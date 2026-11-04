import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../l10n/app_strings.dart';
import 'common.dart';

class ContactAction extends StatelessWidget {
  const ContactAction(this.c, {super.key});
  final CareController c;
  void open(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: contactCard(context, c),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.sizeOf(context).width < 340 ||
        (MediaQuery.sizeOf(context).width < 480 &&
            MediaQuery.textScalerOf(context).scale(14) > 21);
    if (compact) {
      return IconButton(
        tooltip: context.tr('연락'),
        onPressed: () => open(context),
        icon: const Icon(Icons.call_outlined),
      );
    }
    return TextButton.icon(
      icon: const Icon(Icons.call_outlined),
      label: Text(context.tr('연락')),
      onPressed: () => open(context),
    );
  }
}

Widget contactCard(BuildContext context, CareController c, {String? contact}) {
  final number = contact ?? c.patient.contact;
  return Card(
    child: Column(
      children: [
        if (number.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.call_outlined, color: forest),
            title: Text(context.tr('저장한 의료기관')),
            subtitle: Text(number),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => attempt(context, () => c.openDialer(number)),
          ),
        ListTile(
          leading: const Icon(
            Icons.emergency_outlined,
            color: Color(0xFFAA5140),
          ),
          title: Text(context.tr('위급할 때 119 (대한민국)')),
          subtitle: Text(context.tr('기록보다 의료기관 연락이 먼저예요.')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => attempt(context, () => c.openDialer('119')),
        ),
      ],
    ),
  );
}
