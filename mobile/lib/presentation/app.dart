import 'language_picker.dart';
import '../l10n/app_strings.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../application/care_controller.dart';
import '../domain/records.dart';
import 'common.dart';
import 'shell.dart';

class CareApp extends StatefulWidget {
  const CareApp({super.key, required this.controller});
  final CareController controller;
  @override
  State<CareApp> createState() => _CareAppState();
}

class _CareAppState extends State<CareApp> with WidgetsBindingObserver {
  final privateNavigator = GlobalKey<NavigatorState>();
  bool obscured = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(clearLockedImages);
  }

  void clearLockedImages() {
    if (!widget.controller.unlocked) {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(clearLockedImages);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused &&
        !widget.controller.externalOperation) {
      widget.controller.lock();
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
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: forest,
          primary: forest,
          surface: const Color(0xFFF7F8F3),
          onSurface: ink,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F8F3),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF7F8F3),
          foregroundColor: ink,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: const EdgeInsets.symmetric(vertical: 5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFFE6EBE4)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFCCD7CE)),
          ),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: Color(0xFFDDEADB),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: forest,
          foregroundColor: Colors.white,
          elevation: 2,
        ),
      ),
      home: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => !widget.controller.ready
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : widget.controller.unlocked
            ?
              // Authenticated routes are destroyed together, including open photo dialogs.
              Stack(
                children: [
                  AbsorbPointer(
                    absorbing: widget.controller.busy,
                    child: NavigatorPopHandler<Object?>(
                      onPopWithResult: (_) =>
                          privateNavigator.currentState?.maybePop(),
                      child: Navigator(
                        key: privateNavigator,
                        onGenerateRoute: (_) => MaterialPageRoute<void>(
                          builder: (_) => CareShell(widget.controller),
                        ),
                      ),
                    ),
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
      builder: (context, child) => Stack(
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
}

class LockScreen extends StatefulWidget {
  const LockScreen(this.c, {super.key});
  final CareController c;
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final pin = TextEditingController(), repeat = TextEditingController();
  bool working = false;
  Object? error;
  @override
  void dispose() {
    pin.dispose();
    repeat.dispose();
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
                LanguagePicker(c),
                const SizedBox(height: 12),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: CircleAvatar(
                    radius: 32,
                    backgroundColor: Color(0xFFDDEADB),
                    child: Icon(Icons.spa_outlined, size: 32, color: forest),
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  context.tr('매일의 돌봄을,\n한 권에.'),
                  style: Theme.of(context).textTheme.headlineLarge
                      ?.copyWith(fontWeight: FontWeight.w700, height: 1.3),
                ),
                const SizedBox(height: 16),
                Text(
                  c.hasPin
                      ? context.tr('잠금 번호를 입력해 수첩을 열어 주세요.')
                      : context.tr(
                          '간병수첩에 오신 것을 환영해요.\n이 기기에 기록을 안전하게 보관할\n6자리 잠금 번호를 정해 주세요.',
                        ),
                  style: const TextStyle(height: 1.7),
                ),
                const SizedBox(height: 28),
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
                if (!c.hasPin)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextField(
                      controller: repeat,
                      obscureText: true,
                      enableIMEPersonalizedLearning: false,
                      maxLength: 6,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: context.tr('잠금 번호 다시 입력'),
                      ),
                    ),
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
                            if (pin.text != repeat.text) {
                              throw CareError(
                                CareErrorCode.pinConfirmationMismatch,
                              );
                            }
                            await c.setPin(pin.text);
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
                  TextButton.icon(
                    onPressed: working ? null : () => run(c.unlockDevice),
                    icon: const Icon(Icons.fingerprint),
                    label: Text(context.tr('기기 인증으로 열기')),
                  ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Icon(Icons.lock_outline, size: 16, color: forest),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.tr('기기에 암호화 저장 · 계정 없이 시작'),
                        style: TextStyle(color: forest, fontSize: 13),
                      ),
                    ),
                  ],
                ),
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
