import 'dart:convert';
import 'dart:io';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';

import '../../domain/ai.dart';
import '../../domain/medical_evidence.dart';
import '../../domain/evidence_selection_prompt.dart';

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
    return _generate(
      model,
      '${template['prefix']}$question${template['suffix']}',
    );
  }

  Future<String> selectEvidence(
    String model,
    String question,
    List<ReviewedPassage> passages,
  ) {
    _cancelled = false;
    return _generate(
      model,
      evidenceSelectionPrompt(question, passages),
      contextSize: 4096,
    );
  }

  Future<String> _generate(
    String model,
    String prompt, {
    int contextSize = 2048,
  }) async {
    final params = ModelParams(path: model, gpuLayers: 0);
    final context = ContextParams(
      nCtx: contextSize,
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
          prompt: prompt,
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
