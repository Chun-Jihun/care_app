import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/records.dart';
import '../l10n/app_strings.dart';
import 'editors.dart';

Future<void> chooseIntake(BuildContext context, CareController c) async {
  final session = c.captureSession();
  final medications = c.medications;
  final choice = await Navigator.of(
    context,
  ).push<String>(MaterialPageRoute(builder: (_) => _IntakePicker(medications)));
  if (choice == null || !context.mounted) return;
  c.requireSession(session);
  if (choice == 'manual') {
    await editEntry(context, c, EntryKind.medicationIntake);
  } else {
    final medication = c.medications.where((m) => m.id == choice).firstOrNull;
    if (medication != null) await recordIntake(context, c, medication);
  }
}

class _IntakePicker extends StatefulWidget {
  const _IntakePicker(this.medications);
  final List<Medication> medications;
  @override
  State<_IntakePicker> createState() => _IntakePickerState();
}

class _IntakePickerState extends State<_IntakePicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final medications = widget.medications
        .where((m) => m.name.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('어떤 약을 기록할까요?'))),
      body: ListView.builder(
        padding: const EdgeInsets.all(20),
        itemCount: medications.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: InputDecoration(
                    labelText: context.tr('약 이름 검색'),
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (value) => setState(() => query = value),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => Navigator.pop(context, 'manual'),
                  child: Text(context.tr('목록에 없는 약 직접 입력')),
                ),
                if (medications.isEmpty)
                  Text(context.tr('일치하는 약이 없어요. 직접 입력할 수 있습니다.')),
              ],
            );
          }
          final m = medications[index - 1];
          return Card(
            child: ListTile(
              title: Text(m.name),
              subtitle: m.instruction.isEmpty
                  ? null
                  : Text(
                      m.instruction,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pop(context, m.id),
            ),
          );
        },
      ),
    );
  }
}
