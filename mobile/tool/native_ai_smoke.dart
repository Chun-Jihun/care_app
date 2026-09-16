// Development-only entry point. Uses public/synthetic fixtures, never the vault.
// This file is not reachable from lib/main.dart or the shipping user interface.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:care_notebook/infrastructure/ai/device_ai_runtime.dart';
import 'package:care_notebook/application/ai_query_policy.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Public fixture AI validation'))),
    ),
  );
  final root = (await getApplicationSupportDirectory()).path;
  final report = File('$root/native-ai-report.json');
  // This entry point handles public fixtures only. Never enable stderr capture
  // in the production application, which can contain sensitive input.
  LlamaLibrary.load(path: 'libllama.so');
  LlamaLog.captureToFile('$root/public-native.log');
  final results = <String, Object?>{
    'status': 'running',
    'medical_release_gate_result': false,
    'checks': <Object>[],
  };
  Future<void> save() async {
    await report.writeAsString(jsonEncode(results), flush: true);
  }

  final ai = DeviceAiRuntime();
  await save();
  try {
    if (!(await ai.status()).installed) {
      await ai.installBundle('$root/smoke.careai', (_) {});
    }
    final fixtures = jsonDecode(
      await File('$root/smoke/fixtures.json').readAsString(),
    ) as Map;
    for (final row in fixtures['cases'] as List) {
      final started = Stopwatch()..start();
      final result = <String, Object?>{
        'id': row['id'],
        'task': row['task'],
        'language': row['language'],
        'pass_criterion': row['task'] == 'chat' ? 'exact_filter' :
            row['task'] == 'silence' ? 'no_speech_rejection' : 'nonempty_native_output',
      };
      try {
        switch (row['task']) {
          case 'chat':
            final raw = await ai.extractQuery(
              row['question'] as String,
              row['language'] as String,
            );
            final filter = AiQueryPolicy.parse(raw, row['question'] as String);
            result['output'] = raw;
            result['passed'] =
                filter != null &&
                filter.item == row['item'] &&
                filter.at == DateTime(2026, 9, 11, 9, 30);
          case 'ocr':
            final draft = await ai.recognize(
              await File('$root/smoke/${row['file']}').readAsBytes(),
              row['language'] as String,
            );
            result['output'] = draft.text;
            result['reference'] = row['reference'];
            result['line_count'] = draft.lines.length;
            result['passed'] = draft.lines.isNotEmpty;
          case 'speech':
            sherpa.initBindings();
            final wave = sherpa.readWave('$root/smoke/${row['file']}');
            if (wave.sampleRate != 16000) {
              throw StateError('Fixture sample rate');
            }
            result['output'] = await ai.transcribe(
              wave.samples,
              row['language'] as String,
            );
            result['reference'] = row['reference'];
            result['passed'] = (result['output'] as String).isNotEmpty;
          case 'silence':
            try {
              await ai.transcribe(Float32List(16000 * 3), 'ko');
              result['passed'] = false;
            } catch (e) {
              result['passed'] = e.toString() == 'AiException(noSpeech)';
            }
        }
      } catch (e) {
        result['passed'] = false;
        result['error'] = e.toString();
      }
      result['milliseconds'] = started.elapsedMilliseconds;
      (results['checks'] as List).add(result);
      await save();
    }
    final pending = ai.extractQuery('2026-09-11 09:30 혈압', 'ko').then(
      (_) => false, onError: (Object e) => e.toString() == 'AiException(cancelled)');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    var busyRejected = false;
    try { await ai.extractQuery('2026-09-11 09:30 혈압', 'ko'); }
    catch (e) { busyRejected = e.toString() == 'AiException(busy)'; }
    final cancelledAt = Stopwatch()..start();
    ai.cancel();
    final cancelled = await pending;
    final cancelMilliseconds = cancelledAt.elapsedMilliseconds;
    var released = false;
    for (var i=0; i<40; i++) {
      try {
        await ai.recognize(await File('$root/smoke/ocr-en.png').readAsBytes(), 'en');
        released = true; break;
      } catch (e) {
        if (e.toString() != 'AiException(busy)') rethrow;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    (results['checks'] as List).add({
      'id':'native-cancel-and-reuse', 'task':'control',
      'passed':busyRejected && cancelled && released,
      'busy_rejected':busyRejected,'cancelled':cancelled,'native_resources_reusable':released,
      'cancel_milliseconds':cancelMilliseconds,
    });
    results['status'] = 'completed';
  } catch (e) {
    results['status'] = 'failed';
    results['error'] = e.toString();
  } finally {
    await ai.dispose();
    await save();
  }
}
