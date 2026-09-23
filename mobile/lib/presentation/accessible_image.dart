import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';

/// The same zoom controls serve photos, OCR originals and document pages.
/// In scrollable content provide a viewport height; a full-screen viewer fills
/// the available space while keeping controls outside the moving image.
class AccessibleImage extends StatefulWidget {
  const AccessibleImage({
    super.key,
    required this.bytes,
    required this.semanticLabel,
    this.viewportHeight,
    this.maxScale = 8,
  }) : assert(maxScale >= 1);
  final Uint8List bytes;
  final String semanticLabel;
  final double? viewportHeight;
  final double maxScale;
  @override
  State<AccessibleImage> createState() => _AccessibleImageState();
}

class _AccessibleImageState extends State<AccessibleImage> {
  final transform = TransformationController();
  Size viewport = Size.zero;
  @override
  void didUpdateWidget(covariant AccessibleImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bytes != widget.bytes) transform.value = Matrix4.identity();
  }

  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  void zoom(double factor) {
    final scale = (transform.value.getMaxScaleOnAxis() * factor).clamp(
      1.0,
      widget.maxScale,
    );
    final center = viewport.center(Offset.zero);
    final scene = transform.toScene(center);
    transform.value = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(
        (center.dx - scene.dx * scale).clamp(viewport.width * (1 - scale), 0.0),
        (center.dy - scene.dy * scale).clamp(
          viewport.height * (1 - scale),
          0.0,
        ),
        0,
      );
  }

  @override
  Widget build(BuildContext context) {
    final picture = LayoutBuilder(
      builder: (context, constraints) {
        viewport = constraints.biggest;
        return InteractiveViewer(
          transformationController: transform,
          minScale: 1,
          maxScale: widget.maxScale,
          child: Center(
            child: Image.memory(
              widget.bytes,
              semanticLabel: widget.semanticLabel,
              fit: BoxFit.contain,
              gaplessPlayback: false,
              errorBuilder: (_, _, _) => Text(context.tr('사진을 열 수 없습니다.')),
            ),
          ),
        );
      },
    );
    return Column(
      mainAxisSize: widget.viewportHeight == null
          ? MainAxisSize.max
          : MainAxisSize.min,
      children: [
        if (widget.viewportHeight case final height?)
          SizedBox(height: height, child: picture)
        else
          Expanded(child: picture),
        ValueListenableBuilder<Matrix4>(
          valueListenable: transform,
          builder: (context, matrix, _) {
            final scale = matrix.getMaxScaleOnAxis();
            return Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                IconButton(
                  tooltip: context.tr('작게 보기'),
                  onPressed: scale > 1.001 ? () => zoom(1 / 1.5) : null,
                  icon: const Icon(Icons.remove),
                ),
                Text(context.tr('{0}% 확대', [(scale * 100).round()])),
                IconButton(
                  tooltip: context.tr('크게 보기'),
                  onPressed: scale < widget.maxScale - .001
                      ? () => zoom(1.5)
                      : null,
                  icon: const Icon(Icons.add),
                ),
                TextButton(
                  onPressed: () => transform.value = Matrix4.identity(),
                  child: Text(context.tr('화면에 맞추기')),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
