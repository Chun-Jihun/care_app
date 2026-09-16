import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerAiLicenses() {
  for (final name in [
    'Qwen',
    'PaddleOCR',
    'Whisper',
    'Silero',
    'ONNXRuntime',
    'llama.cpp',
  ]) {
    LicenseRegistry.addLicense(() async* {
      final text = await rootBundle.loadString('assets/ai/licenses/$name.txt');
      yield LicenseEntryWithLineBreaks([name], text);
    });
  }
}
