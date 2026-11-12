import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import 'common.dart';

Future<bool> confirmAiInput(BuildContext context, {required bool photo}) =>
    confirm(
      context,
      context.tr('AI 인식 사용 전 확인해 주세요'),
      context.tr(
        photo
            ? 'AI가 사진 속 글자를 잘못 읽거나 일부 내용을 빠뜨릴 수 있어요. 원본 사진과 대조해 약 이름·용량·숫자·단위를 확인하고, 틀린 부분은 고쳐 주세요.'
            : 'AI가 음성을 글로 옮길 때 단어나 문장이 틀리거나 빠질 수 있어요. 원래 말한 내용과 대조해 약 이름·숫자·단위와 말의 뜻을 확인하고, 틀린 부분은 고쳐 주세요.',
      ),
      action: context.tr('확인하고 시작'),
    );
