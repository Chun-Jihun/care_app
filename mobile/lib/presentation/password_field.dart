import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';

/// A wrapping label stays distinct even with a narrow screen and large text.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    required this.label,
  });
  final TextEditingController controller;
  final String label;
  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool visible = false;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(widget.label),
      const SizedBox(height: 8),
      Semantics(
        label: widget.label,
        child: TextFormField(
          controller: widget.controller,
          obscureText: !visible,
          keyboardType: TextInputType.visiblePassword,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          decoration: InputDecoration(
            suffixIcon: IconButton(
              tooltip: context.tr(visible ? '비밀번호 숨기기' : '비밀번호 보기'),
              onPressed: () => setState(() => visible = !visible),
              icon: Icon(
                visible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
          ),
        ),
      ),
    ],
  );
}
