import 'package:flutter/material.dart';

/// Announce brief status changes, never the full record or AI response.
class StatusMessage extends StatelessWidget {
  const StatusMessage(this.message, {super.key, this.isError = false});
  final String message;
  final bool isError;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(
      message,
      style: isError
          ? TextStyle(color: Theme.of(context).colorScheme.error)
          : null,
    ),
  );
}
