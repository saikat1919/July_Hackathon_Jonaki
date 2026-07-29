import 'package:flutter/material.dart';

import 'app/chat_screen.dart';
import 'app/contacts.dart';
import 'app/map_screen.dart';
import 'app/mesh_service.dart';
import 'app/sos_screen.dart';
import 'gossip/envelope.dart';

/// Demo build. The APK handed to judges MUST use a different serviceId, or
/// their phones advertise into the demo's radio cluster during judging.
const String kServiceId = 'bd.july.crisis_mesh.demo';

void main() => runApp(const CrisisMeshApp());

class CrisisMeshApp extends StatelessWidget {
  const CrisisMeshApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Crisis Mesh',
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

  @override
  void initState() {
    super.initState();
    mesh.addListener(_refresh);
    contacts.addListener(_refresh);
    contacts.load();
    mesh.bootIdentity();
    // An SOS that needs you to be looking at the right tab is not an alert.
    mesh.incomingSos.listen(_raiseAlert);
  }

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
    contacts.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(switch (_tab) {
            0 => 'Chat',
            1 => 'Map',
            _ => 'Mesh · ${mesh.fingerprint}',
          }),
          actions: [
            // Peer count belongs on every screen: it is the one number that
            // tells you whether anything you send can go anywhere.
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text('${mesh.peers.length} peer'
                    '${mesh.peers.length == 1 ? '' : 's'}'),
              ),
            ),
            IconButton(
              tooltip: mesh.running ? 'stop mesh' : 'start mesh',
              icon: Icon(mesh.running ? Icons.stop : Icons.play_arrow),
              onPressed: () => mesh.running ? mesh.stop() : mesh.start(),
            ),
          ],
        ),
        body: switch (_tab) {
          0 => ChatScreen(mesh: mesh, contacts: contacts),
          1 => MapScreen(mesh: mesh, contacts: contacts),
          _ => MeshScreen(mesh: mesh),
        },
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.forum), label: 'Chat'),
            NavigationDestination(icon: Icon(Icons.map), label: 'Map'),
            NavigationDestination(icon: Icon(Icons.hub), label: 'Mesh'),
          ],
        ),
      );
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
                onPressed: mesh.running ? mesh.unlockTopology : null,
                child: Text(mesh.locked ? 'unlock topology' : 'lock: OFF'),
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
