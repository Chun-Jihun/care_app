import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;

import '../domain/records.dart';
import 'care_database.dart';
import 'crypto.dart';
import 'vault_state.dart';

final class VaultPhotos {
  VaultPhotos(this._state);
  final VaultState _state;
  Future<void> addPhoto(
    String pid,
    String eid,
    Uint8List source, {
    void Function()? beforeCommit,
  }) async {
    if (source.length > 20 * 1024 * 1024) {
      throw CareError(CareErrorCode.photoTooLarge);
    }
    _state.database.attachments(pid, eid);
    final normalized = await Isolate.run(() => normalizePhoto(source));
    final id = CareDatabase.newId();
    final key = VaultCrypto.randomBytes();
    final encrypted = await VaultCrypto.seal(
      normalized,
      key,
      context: 'photo:$id',
    );
    final wrapped = await VaultCrypto.seal(
      key,
      _state.key('files'),
      context: 'key:$id',
    );
    final dir = await Directory(p.join(_state.directory.path, 'attachments'))
        .create(recursive: true);
    final file = File(p.join(dir.path, '$id.enc'));
    try {
      await file.writeAsBytes(encrypted, flush: true);
      beforeCommit?.call();
      _state.database.addAttachment(
        pid,
        eid,
        id,
        base64Encode(wrapped),
        encrypted.length,
      );
    } catch (_) {
      if (await file.exists()) {
        await file.delete();
      }
      rethrow;
    }
  }

  static Uint8List normalizePhoto(Uint8List source) {
    if (source.length > 20 * 1024 * 1024) {
      throw CareError(CareErrorCode.photoTooLarge);
    }
    final img.Decoder decoder;
    if (img.JpegDecoder().isValidFile(source)) {
      decoder = img.JpegDecoder();
    } else if (img.PngDecoder().isValidFile(source)) {
      decoder = img.PngDecoder();
    } else {
      throw CareError(CareErrorCode.unsupportedPhoto);
    }
    final info = decoder.startDecode(source);
    if (info == null || info.width <= 0 || info.height <= 0) {
      throw CareError(CareErrorCode.invalidPhoto);
    }
    if (info.width * info.height > 24000000) {
      throw CareError(CareErrorCode.photoResolutionTooLarge);
    }
    if (info.numFrames != 1) {
      throw CareError(CareErrorCode.animatedPhotoUnsupported);
    }
    final decoded = decoder.decodeFrame(0);
    if (decoded == null) throw CareError(CareErrorCode.photoDecodeFailed);
    final oriented = img.bakeOrientation(decoded);
    final clean = img.Image(
      width: oriented.width,
      height: oriented.height,
      numChannels: 3,
    );
    img.compositeImage(clean, oriented);
    return Uint8List.fromList(img.encodeJpg(clean, quality: 94));
  }

  Future<Uint8List> photo(String pid, String eid, String id) async {
    final item = _state.database
        .attachments(pid, eid)
        .where((a) => a.id == id)
        .firstOrNull;
    if (item == null || !VaultState.idPattern.hasMatch(id)) {
      throw CareError(CareErrorCode.photoNotFound);
    }
    final key = await VaultCrypto.open(
      base64Decode(item.wrappedKey),
      _state.key('files'),
      context: 'key:$id',
    );
    return VaultCrypto.open(
      await File(p.join(_state.directory.path, 'attachments', '$id.enc'))
          .readAsBytes(),
      key,
      context: 'photo:$id',
    );
  }
}
