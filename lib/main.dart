import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/chat_screen.dart';
import 'app/contacts.dart';
import 'app/map_screen.dart';
import 'app/mesh_service.dart';
import 'app/radio_readiness.dart';
import 'app/readiness_card.dart';
import 'app/sos_screen.dart';
import 'gossip/envelope.dart';

/// Which radio network this build joins.
///
/// The APK handed to judges MUST NOT share a serviceId with the demo phones.
/// Judges install during judging, their phones start advertising, and suddenly
/// the demo is running in a cluster of six or eight advertisers — which is the
/// top known Nearby failure mode, arriving at the worst possible moment.
///
///   flutter build apk --release --split-per-abi
///       → public build, what judges install
///   flutter build apk --release --split-per-abi --dart-define=DEMO_BUILD=true
///       → demo build, invisible to the public one
///
/// Public is the DEFAULT on purpose: forgetting the flag gives judges a
/// correct APK, whereas the reverse would put them in your cluster. The Mesh
/// tab shows which variant is installed, so it is checkable at a glance rather
/// than a thing you have to remember.
const bool kDemoBuild = bool.fromEnvironment('DEMO_BUILD');

const String kServiceId =
    kDemoBuild ? 'bd.july.crisis_mesh.demo' : 'bd.july.crisis_mesh';

void main() => runApp(const CrisisMeshApp());

class CrisisMeshApp extends StatelessWidget {
  const CrisisMeshApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Jonaki',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const HomeShell(),
      );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final mesh = MeshService(serviceId: kServiceId);
  final contacts = Contacts();
  int _tab = 0;

  List<Blocker> _blockers = const [];
  bool _booting = true;

  @override
  void initState() {
    super.initState();
    mesh.addListener(_refresh);
    contacts.addListener(_refresh);
    mesh.contacts = contacts;
    mesh.keys.addListener(_refresh);
    // An SOS that needs you to be looking at the right tab is not an alert.
    mesh.incomingSos.listen(_raiseAlert);
    _boot();
  }

  /// Everything a user should never have to ask for: load state, get the
  /// radios ready, and start the mesh. Nobody opens a crisis communication app
  /// and then wants to hunt for a play button.
  Future<void> _boot() async {
    await contacts.load();
    await mesh.keys.load();
    await mesh.bootIdentity();

    final prefs = await SharedPreferences.getInstance();
    final savedName = prefs.getString(_nameKey);
    if (savedName != null) mesh.myName = savedName;

    if (mounted) setState(() => _booting = false);

    await _startWhenReady();

    if (savedName == null && mounted) await _askName(prefs);
  }

  /// Checks the radios, starts if clear, and shows exactly what is blocking if
  /// not. Re-run every time the user fixes something.
  Future<void> _startWhenReady() async {
    final blockers = await RadioReadiness.check();
    if (!mounted) return;
    setState(() => _blockers = blockers);
    if (blockers.isEmpty && !mesh.running) await mesh.start();
  }

  Future<void> _askName(SharedPreferences prefs) async {
    final name = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => NamePrompt(onSubmit: (v) => Navigator.pop(ctx, v)),
    );
    await prefs.setString(_nameKey, name ?? '');
    await mesh.setMyName(name ?? '');
  }

  static const _nameKey = 'my.name';

  Future<void> _raiseAlert(Envelope e) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => SosAlertScreen(envelope: e, contacts: contacts),
      ),
    );
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    mesh.removeListener(_refresh);
    mesh.keys.removeListener(_refresh);
    contacts.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          // Long-press the title for diagnostics. Kept out of the way rather
          // than deleted: still needed for rehearsal, but a scrolling debug
          // log is not what a judge should find in a crisis app.
          title: GestureDetector(
            onLongPress: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: Text('Diagnostics · ${mesh.fingerprint}')),
                  body: MeshScreen(mesh: mesh),
                ),
              ),
            ),
            child: Text(switch (_tab) {
              0 => 'Jonaki · Chat',
              1 => 'Jonaki · Map',
              _ => 'Jonaki · SOS',
            }),
          ),
          actions: [
            // Peer count belongs on every screen: it is the one number that
            // tells you whether anything you send can go anywhere.
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                // Plain language: "0 peers" reads as an error code. "No one
                // nearby" is a fact a user can understand and act on.
                child: Text(
                  mesh.peers.isEmpty
                      ? 'No one nearby'
                      : '${mesh.peers.length} nearby',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
            IconButton(
              tooltip: mesh.running ? 'stop mesh' : 'start mesh',
              icon: Icon(mesh.running ? Icons.stop : Icons.play_arrow),
              onPressed: () => mesh.running ? mesh.stop() : mesh.start(),
            ),
          ],
        ),
        // No floating SOS button: it sat on top of the chat send button.
        // SOS lives on its own tab instead, which keeps it one tap away
        // without covering anything.
        body: _booting
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  ReadinessCard(
                    blockers: _blockers,
                    onFixed: _startWhenReady,
                  ),
                  if (mesh.keys.conflicts.isNotEmpty)
                    _KeyConflictBanner(
                      fingerprints: mesh.keys.conflicts,
                      contacts: contacts,
                    ),
                  Expanded(
                    child: switch (_tab) {
                      0 => ChatScreen(mesh: mesh, contacts: contacts),
                      1 => MapScreen(mesh: mesh, contacts: contacts),
                      _ => SosTab(mesh: mesh, contacts: contacts),
                    },
                  ),
                ],
              ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.forum), label: 'Chat'),
            NavigationDestination(icon: Icon(Icons.map), label: 'Map'),
            NavigationDestination(
                icon: Icon(Icons.emergency_share, color: Colors.redAccent),
                label: 'SOS'),
          ],
        ),
      );
}

