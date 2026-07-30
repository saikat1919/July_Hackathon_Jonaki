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

  /// A custom SOS with no description is not actionable, so it cannot be sent.
  /// Every other type is fine without one — the icon already says enough.
  bool get _ready {
    final k = _kind;
    if (k == null) return false;
    if (k.needsNote && _note.text.trim().isEmpty) return false;
    return true;
  }

  Future<void> _send() async {
    if (!_ready || _sending) return;
    setState(() => _sending = true);
    await HapticFeedback.heavyImpact();
    await widget.mesh.sendSos(kind: _kind!, note: _note.text);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        // Scrollable so nothing is ever clipped: six type buttons plus the
        // note field plus the keyboard already overflow a short screen, and a
        // send button you cannot reach is the worst possible failure here.
        child: SingleChildScrollView(
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
              autofocus: _kind?.needsNote ?? false,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: (_kind?.needsNote ?? false)
                    ? 'What is happening? (required)'
                    : 'Note (optional)',
                hintText: (_kind?.needsNote ?? false)
                    ? 'e.g. trapped under rubble, two people'
                    : 'e.g. second floor, water rising',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: !_ready || _sending ? null : _send,
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
            if ((_kind?.needsNote ?? false) && _note.text.trim().isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Describe the emergency so people know what help to bring.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12),
                ),
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
        ),
      );
}

/// The SOS tab. Raise one, cancel your own, and see what is live nearby.
/// Deliberately sparse: this is the screen someone opens in a bad moment.
class SosTab extends StatefulWidget {
  const SosTab({super.key, required this.mesh, required this.contacts});

  final MeshService mesh;
  final Contacts contacts;

  @override
  State<SosTab> createState() => _SosTabState();
}

class _SosTabState extends State<SosTab> {
  List<Envelope> _alerts = const [];

  @override
  void initState() {
    super.initState();
    widget.mesh.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.mesh.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final a = await widget.mesh.activeSosAlerts();
    if (mounted) setState(() => _alerts = a);
  }

  @override
  Widget build(BuildContext context) {
    final mesh = widget.mesh;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed:
                mesh.running ? () => SosSheet.show(context, mesh) : null,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 28),
            ),
            icon: const Icon(Icons.emergency_share, size: 30),
            label: const Text('SOS  ·  জরুরি',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 6),
          Text(
            mesh.running
                ? 'Sends your location, the type of emergency and your battery '
                    'level to every phone the mesh can reach. Relayed ahead of '
                    'all other traffic.'
                : 'The mesh is not running yet.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          if (mesh.mySosIds.isNotEmpty) ...[
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () async {
                await mesh.cancelSos(mesh.mySosIds.last);
                await _reload();
              },
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              icon: const Icon(Icons.check_circle_outline),
              label: const Text("I'm safe now — cancel my SOS"),
            ),
          ],
          const Divider(height: 32),
          Text('Alerts nearby',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Expanded(
            child: _alerts.isEmpty
                ? const Center(
                    child: Text('No one nearby has called for help.'))
                : ListView.builder(
                    itemCount: _alerts.length,
                    itemBuilder: (_, i) {
                      final e = _alerts[i];
                      final sos = SosPayload.fromJson(decodePayload(e.payload));
                      final fp = e.senderFingerprint;
                      return Card(
                        color: Colors.red.shade900,
                        child: ListTile(
                          leading: Text(sos.kind.emoji,
                              style: const TextStyle(fontSize: 28)),
                          title: Text(
                            '${sos.headline} · '
                            '${widget.contacts.isAnonymous(fp) ? 'Name unknown' : widget.contacts.nameFor(fp)}',
                            style:
                                const TextStyle(fontWeight: FontWeight.bold),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          // ID always visible: it is the part that cannot be
                          // faked, and it is how you tell two people apart.
                          subtitle: Text('ID $fp · ${sos.locationLabel}',
                              style: const TextStyle(fontSize: 11)),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => SosAlertScreen(
                                  envelope: e, contacts: widget.contacts),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
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
    final fp = e.senderFingerprint;
    final contacts = widget.contacts;
    // Whoever is in danger, say who as loudly as the data allows. The ID is
    // ALWAYS shown alongside the name: it is the part that cannot be faked,
    // and a rescuer comparing it against a contact list needs to see it.
    final anonymous = contacts.isAnonymous(fp);
    final selfDeclared = contacts.isSelfDeclared(fp);
    final sender = anonymous ? 'Name unknown' : contacts.nameFor(fp);
    final idLine = selfDeclared
        ? 'ID $fp · name they gave themselves'
        : anonymous
            ? 'ID $fp · nobody has named this person yet'
            : 'ID $fp';

    return Scaffold(
      backgroundColor: Colors.red.shade900,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(sos.kind.emoji, style: const TextStyle(fontSize: 56)),
              // For a custom SOS the person's own words are the emergency, so
              // they get the headline instead of a generic label.
              Text('SOS · ${sos.headline.toUpperCase()}',
                  style: TextStyle(
                      fontSize: sos.headline.length > 28 ? 22 : 30,
                      fontWeight: FontWeight.bold)),
              Text(sos.kind.bangla, style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 16),
              _row(Icons.person, sender, sub: idLine),
              // Signature is the real trust claim, so it gets said plainly.
              _row(Icons.verified_user, 'Signature verified',
                  sub: 'this message was not altered in transit'),
              _row(Icons.place, sos.locationLabel),
              // Skipped for a custom SOS: the note is already the headline, and
              // repeating it wastes a line on a screen read in a hurry.
              if (sos.kind != SosKind.other &&
                  sos.note != null &&
                  sos.note!.isNotEmpty)
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
