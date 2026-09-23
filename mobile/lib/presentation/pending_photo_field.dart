import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/records.dart';
import '../domain/reviewed_input.dart';
import '../l10n/app_strings.dart';
import 'accessible_image.dart';
import 'ai_draft_page.dart';
import 'common.dart';

Future<Uint8List?> choosePhoto(
  BuildContext context,
  CareController c,
  String pid,
) async {
  final session = c.captureSession();
  final camera = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(context.tr('촬영')),
              onTap: () => Navigator.pop(context, true),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(context.tr('사진 선택')),
              onTap: () => Navigator.pop(context, false),
            ),
          ],
        ),
      ),
    ),
  );
  if (camera == null || !context.mounted) return null;
  c.requireSession(session);
  return c.photos.pick(pid, camera: camera);
}

/// Unconfirmed photo bytes stay in this editor's memory, never a plain file.
class PendingPhotoField extends StatelessWidget {
  const PendingPhotoField({
    super.key,
    required this.c,
    required this.pid,
    required this.photo,
    required this.onChanged,
    required this.onReviewed,
    this.kind,
    this.currentFields = const {},
  });
  final CareController c;
  final String pid;
  final Uint8List? photo;
  final ValueChanged<Uint8List?> onChanged;
  final ValueChanged<ReviewedInput> onReviewed;
  final EntryKind? kind;
  final Map<String, String> currentFields;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      OutlinedButton.icon(
        icon: const Icon(Icons.add_a_photo_outlined),
        label: Text(context.tr(photo == null ? '사진 넣기' : '다른 사진 선택')),
        onPressed: () => attempt(context, () async {
          final session = c.captureSession();
          final value = await choosePhoto(context, c, pid);
          if (!context.mounted || value == null) return;
          c.requireSession(session);
          onChanged(value);
        }),
      ),
      if (photo case final data?) ...[
        AccessibleImage(
          bytes: data,
          semanticLabel: context.tr('저장할 사진 미리보기'),
          viewportHeight: 190,
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.document_scanner_outlined),
          label: Text(context.tr('사진에서 글자 읽기')),
          onPressed: () => attempt(context, () async {
            final session = c.captureSession();
            final reviewed = await reviewRecordInput(
              context,
              c,
              pid,
              photo: data,
              kind: kind,
              currentFields: currentFields,
            );
            if (!context.mounted || reviewed == null) return;
            c.requireSession(session);
            onReviewed(reviewed);
          }),
        ),
        TextButton(
          onPressed: () => onChanged(null),
          child: Text(context.tr('선택한 사진 빼기')),
        ),
        Text(
          context.tr(
            '사진은 저장을 눌러야 보관돼요. 초안에는 글만 보관되므로 나갔다 돌아오면 사진을 다시 선택해 주세요.',
          ),
        ),
      ],
    ],
  );
}