/// Someone sent a key that clashes with one already pinned for that ID.
///
/// That is either a rare fingerprint collision or somebody trying to take over
/// a conversation. The app already refuses the new key; this makes the refusal
/// visible, because a silent security event is not much of a security feature.
class _KeyConflictBanner extends StatelessWidget {
  const _KeyConflictBanner({
    required this.fingerprints,
    required this.contacts,
  });

  final Set<String> fingerprints;
  final Contacts contacts;

  @override
  Widget build(BuildContext context) {
    final names = fingerprints.map(contacts.nameFor).join(', ');
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.gpp_maybe, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Identity conflict',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Text(
                    'Someone claiming to be $names sent a different key. '
                    'The original is still trusted and the new one was '
                    'refused. Treat messages from them with suspicion.',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Diagnostics and demo controls. This is the screen the day-2 gate runs on.
class MeshScreen extends StatelessWidget {
  const MeshScreen({super.key, required this.mesh});

  final MeshService mesh;

  @override
  Widget build(BuildContext context) {
    final err = mesh.startupError;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Which build this is, stated plainly. Two APKs that look identical
          // but cannot see each other is exactly the kind of confusion that
          // eats twenty minutes on demo day.
          Card(
            color: kDemoBuild
                ? Theme.of(context).colorScheme.tertiaryContainer
                : null,
            child: ListTile(
              dense: true,
              leading: Icon(kDemoBuild ? Icons.science : Icons.public),
              title: Text(kDemoBuild ? 'DEMO build' : 'Public build'),
              subtitle: Text(
                kDemoBuild
                    ? 'Only sees other demo builds. Not for judges.'
                    : 'The build to distribute. Sees other public builds.',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _StatusStrip(mesh: mesh),
          if (err != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(err),
                ),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed:
                mesh.running ? () => SosSheet.show(context, mesh) : null,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              padding: const EdgeInsets.symmetric(vertical: 20),
            ),
            icon: const Icon(Icons.emergency_share),
            label: const Text('SOS  ·  জরুরি', style: TextStyle(fontSize: 20)),
          ),
          if (mesh.mySosIds.isNotEmpty) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => mesh.cancelSos(mesh.mySosIds.last),
              icon: const Icon(Icons.check_circle_outline),
              label: const Text("I'm safe — cancel my SOS"),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: mesh.running ? mesh.floodChat : null,
                child: const Text('queue 50 chat'),
              ),
              OutlinedButton(
                onPressed: mesh.running ? mesh.sweepNow : null,
                child: const Text('sweep expired'),
              ),
            ],
          ),
          const Divider(height: 24),
          Expanded(
            child: ListView(
              children: [
                for (final line in mesh.log)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text('· $line',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.mesh});

  final MeshService mesh;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _stat(context, 'peers', '${mesh.peers.length}'),
              _stat(context, 'inbox', '${mesh.inbox.length}'),
              _stat(context, 'syncs', '${mesh.syncCount}'),
              _stat(context, 'bad sig', '${mesh.rejected}'),
              _stat(context, 'mesh', mesh.running ? 'ON' : 'off'),
            ],
          ),
        ),
      );

  Widget _stat(BuildContext context, String label, String value) => Column(
        children: [
          Text(value, style: Theme.of(context).textTheme.titleMedium),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      );
}
