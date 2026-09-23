import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/records.dart';
import '../l10n/app_strings.dart';
import 'common.dart';
import 'editors.dart';
import 'pending_photo_field.dart';

Future<void> startPhotoRecord(BuildContext context, CareController c) =>
    attempt(context, () async {
      final session = c.captureSession();
      final kind = await showModalBottomSheet<EntryKind>(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(context.tr('어떤 기록에 사진을 넣을까요?')),
                ),
                for (final kind in [
                  EntryKind.meal,
                  EntryKind.medicalContact,
                  EntryKind.generalNote,
                ])
                  ListTile(
                    leading: Icon(kindIcon(kind)),
                    title: Text(context.tr(kind.label)),
                    onTap: () => Navigator.pop(context, kind),
                  ),
              ],
            ),
          ),
        ),
      );
      if (kind == null || !context.mounted) return;
      c.requireSession(session);
      final photo = await choosePhoto(context, c, c.selectedId!);
      if (photo == null || !context.mounted) return;
      c.requireSession(session);
      await editEntry(context, c, kind, initialPhoto: photo);
    });
