import 'dart:convert';
import 'dart:io';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';

import '../../domain/ai.dart';

final class LocalChatEngine {
  bool _cancelled = false;
  Future<String> extract(
    String model,
    String promptPath,
    String question,
  ) async {
    _cancelled = false;
    // Reject template delimiters from untrusted input before parseSpecial=true.
    if (question.length > 1200 ||
        question.contains('<|') ||
        question.contains('|>')) {
      throw const AiException(AiFailure.invalidInput);
    }
    final template = jsonDecode(await File(promptPath).readAsString()) as Map;
    final params = ModelParams(path: model, gpuLayers: 0);
    const context = ContextParams(
      nCtx: 2048,
      nBatch: 256,
      nUbatch: 64,
      nThreads: 2,
      nThreadsBatch: 2,
      offloadKqv: false,
    );
    final engine = Platform.isIOS
        ? await LlamaEngine.spawnFromProcess(
            modelParams: params,
            contextParams: context,
          )
        : await LlamaEngine.spawn(modelParams: params, contextParams: context);
    try {
      if (_cancelled) throw const AiException(AiFailure.cancelled);
      final session = await engine.createSession();
      final result = StringBuffer();
      try {
        await for (final event in session.generate(
          prompt: '${template['prefix']}$question${template['suffix']}',
          addSpecial: true,
          sampler: const SamplerParams(
            greedy: true,
            temperature: 0,
            repeatPenalty: 1,
          ),
          maxTokens: 160,
        )) {
          if (_cancelled) throw const AiException(AiFailure.cancelled);
          if (event is TokenEvent) result.write(event.text);
          if (event is DoneEvent) result.write(event.trailingText);
          if (result.length > 4096) throw const AiException(AiFailure.failed);
        }
        return result.toString();
      } finally {
        if (!engine.isDisposed) await session.dispose();
      }
    } finally {
      await engine.dispose();
    }
  }

  void cancel() {
    _cancelled = true;
    // Let the current bounded native step finish. The next event cancels the
    // stream, then the finally blocks release session/model in order. Calling
    // engine.dispose here can kill the worker while it still owns native memory.
  }
}
