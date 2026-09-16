import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:care_ort/care_ort.dart';
import 'package:image/image.dart' as img;

import '../../domain/ai.dart';

/// Horizontal-line OCR. Recognition crops and coordinates remain tied to the
/// original image; the UI presents both before any text is accepted.
Future<OcrDraft> recognizeLocal(
  String detector,
  String recognizer,
  String dictionary,
  Uint8List bytes,
) async {
  if (bytes.length > 24 * 1024 * 1024) {
    throw const AiException(AiFailure.invalidInput);
  }
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width * info.height > 16000000) {
    throw const AiException(AiFailure.invalidInput);
  }
  final decoded = decoder!.decodeFrame(0);
  if (decoded == null) throw const AiException(AiFailure.invalidInput);
  var original = img.bakeOrientation(decoded);
  if (math.max(original.width, original.height) > 1920) {
    original = img.copyResize(
      original,
      width: original.width >= original.height ? 1920 : null,
      height: original.height > original.width ? 1920 : null,
    );
  }
  final ratio = math.min(1.0, 960 / math.max(original.width, original.height));
  final w = math.max(32, (original.width * ratio / 32).round() * 32);
  final h = math.max(32, (original.height * ratio / 32).round() * 32);
  final image = img.copyResize(
    original,
    width: w,
    height: h,
    interpolation: img.Interpolation.linear,
  );
  final input = Float32List(3 * w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final pixel = image.getPixel(x, y);
      final channels = [pixel.b, pixel.g, pixel.r];
      for (var c = 0; c < 3; c++) {
        input[c * w * h + y * w + x] =
            (channels[c] / 255 - [.485, .456, .406][c]) / [.229, .224, .225][c];
      }
    }
  }
  final det = FloatSession(detector);
  late List<List<double>> boxes;
  try {
    final result = det.run(input, [1, 3, h, w]);
    boxes = textBoxes(
      result.$1,
      result.$2[result.$2.length - 1],
      result.$2[result.$2.length - 2],
    );
  } finally {
    det.close();
  }
  if (boxes.length > 64) throw const AiException(AiFailure.invalidInput);
  final chars = (jsonDecode(await File(dictionary).readAsString()) as List)
      .cast<String>();
  final rec = FloatSession(recognizer);
  final lines = <OcrLine>[];
  try {
    for (final box in boxes) {
      final x = (box[0] * original.width).floor(),
          y = (box[1] * original.height).floor();
      final cw = math.max(1, (box[2] * original.width).ceil() - x),
          ch = math.max(1, (box[3] * original.height).ceil() - y);
      final crop = img.copyCrop(original, x: x, y: y, width: cw, height: ch);
      final width = (48 * cw / ch).ceil().clamp(1, 320);
      final resized = img.copyResize(
        crop,
        width: width,
        height: 48,
        interpolation: img.Interpolation.linear,
      );
      final tensor = Float32List(3 * 48 * 320);
      for (var py = 0; py < 48; py++) {
        for (var px = 0; px < width; px++) {
          final pixel = resized.getPixel(px, py);
          tensor[py * 320 + px] = pixel.b / 127.5 - 1;
          tensor[48 * 320 + py * 320 + px] = pixel.g / 127.5 - 1;
          tensor[2 * 48 * 320 + py * 320 + px] = pixel.r / 127.5 - 1;
        }
      }
      final result = rec.run(tensor, [1, 3, 48, 320]);
      final decoded = decodeCtc(result.$1, result.$2, chars);
      if (decoded.$1.trim().isNotEmpty) {
        lines.add(OcrLine(decoded.$1, decoded.$2, List.unmodifiable(box)));
      }
    }
  } finally {
    rec.close();
  }
  return OcrDraft(lines);
}

