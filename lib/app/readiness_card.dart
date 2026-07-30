import 'package:flutter/material.dart';

import 'radio_readiness.dart';

/// Tells the user exactly what is stopping the mesh, and gives them the button
/// that fixes it.
///
/// Every blocker produces the same symptom — zero peers — so without this the
/// app just looks broken. "Bluetooth is off, turn it on" is something a
/// frightened person can act on; an empty peer list is not.
class ReadinessCard extends StatelessWidget {
  const ReadinessCard({
    super.key,
    required this.blockers,
    required this.onFixed,
  });

  final List<Blocker> blockers;
  final VoidCallback onFixed;

  @override
  Widget build(BuildContext context) {
    if (blockers.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final first = blockers.first;

    return Card(
      color: scheme.errorContainer,
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber, color: scheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    first.title,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(first.detail,
                style: TextStyle(color: scheme.onErrorContainer)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () async {
                switch (first) {
                  case Blocker.permissions:
                    await RadioReadiness.requestPermissions();
                  case Blocker.bluetooth:
                    await RadioReadiness.requestBluetooth();
                  case Blocker.location:
                    await RadioReadiness.openLocationSettings();
                }
                onFixed();
              },
              icon: Icon(switch (first) {
                Blocker.permissions => Icons.lock_open,
                Blocker.bluetooth => Icons.bluetooth,
                Blocker.location => Icons.location_on,
              }),
              label: Text(switch (first) {
                Blocker.permissions => 'Grant permissions',
                Blocker.bluetooth => 'Turn on Bluetooth',
                Blocker.location => 'Open location settings',
              }),
            ),
            if (blockers.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  // One at a time. A list of four problems is paralysing; the
                  // next one appears as soon as this is fixed.
                  '${blockers.length - 1} more to fix after this',
                  style: TextStyle(
                      fontSize: 11, color: scheme.onErrorContainer),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Asked once on first launch. A name is the difference between "70E04E1A sent
/// an SOS" and "Niloy sent an SOS".
class NamePrompt extends StatefulWidget {
  const NamePrompt({super.key, required this.onSubmit});

  final ValueChanged<String> onSubmit;

  @override
  State<NamePrompt> createState() => _NamePromptState();
}

class _NamePromptState extends State<NamePrompt> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('What should people call you?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Shown to people nearby instead of your ID. You can change it '
              'later.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 24,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                hintText: 'e.g. Niloy',
                border: OutlineInputBorder(),
                counterText: '',
              ),
              onSubmitted: widget.onSubmit,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => widget.onSubmit(''),
            child: const Text('Skip'),
          ),
          FilledButton(
            onPressed: () => widget.onSubmit(_controller.text),
            child: const Text('Save'),
          ),
        ],
      );
}
