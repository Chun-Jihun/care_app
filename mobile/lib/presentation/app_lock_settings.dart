import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/care_controller.dart';
import '../domain/records.dart';
import '../l10n/app_strings.dart';
import 'common.dart';

class AppLockSettings extends StatelessWidget {
  const AppLockSettings(this.c, {super.key});
  final CareController c;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SwitchListTile(
        key: const ValueKey('appLockToggle'),
        title: Text(context.tr('앱 잠금')),
        subtitle: Text(
          context.tr(
            c.hasPin ? '앱을 다시 열 때 인증을 요청해요.' : '인증 없이 수첩을 열어요. 기록은 암호화해 보관합니다.',
          ),
        ),
        value: c.hasPin,
        onChanged: c.busy
            ? null
            : (enabled) =>
                  enabled ? _editPin(context, c) : _disableLock(context, c),
      ),
      if (c.hasPin) ...[
        FutureBuilder<bool>(
          future: c.deviceAuthEnabled,
          builder: (context, snapshot) => SwitchListTile(
            title: Text(context.tr('기기 인증으로 열기')),
            subtitle: Text(context.tr('지문·얼굴 또는 기기 잠금으로 인증')),
            value: snapshot.data ?? false,
            onChanged: !snapshot.hasData || c.busy
                ? null
                : (value) => attempt(context, () => c.enableDeviceAuth(value)),
          ),
        ),
        ListTile(
          title: Text(context.tr('잠금 번호 변경')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _editPin(context, c),
        ),
        ListTile(
          title: Text(context.tr('지금 잠그기')),
          trailing: const Icon(Icons.lock_outline),
          onTap: c.lock,
        ),
      ],
    ],
  );
}

Widget _pinField(TextEditingController controller, String label) => TextField(
  controller: controller,
  obscureText: true,
  autocorrect: false,
  enableSuggestions: false,
  enableIMEPersonalizedLearning: false,
  keyboardType: TextInputType.number,
  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
  maxLength: 6,
  decoration: InputDecoration(labelText: label),
);

Future<void> _editPin(BuildContext context, CareController c) async {
  final a = TextEditingController(), b = TextEditingController();
  final enabled = c.hasPin;
  final session = c.captureSession();
  try {
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (context) => EditorPage(
          title: context.tr(enabled ? '잠금 번호 변경' : '앱 잠금 설정'),
          content: (_) => [
            _pinField(a, context.tr('새 잠금 번호 (숫자 6자리)')),
            _pinField(b, context.tr('잠금 번호 확인')),
          ],
          save: () async {
            c.requireSession(session);
            if (a.text != b.text) {
              throw CareError(CareErrorCode.pinConfirmationMismatch);
            }
            await c.setPin(a.text);
          },
        ),
      ),
    );
  } finally {
    a.dispose();
    b.dispose();
  }
}

Future<void> _disableLock(BuildContext context, CareController c) async {
  final pin = TextEditingController();
  final session = c.captureSession();
  try {
    await pushPage(
      context,
      MaterialPageRoute<void>(
        builder: (context) => EditorPage(
          title: context.tr('앱 잠금 끄기'),
          saveLabel: context.tr('잠금 끄기'),
          content: (_) => [
            Text(
              context.tr(
                '현재 잠금 번호를 확인하면 다음부터 인증 없이 수첩을 열어요. 기록은 계속 암호화해 보관합니다.',
              ),
            ),
            const SizedBox(height: 16),
            _pinField(pin, context.tr('현재 잠금 번호')),
          ],
          save: () async {
            c.requireSession(session);
            await c.disableAppLock(pin.text);
          },
        ),
      ),
    );
  } finally {
    pin.dispose();
  }
}
