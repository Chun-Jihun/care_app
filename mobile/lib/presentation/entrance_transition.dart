import 'package:flutter/material.dart';

/// One current screen is animated; previous notebooks are never retained.
class EntranceTransition extends StatefulWidget {
  const EntranceTransition({
    super.key,
    required this.revision,
    required this.identity,
    required this.enabled,
    required this.child,
  });
  final Object revision;
  final Object? identity;
  final bool enabled;
  final Widget child;
  @override
  State<EntranceTransition> createState() => _EntranceTransitionState();
}

class _EntranceTransitionState extends State<EntranceTransition>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );
  late final curve = CurvedAnimation(
    parent: controller,
    curve: Curves.easeOutCubic,
  );
  @override
  void didUpdateWidget(EntranceTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || widget.identity != oldWidget.identity) {
      controller.value = 1;
    } else if (widget.revision != oldWidget.revision) {
      controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    curve.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(begin: .82, end: 1).animate(curve),
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, .015),
        end: Offset.zero,
      ).animate(curve),
      child: widget.child,
    ),
  );
}
