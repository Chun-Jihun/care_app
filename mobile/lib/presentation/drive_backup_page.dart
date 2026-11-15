import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../application/services/drive_backup_service.dart';
import '../domain/records.dart';
import '../l10n/app_strings.dart';
import 'backup_page.dart';
import 'common.dart';
import 'password_field.dart';

class DriveBackupPage extends StatefulWidget {
  const DriveBackupPage(this.controller, {super.key});
  final CareController controller;

  @override
  State<DriveBackupPage> createState() => _DriveBackupPageState();
}

class _DriveBackupPageState extends State<DriveBackupPage> {
  DriveBackupService get _drive => widget.controller.driveBackup!;
  late Future<DriveBackupStatus?> _status = _drive.status();
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _drive.changes.addListener(_refresh);
  }

  @override
  void dispose() {
    _drive.changes.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted && widget.controller.unlocked) {
      setState(() => _status = _drive.status());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    await attempt(context, action);
    if (mounted) {
      setState(() => _working = false);
    }
  }

  Future<void> _enable() async {
    final password = TextEditingController(), repeat = TextEditingController();
    try {
      await pushPage(
        context,
        MaterialPageRoute<void>(
          builder: (context) => EditorPage(
            title: context.tr('Google Drive 자동 백업'),
            saveLabel: context.tr('Google 계정 연결'),
            content: (_) => [
              Text(
                context.tr(
                  '새 기기에서도 사용할 별도의 백업 비밀번호를 정해 주세요. 잊으면 Google 계정으로도 복원할 수 없어요.',
                ),
              ),
              PasswordField(
                controller: password,
                label: context.tr('백업 비밀번호 (12자 이상)'),
              ),
              PasswordField(
                controller: repeat,
                label: context.tr('백업 비밀번호 확인'),
              ),
            ],
            save: () async {
              if (password.text != repeat.text) {
                throw CareError(CareErrorCode.passwordMismatch);
              }
              await _drive.enable(password.text);
            },
          ),
        ),
      );
      if (mounted && (await _drive.status()) != null) {
        await _drive.backup(now: true);
      }
    } finally {
      password.dispose();
      repeat.dispose();
    }
  }

  Future<Uint8List?> _choose() async {
    final files = await _drive.availableFiles();
    if (!mounted) return null;
    final file = await showDialog<DriveBackupFile>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(context.tr('Google Drive 백업 선택')),
        content: files.isEmpty
            ? Text(context.tr('이 Google 계정에 저장된 백업이 없어요.'))
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(files.first.accountEmail),
                  for (final file in files)
                    ListTile(
                      title: Text(dateText(context, file.modifiedAt.toLocal())),
                      subtitle: Text(
                        timeText(context, file.modifiedAt.toLocal()),
                      ),
                      onTap: () => Navigator.pop(context, file),
                    ),
                ],
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('취소')),
          ),
        ],
      ),
    );
    if (file == null || !mounted) return null;
    return _drive.download(file);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('Google Drive 자동 백업'))),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            context.tr(
              '수첩을 열면 하루 한 번 모든 수첩의 기록·약·일정·첨부 사진을 암호화해서 연결한 Google Drive에 저장해요. 이 기기의 최근 백업 한 개가 갱신돼요.',
            ),
          ),
          Text(
            context.tr(
              '별칭·연락처 항목, 대화, 돌보는 나의 상태, 작성 중인 초안, 진료 녹음 원본은 제외해요. 기록 본문과 사진에 들어 있는 정보는 그대로 암호화해요.',
            ),
          ),
          const SizedBox(height: 16),
          FutureBuilder<DriveBackupStatus?>(
            future: _status,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const LinearProgressIndicator();
              }
              if (snapshot.hasError) {
                return Text(errorText(context, snapshot.error!));
              }
              final status = snapshot.data;
              final last = status?.lastSuccess?.toLocal();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (status == null)
                    FilledButton(
                      onPressed: _working ? null : () => _run(_enable),
                      child: Text(context.tr('Google 계정 연결')),
                    )
                  else ...[
                    Text(context.tr('연결된 Google 계정 {0}', [status.email])),
                    Text(
                      last == null
                          ? context.tr('아직 성공한 백업이 없어요.')
                          : context.tr('마지막 성공 {0} {1}', [
                              dateText(context, last),
                              timeText(context, last),
                            ]),
                    ),
                    if (_drive.failure case final error?)
                      Text(errorText(context, error)),
                    FilledButton(
                      onPressed: _working
                          ? null
                          : () => _run(() => _drive.backup(now: true)),
                      child: Text(context.tr('지금 백업')),
                    ),
                    OutlinedButton(
                      onPressed: _working ? null : () => _run(_drive.reconnect),
                      child: Text(context.tr('같은 Google 계정 다시 인증')),
                    ),
                    TextButton(
                      onPressed: _working
                          ? null
                          : () => _run(() async {
                              if (await confirm(
                                    context,
                                    context.tr('자동 백업을 끌까요?'),
                                    context.tr(
                                      '이 기기에서 자동 백업을 끄고 백업 비밀번호를 지워요. 이미 Google Drive에 저장된 백업은 계정에 남아요.',
                                    ),
                                    action: context.tr('연결 해제'),
                                  ) &&
                                  mounted) {
                                await _drive.disconnect();
                              }
                            }),
                      child: Text(context.tr('연결 해제')),
                    ),
                  ],
                ],
              );
            },
          ),
          OutlinedButton(
            onPressed: _working
                ? null
                : () => _run(
                    () => restoreFlow(
                      context,
                      widget.controller,
                      choose: _choose,
                    ),
                  ),
            child: Text(context.tr('Google Drive에서 복원')),
          ),
          if (_working) const LinearProgressIndicator(),
        ],
      ),
    ),
  );
}
