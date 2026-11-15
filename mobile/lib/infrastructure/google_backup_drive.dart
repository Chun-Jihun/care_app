import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';

import '../application/services/drive_backup_service.dart';
import '../domain/records.dart';
import 'vault_store.dart';

final class GoogleBackupDrive implements BackupDrive {
  static const clientId = String.fromEnvironment('CARE_GOOGLE_WEB_CLIENT_ID');
  static const _scope = ['https://www.googleapis.com/auth/drive.appdata'];
  static const _name = 'care-notebook.carebackup';
  static const _timeout = Duration(minutes: 2);
  static const _limit = VaultStore.maxBackupBytes + 128;
  final _google = GoogleSignIn.instance;
  late final _ready = _google.initialize(serverClientId: clientId);

  @override
  Future<String> connect() async {
    final GoogleSignInAccount user;
    try {
      await _ready;
      user = await _google.authenticate();
    } on GoogleSignInException {
      throw CareError(CareErrorCode.driveSignInIncomplete);
    }
    try {
      await user.authorizationClient.authorizeScopes(_scope);
    } on GoogleSignInException {
      throw CareError(CareErrorCode.driveConsentIncomplete);
    }
    return user.email;
  }

  @override
  Future<void> disconnect(String email) async {
    await _token(email);
    await _google.disconnect();
  }

  @override
  Future<void> reconnect(String email) async {
    await _token(email, prompt: true);
  }

  Future<String> _token(String email, {bool prompt = false}) async {
    await _ready;
    final authorization = await GoogleSignInPlatform.instance
        .clientAuthorizationTokensForScopes(
          ClientAuthorizationTokensForScopesParameters(
            request: AuthorizationRequestDetails(
              scopes: _scope,
              userId: null,
              email: email,
              promptIfUnauthorized: prompt,
            ),
          ),
        );
    if (authorization == null) {
      throw CareError(CareErrorCode.driveAuthorizationRequired);
    }
    return authorization.accessToken;
  }

  Future<({int status, Uint8List bytes, String? location})> _request(
    String email,
    String method,
    String path, {
    Map<String, String>? query,
    String? type,
    List<List<int>> body = const [],
    int limit = 64 * 1024,
    void Function()? beforeSend,
    Uri? session,
    int? uploadLength,
  }) async {
    final token = await _token(email).timeout(const Duration(seconds: 30));
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      return await (() async {
        beforeSend?.call();
        final request = await client.openUrl(
          method,
          session ?? Uri.https('www.googleapis.com', path, query),
        );
        request.followRedirects = false;
        beforeSend?.call();
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        if (uploadLength != null) {
          request.headers.set(
            'X-Upload-Content-Type',
            'application/octet-stream',
          );
          request.headers.set('X-Upload-Content-Length', uploadLength);
        }
        if (type != null) {
          request.headers.set(HttpHeaders.contentTypeHeader, type);
          request.contentLength = body.fold(
            0,
            (total, bytes) => total + bytes.length,
          );
          for (final bytes in body) {
            request.add(bytes);
          }
        }
        final response = await request.close();
        if (response.statusCode == HttpStatus.unauthorized) {
          await GoogleSignInPlatform.instance.clearAuthorizationToken(
            ClearAuthorizationTokenParams(accessToken: token),
          );
          throw CareError(CareErrorCode.driveAuthorizationRequired);
        }
        if (response.contentLength > limit) {
          throw CareError(CareErrorCode.backupFileTooLarge);
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (bytes.length + chunk.length > limit) {
            throw CareError(CareErrorCode.backupFileTooLarge);
          }
          bytes.add(chunk);
        }
        return (
          status: response.statusCode,
          bytes: bytes.takeBytes(),
          location: response.headers.value(HttpHeaders.locationHeader),
        );
      })().timeout(_timeout);
    } finally {
      client.close(force: true);
    }
  }

  void _check(int status) {
    if (status < 200 || status >= 300) {
      throw CareError(CareErrorCode.driveBackupFailed);
    }
  }

  @override
  Future<String> reserveFile(String email) async {
    final result = await _request(
      email,
      'GET',
      '/drive/v3/files/generateIds',
      query: {'count': '1', 'space': 'appDataFolder'},
    );
    _check(result.status);
    final response =
        jsonDecode(utf8.decode(result.bytes)) as Map<String, dynamic>;
    return (response['ids'] as List).single as String;
  }

  @override
  Future<void> upload(
    String email,
    String fileId,
    Uint8List data,
    void Function() check,
  ) async {
    if (data.length > _limit) throw CareError(CareErrorCode.backupFileTooLarge);
    final path = '/upload/drive/v3/files/${Uri.encodeComponent(fileId)}';
    Future<int> send({bool create = false}) async {
      final result = await _request(
        email,
        create ? 'POST' : 'PATCH',
        create ? '/upload/drive/v3/files' : path,
        query: {'uploadType': 'resumable', 'fields': 'id'},
        type: 'application/json; charset=UTF-8',
        uploadLength: data.length,
        beforeSend: check,
        body: [
          utf8.encode(
            jsonEncode(
              create
                  ? {
                      'id': fileId,
                      'name': _name,
                      'parents': ['appDataFolder'],
                    }
                  : <String, Object>{},
            ),
          ),
        ],
      );
      if (result.status < 200 || result.status >= 300) return result.status;
      final session = Uri.tryParse(result.location ?? '');
      if (session == null ||
          session.scheme != 'https' ||
          session.host != 'www.googleapis.com' ||
          session.port != 443 ||
          session.userInfo.isNotEmpty ||
          !(session.path == '/upload/drive/v3/files' ||
              session.path.startsWith('/upload/drive/v3/files/'))) {
        throw CareError(CareErrorCode.driveBackupFailed);
      }
      final uploaded = await _request(
        email,
        'PUT',
        '',
        session: session,
        type: 'application/octet-stream',
        body: [data],
        beforeSend: check,
      );
      return uploaded.status;
    }

    // Drive can defer the missing-file response until the bytes are sent.
    var status = await send();
    if (status == HttpStatus.notFound) {
      status = await send(create: true);
      if (status == HttpStatus.conflict) status = await send();
    }
    _check(status);
  }

  @override
  Future<List<DriveBackupFile>> files(String email) async {
    final result = await _request(
      email,
      'GET',
      '/drive/v3/files',
      query: {
        'spaces': 'appDataFolder',
        'q': "name = '$_name'",
        'orderBy': 'modifiedTime desc',
        'pageSize': '20',
        'fields': 'files(id,modifiedTime)',
      },
    );
    _check(result.status);
    final response =
        jsonDecode(utf8.decode(result.bytes)) as Map<String, dynamic>;
    return [
      for (final file in response['files'] as List)
        (
          id: file['id'] as String,
          modifiedAt: DateTime.parse(file['modifiedTime'] as String),
          accountEmail: email,
        ),
    ];
  }

  @override
  Future<Uint8List> download(String email, String fileId) async {
    final result = await _request(
      email,
      'GET',
      '/drive/v3/files/${Uri.encodeComponent(fileId)}',
      query: {'alt': 'media'},
      limit: _limit,
    );
    _check(result.status);
    return result.bytes;
  }
}
