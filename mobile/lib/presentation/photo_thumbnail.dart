import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../application/care_controller.dart';

class PhotoThumbnail extends StatefulWidget {
  const PhotoThumbnail(this.c, this.pid, this.entryId, this.id, {super.key});
  final CareController c;
  final String pid, entryId, id;
  @override
  State<PhotoThumbnail> createState() => _PhotoThumbnailState();
}

class _PhotoThumbnailState extends State<PhotoThumbnail> {
  late final Future<Uint8List> photo = widget.c.photos.preview(
    widget.pid,
    widget.entryId,
    widget.id,
  );
  ImageProvider? provider;
  @override
  void dispose() {
    provider?.evict();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: 56,
      height: 56,
      child: FutureBuilder<Uint8List>(
        future: photo,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Icon(Icons.photo_outlined);
          provider ??= ResizeImage(MemoryImage(snapshot.data!), width: 144);
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image(
              image: provider!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.broken_image_outlined),
            ),
          );
        },
      ),
    ),
  );
}
