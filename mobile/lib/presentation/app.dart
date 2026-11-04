import 'language_picker.dart';

import 'dart:async';

import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../application/care_controller.dart';
import 'common.dart';
import 'shell.dart';
import 'backup_activity_bar.dart';
import 'care_theme.dart';
import 'ui_preferences_scope.dart';
import 'display_settings_page.dart';
import '../domain/ui_preferences.dart';

class CareApp extends StatefulWidget {
  const CareApp({super.key, required this.controller});
  final CareController controller;
  @override
  State<CareApp> createState() => _CareAppState();
}

class _CareAppState extends State<CareApp> with WidgetsBindingObserver {
  var privateNavigator = GlobalKey<NavigatorState>();
  Route<void>? backupReadingRoute;
  bool wasCommitting = false;
  bool obscured = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(syncPrivateNavigation);
  }

  void syncPrivateNavigation() {
    final committing = widget.controller.backupCommitting;
    if (committing && !wasCommitting) {
      privateNavigator = GlobalKey<NavigatorState>();
      backupReadingRoute = null;
    }
    wasCommitting = committing;
    if (!widget.controller.backingUp) backupReadingRoute = null;
    if (!widget.controller.unlocked || committing) {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    }
  }

  void browseBackup() {
    if (!widget.controller.backingUp || widget.controller.backupCommitting) {
      return;
    }
    final navigator = privateNavigator.currentState;
    if (navigator == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    if (backupReadingRoute case final route?) {
      navigator.popUntil((current) => current == route);
      navigator.pop();
      return;
    }
    final route = MaterialPageRoute<void>(
      builder: (_) => CareShell(widget.controller),
    );
    setState(() => backupReadingRoute = route);
    unawaited(
      navigator.push(route).whenComplete(() {
        if (mounted && backupReadingRoute == route) {
          setState(() => backupReadingRoute = null);
        }
      }),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(syncPrivateNavigation);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused &&
        !widget.controller.externalOperation) {
      widget.controller.handleBackground();
    }
    setState(() => obscured = state != AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed && widget.controller.unlocked) {
      attempt(context, widget.controller.refresh);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (context) => context.tr('간병수첩'),
      locale: widget.controller.language.locale,
      supportedLocales: AppLanguage.values.map((value) => value.locale),
      localizationsDelegates: const [
        AppStrings.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      theme: careTheme(
        widget.controller.uiPreferences,
        reduceMotion: MediaQuery.maybeOf(context)?.disableAnimations ?? false,
      ),
      highContrastTheme: careTheme(
        widget.controller.uiPreferences,
        highContrast: true,
        reduceMotion: MediaQuery.maybeOf(context)?.disableAnimations ?? false,
      ),
      themeAnimationDuration:
          (widget.controller.uiPreferences.reduceMotion ||
              (MediaQuery.maybeOf(context)?.disableAnimations ?? false))
          ? Duration.zero
          : const Duration(milliseconds: 200),
      home: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => !widget.controller.ready
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : widget.controller.unlocked
            ?
              // Authenticated routes are destroyed together, including open photo dialogs.
              Stack(
                children: [
                  Column(
                    children: [
                      if (widget.controller.backingUp)
                        BackupActivityBar(
                          widget.controller,
                          key: const ValueKey('backup-contacts'),
                          onBrowse: widget.controller.backupCommitting
                              ? null
                              : browseBackup,
                          browsing: backupReadingRoute != null,
                        ),
                      Expanded(
                        child: widget.controller.backupCommitting
                            ? const Center(child: CircularProgressIndicator())
                            : AbsorbPointer(
                                absorbing:
                                    widget.controller.busy &&
                                    !widget.controller.backingUp,
                                child: NavigatorPopHandler<Object?>(
                                  onPopWithResult: (_) =>
                                      privateNavigator.currentState?.maybePop(),
                                  child: Navigator(
                                    key: privateNavigator,
                                    onGenerateRoute: (_) =>
                                        MaterialPageRoute<void>(
                                          builder: (_) =>
                                              CareShell(widget.controller),
                                        ),
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                  if (widget.controller.busy)
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SafeArea(child: LinearProgressIndicator()),
                    ),
                ],
              )
            : LockScreen(widget.controller),
      ),
      builder: (context, child) {
        final data = MediaQuery.of(context);
        final preferences = widget.controller.uiPreferences;
        return UiPreferencesScope(
          value: preferences,
          child: MediaQuery(
            data: data.copyWith(
              textScaler: preferences.enabled(UiOption.largeText)
                  ? MinimumTextScaler(data.textScaler, 1.2)
                  : data.textScaler,
              boldText: data.boldText || preferences.enabled(UiOption.boldText),
              highContrast:
                  data.highContrast ||
                  preferences.enabled(UiOption.highContrast),
              disableAnimations:
                  data.disableAnimations || preferences.reduceMotion,
            ),
            child: Stack(
              children: [
                child!,
                if (obscured)
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Color(0xFFF7F8F3),
                      child: Center(
                        child: Icon(
                          Icons.lock_outline_rounded,
                          color: forest,
                          size: 48,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class LockScreen extends StatefulWidget {
  const LockScreen(this.c, {super.key});
  final CareController c;
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final pin = TextEditingController();
  late final deviceEnabled = widget.c.deviceAuthEnabled;
  bool working = false;
  Object? error;
  @override
  void dispose() {
    pin.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => error = e);
      }
    } finally {
      if (mounted) {
        setState(() => working = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(28),
              children: [
                Text(
                  context.tr('간병수첩'),
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                Text(
                  c.hasPin
                      ? context.tr('잠금 번호를 입력해 수첩을 열어 주세요.')
                      : context.tr('식사·복약·상태를 한곳에 기록해요. 앱 잠금은 설정에서 켤 수 있습니다.'),
                  style: const TextStyle(height: 1.7),
                ),
                const SizedBox(height: 28),
                if (c.hasPin)
                  TextField(
                    controller: pin,
                    obscureText: true,
                    enableIMEPersonalizedLearning: false,
                    maxLength: 6,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: context.tr('잠금 번호 6자리'),
                    ),
                    onSubmitted: (_) {
                      if (c.hasPin && !working) {
                        run(() => c.unlockPin(pin.text));
                      }
                    },
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      errorText(context, error!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                FilledButton(
                  onPressed: working
                      ? null
                      : () => run(() async {
                          if (c.hasPin) {
                            await c.unlockPin(pin.text);
                          } else {
                            await c.startWithoutLock();
                          }
                        }),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      working
                          ? context.tr('수첩을 여는 중…')
                          : c.hasPin
                          ? context.tr('수첩 열기')
                          : context.tr('내 수첩 시작하기'),
                    ),
                  ),
                ),
                if (c.hasPin)
                  FutureBuilder<bool>(
                    future: deviceEnabled,
                    builder: (context, snapshot) => snapshot.data == true
                        ? TextButton.icon(
                            onPressed: working
                                ? null
                                : () => run(c.unlockDevice),
                            icon: const Icon(Icons.fingerprint),
                            label: Text(context.tr('기기 인증으로 열기')),
                          )
                        : const SizedBox.shrink(),
                  ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Icon(Icons.lock_outline, size: 16, color: forest),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.tr('기기에 암호화 저장 · 계정 없이 시작'),
                        style: TextStyle(color: forest, fontSize: 14),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: const Icon(Icons.accessibility_new),
                  title: Text(context.tr('화면·접근성 설정')),
                  onTap: working
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => DisplaySettingsPage(c),
                          ),
                        ),
                ),
                LanguagePicker(c),
                if (c.hasPin)
                  TextButton(
                    onPressed: working
                        ? null
                        : () async {
                            if (await confirm(
                              context,
                              context.tr('잠금 번호를 잊으셨나요?'),
                              context.tr(
                                '기존 잠금 번호를 복구할 수는 없습니다. 이 기기의 수첩을 모두 삭제하고 다시 시작할 수 있습니다. 따로 저장한 암호화 백업은 새 수첩의 설정에서 복원할 수 있습니다.',
                              ),
                              action: context.tr('모두 삭제하고 재시작'),
                            )) {
                              await run(c.deleteAll);
                            }
                          },
                    child: Text(context.tr('잠금 번호를 잊었어요')),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