(String, double) decodeCtc(
  List<double> values,
  List<int> shape,
  List<String> chars,
) {
  if (shape.length != 3 ||
      shape[0] != 1 ||
      shape[2] != chars.length ||
      values.length != shape[1] * shape[2]) {
    throw const AiException(AiFailure.modelInvalid);
  }
  var previous = -1, count = 0;
  var sum = 0.0;
  final text = StringBuffer();
  for (var t = 0; t < shape[1]; t++) {
    var index = 0, confidence = values[t * chars.length];
    for (var c = 1; c < chars.length; c++) {
      if (values[t * chars.length + c] > confidence) {
        index = c;
        confidence = values[t * chars.length + c];
      }
    }
    if (index != 0 && index != previous) {
      text.write(chars[index]);
      sum += confidence;
      count++;
    }
    previous = index;
  }
  return (text.toString(), count == 0 ? 0 : sum / count);
}

/// Bounded connected components on DB probability maps. Axis-aligned crops;
/// rotated/vertical text is not claimed as supported by this first adapter.
List<List<double>> textBoxes(List<double> map, int width, int height) {
  if (width < 1 ||
      height < 1 ||
      width * height != map.length ||
      map.length > 1024 * 1024) {
    throw const AiException(AiFailure.modelInvalid);
  }
  final visited = Uint8List(map.length), queue = Int32List(map.length);
  final boxes = <List<double>>[];
  for (var start = 0; start < map.length; start++) {
    if (visited[start] != 0 || map[start] < .3) continue;
    var read = 0, end = 1, minX = width, minY = height, maxX = 0, maxY = 0;
    var score = 0.0;
    queue[0] = start;
    visited[start] = 1;
    while (read < end) {
      final i = queue[read++], x = i % width, y = i ~/ width;
      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
      score += map[i];
      for (final next in [
        if (x > 0) i - 1,
        if (x + 1 < width) i + 1,
        if (y > 0) i - width,
        if (y + 1 < height) i + width,
      ]) {
        if (visited[next] == 0 && map[next] >= .3) {
          visited[next] = 1;
          queue[end++] = next;
        }
      }
    }
    final bw = maxX - minX + 1, bh = maxY - minY + 1;
    if (bw < 3 || bh < 3 || score / end < .6) continue;
    final pad = bw * bh * 1.5 / (2 * (bw + bh));
    boxes.add([
      (minX - pad).clamp(0, width - 1) / width,
      (minY - pad).clamp(0, height - 1) / height,
      (maxX + 1 + pad).clamp(1, width) / width,
      (maxY + 1 + pad).clamp(1, height) / height,
    ]);
    if (boxes.length > 64) break;
  }
  if (boxes.length > 64) throw const AiException(AiFailure.invalidInput);
  return mergeHorizontalBoxes(boxes, width, height);
}

/// DB may split one line into words. Merge only nearby boxes with substantial
/// vertical overlap before recognition, preserving separate rows/columns.
List<List<double>> mergeHorizontalBoxes(
  List<List<double>> boxes,
  int width,
  int height,
) {
  final pixels =
      boxes
          .map(
            (b) => [b[0] * width, b[1] * height, b[2] * width, b[3] * height],
          )
          .toList()
        ..sort((a, b) => a[0].compareTo(b[0]));
  final lines = <List<double>>[];
  for (final box in pixels) {
    List<double>? match;
    for (final line in lines) {
      final overlap = math.min(box[3], line[3]) - math.max(box[1], line[1]);
      final smallHeight = math.min(box[3] - box[1], line[3] - line[1]);
      final largeHeight = math.max(box[3] - box[1], line[3] - line[1]);
      if (overlap >= smallHeight * .65 &&
          box[0] - line[2] <= largeHeight * 1.5) {
        match = line;
        break;
      }
    }
    if (match == null) {
      lines.add(box);
    } else {
      match[0] = math.min(match[0], box[0]);
      match[1] = math.min(match[1], box[1]);
      match[2] = math.max(match[2], box[2]);
      match[3] = math.max(match[3], box[3]);
    }
  }
  lines.sort((a, b) {
    final y = a[1].compareTo(b[1]);
    return y == 0 ? a[0].compareTo(b[0]) : y;
  });
  return lines
      .map((b) => [b[0] / width, b[1] / height, b[2] / width, b[3] / height])
      .toList();
}
