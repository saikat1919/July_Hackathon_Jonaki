import 'package:flutter/material.dart';

import 'gossip/envelope.dart';
import 'gossip/gossip_node.dart';
import 'gossip/identity.dart';
import 'store/envelope_store.dart';
import 'transport/transport.dart';

/// Day-1 harness, not the product. It proves on real hardware that identity
/// generation, signing, and the gossip pipeline all work inside a release APK
/// before any radio is involved. The Nearby transport lands on day 2, the real
/// screens on day 2 afternoon and day 3.
void main() => runApp(const CrisisMeshApp());

class CrisisMeshApp extends StatelessWidget {
  const CrisisMeshApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Crisis Mesh',
        theme: ThemeData.dark(useMaterial3: true),
        home: const HarnessScreen(),
      );
}

class HarnessScreen extends StatefulWidget {
  const HarnessScreen({super.key});

  @override
  State<HarnessScreen> createState() => _HarnessScreenState();
}

class _HarnessScreenState extends State<HarnessScreen> {
  Identity? _me;
  final _log = <String>[];

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final me = await Identity.generate();
    if (!mounted) return;
    setState(() {
      _me = me;
      _log.add('identity generated');
    });
  }

  /// Runs the same convergence check as the test suite, on the phone. Green
  /// here plus four phones that will not relay means the radio is the fault.
  Future<void> _selfCheck() async {
    final net = MemoryNetwork();
    final nodes = <String, GossipNode>{};
    final stores = <String, MemoryEnvelopeStore>{};
    for (final id in ['A', 'B', 'C', 'D']) {
      final store = MemoryEnvelopeStore();
      final n = GossipNode(
        identity: await Identity.generate(),
        store: store,
        transport: net.register(id),
        syncCooldown: Duration.zero,
      );
      await n.start();
      nodes[id] = n;
      stores[id] = store;
    }
    net.link('A', 'B');
    net.link('B', 'C');
    net.link('C', 'D');
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final sent = await nodes['A']!
        .publish(EnvelopeType.chat, encodePayload({'t': 'self check'}));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final atD = await stores['D']!.get(sent.id);
    if (!mounted) return;
    setState(() => _log.add(atD == null
        ? 'SELF CHECK FAILED: A did not reach D'
        : 'self check OK: A reached D in ${atD.path.length} hops'));
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;
    return Scaffold(
      appBar: AppBar(title: const Text('Crisis Mesh — day 1 harness')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ID: ${me?.fingerprint ?? '...'}',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text('No phone number. The public key is the identity.'),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: me == null ? null : _selfCheck,
              child: const Text('Run 4-node gossip self check'),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                children: [for (final line in _log) Text('• $line')],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
