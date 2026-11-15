import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:care_notebook/infrastructure/google_backup_drive.dart';
import 'package:care_notebook/l10n/app_strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';

final class _GooglePlatform extends GoogleSignInPlatform {
  bool signedIn = false;
  bool authorized = false;
  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<AuthenticationResults> authenticate(
    AuthenticateParameters params,
  ) async {
    if (!signedIn) {
      throw const GoogleSignInException(
        code: GoogleSignInExceptionCode.canceled,
      );
    }
    return const AuthenticationResults(
      user: GoogleSignInUserData(email: 'example@example.invalid', id: 'test'),
      authenticationTokens: AuthenticationTokenData(idToken: null),
    );
  }

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async {
    expect(params.request.email, 'example@example.invalid');
    if (authorized) {
      return const ClientAuthorizationTokenData(accessToken: 'test');
    }
    throw const GoogleSignInException(
      code: GoogleSignInExceptionCode.unknownError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  _Headers([this.location]);

  final String? location;

  @override
  String? value(String name) =>
      name == HttpHeaders.locationHeader ? location : null;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, String? location) : headers = _Headers(location);

  @override
  final int statusCode;
  @override
  final HttpHeaders headers;
  @override
  int get contentLength => 0;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => const Stream<List<int>>.empty().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.response);

  final HttpClientResponse response;
  final body = BytesBuilder();
  @override
  final headers = _Headers();
  @override
  bool followRedirects = false;
  @override
  int contentLength = 0;

  @override
  void add(List<int> data) => body.add(data);

  @override
  Future<HttpClientResponse> close() async => response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DriveClient implements HttpClient {
  static const _upload = 'https://www.googleapis.com/upload/drive/v3/files';
  final steps = [
    ('PATCH', '$_upload/reserved', 200, '$_upload?upload_id=update'),
    ('PUT', '$_upload?upload_id=update', 404, null),
    ('POST', _upload, 200, '$_upload?upload_id=create'),
    ('PUT', '$_upload?upload_id=create', 200, null),
  ];
  final requests = <_Request>[];

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final (verb, address, status, location) = steps.removeAt(0);
    final expected = Uri.parse(address);
    expect(method, verb);
    expect(url.origin, expected.origin);
    expect(url.path, expected.path);
    expect(
      url.queryParameters,
      method == 'PUT'
          ? expected.queryParameters
          : {'uploadType': 'resumable', 'fields': 'id'},
    );
    final request = _Request(_Response(status, location));
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'Drive connection failures explain whether login or consent failed',
    () async {
      final previous = GoogleSignInPlatform.instance;
      final platform = _GooglePlatform();
      GoogleSignInPlatform.instance = platform;
      addTearDown(() => GoogleSignInPlatform.instance = previous);
      const strings = AppStrings(AppLanguage.korean);
      final drive = GoogleBackupDrive();
      await expectLater(
        drive.connect(),
        throwsA(
          predicate<Object>(
            (error) => strings.error(error).contains('Google 로그인'),
          ),
        ),
      );
      platform.signedIn = true;
      await expectLater(
        drive.connect(),
        throwsA(
          predicate<Object>(
            (error) => strings.error(error).contains('Drive 권한 승인'),
          ),
        ),
      );
    },
  );

  test(
    'creates the first backup when Drive reports 404 during upload',
    () async {
      final previous = GoogleSignInPlatform.instance;
      GoogleSignInPlatform.instance = _GooglePlatform()..authorized = true;
      addTearDown(() => GoogleSignInPlatform.instance = previous);
      final client = _DriveClient();
      final encrypted = Uint8List.fromList([1, 2, 3]);

      await HttpOverrides.runZoned(
        () => GoogleBackupDrive().upload(
          'example@example.invalid',
          'reserved',
          encrypted,
          () {},
        ),
        createHttpClient: (_) => client,
      );

      expect(client.steps, isEmpty);
      expect(jsonDecode(utf8.decode(client.requests[2].body.toBytes())), {
        'id': 'reserved',
        'name': 'care-notebook.carebackup',
        'parents': ['appDataFolder'],
      });
      expect(client.requests[3].body.toBytes(), encrypted);
    },
  );
}
