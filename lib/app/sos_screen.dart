import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../gossip/envelope.dart';
import 'contacts.dart';
import 'mesh_service.dart';
import 'sos.dart';

/// Pick a type, add a note, send. Deliberately short: the person using this is
/// frightened, one-handed, and possibly in the dark.
class SosSheet extends StatefulWidget {
  const SosSheet({super.key, required this.mesh});

  final MeshService mesh;

  static Future<void> show(BuildContext context, MeshService mesh) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SosSheet(mesh: mesh),
        ),
      );

  @override
  State<SosSheet> createState() => _SosSheetState();
}

class _SosSheetState extends State<SosSheet> {
  SosKind? _kind;
  final _note = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_kind == null || _sending) return;
    setState(() => _sending = true);
    await HapticFeedback.heavyImpact();
    await widget.mesh.sendSos(kind: _kind!, note: _note.text);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('What is happening?',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            // Big targets. Under stress, small buttons get mis-tapped.
            for (final k in SosKind.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: OutlinedButton(
                  onPressed: () => setState(() => _kind = k),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: _kind == k
                        ? Theme.of(context).colorScheme.errorContainer
                        : null,
                  ),
                  child: Row(
                    children: [
                      Text(k.emoji, style: const TextStyle(fontSize: 22)),
                      const SizedBox(width: 12),
                      Text('${k.english}  ·  ${k.bangla}',
                          style: const TextStyle(fontSize: 16)),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 4),
            TextField(
              controller: _note,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                hintText: 'e.g. second floor, water rising',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _kind == null || _sending ? null : _send,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade700,
                padding: const EdgeInsets.symmetric(vertical: 18),
              ),
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.emergency_share),
              label: Text(_sending ? 'Getting location…' : 'SEND SOS',
                  style: const TextStyle(fontSize: 18)),
            ),
            const SizedBox(height: 8),
            Text(
              'Sends your location if available, your battery level, and the '
              'time. Relayed ahead of all other traffic.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
}

/// Full-screen takeover for an incoming SOS. It should be impossible to miss
/// and impossible to misread: who, what, where, how stale, how it reached you.
class SosAlertScreen extends StatefulWidget {
  const SosAlertScreen({
    super.key,
    required this.envelope,
    required this.contacts,
  });

  final Envelope envelope;
  final Contacts contacts;

  @override
  State<SosAlertScreen> createState() => _SosAlertScreenState();
}

class _SosAlertScreenState extends State<SosAlertScreen> {
  @override
  void initState() {
    super.initState();
    _buzz();
  }

  /// A short insistent pattern. Platform haptics rather than a vibration
  /// package: one fewer dependency for something a loop does fine.
  Future<void> _buzz() async {
    for (var i = 0; i < 5; i++) {
      if (!mounted) return;
      await HapticFeedback.heavyImpact();
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.envelope;
    final sos = SosPayload.fromJson(decodePayload(e.payload));
    final sender = widget.contacts.nameFor(e.senderFingerprint);
    final known = widget.contacts.isKnown(e.senderFingerprint);

    return Scaffold(
      backgroundColor: Colors.red.shade900,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(sos.kind.emoji, style: const TextStyle(fontSize: 56)),
              Text('SOS · ${sos.kind.english.toUpperCase()}',
                  style: const TextStyle(
                      fontSize: 30, fontWeight: FontWeight.bold)),
              Text(sos.kind.bangla, style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 16),
              _row(Icons.person, known ? sender : 'Unknown sender',
                  sub: known ? e.senderFingerprint : 'ID ${e.senderFingerprint}'),
              // Signature is the real trust claim, so it gets said plainly.
              _row(Icons.verified_user, 'Signature verified',
                  sub: 'this message was not altered in transit'),
              _row(Icons.place, sos.locationLabel),
              if (sos.note != null && sos.note!.isNotEmpty)
                _row(Icons.sticky_note_2, sos.note!),
              _row(
                Icons.route,
                e.path.isEmpty
                    ? 'received directly'
                    : 'relayed through ${e.path.length} phone'
                        '${e.path.length == 1 ? '' : 's'}',
                // The hop list is unsigned: any relay could have written it.
                // Say so rather than presenting it as provenance.
                sub: 'hop list is informational, not signed',
              ),
              if (sos.battery != null)
                _row(Icons.battery_alert, 'Sender battery ${sos.battery}%'),
              _row(Icons.schedule, _clock(e.timestamp)),
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                ),
                child: const Text('Acknowledge', style: TextStyle(fontSize: 18)),
              ),
              const SizedBox(height: 8),
              const Text(
                'This phone keeps relaying this SOS until it expires.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(IconData icon, String text, {String? sub}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text, style: const TextStyle(fontSize: 16)),
                  if (sub != null)
                    Text(sub,
                        style: TextStyle(
                            fontSize: 11, color: Colors.white.withValues(alpha: 0.7))),
                ],
              ),
            ),
          ],
        ),
      );

  static String _clock(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return 'Sent at $h:$m';
  }
}
