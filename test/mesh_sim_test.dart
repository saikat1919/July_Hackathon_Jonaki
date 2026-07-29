import 'dart:typed_data';

import 'package:crisis_mesh/gossip/envelope.dart';
import 'package:crisis_mesh/gossip/gossip_node.dart';
import 'package:crisis_mesh/gossip/identity.dart';
import 'package:crisis_mesh/store/envelope_store.dart';
import 'package:crisis_mesh/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// THE GATE DIAGNOSTIC.
///
/// Run this before the day-2 hardware gate. If it is green and four phones
/// still fail to relay, the fault is the radio, not the logic — which is the
/// difference between fixing the problem and bisecting blind for a day.
void main() {
  Future<_Node> node(MemoryNetwork net, String id) async {
    final me = await Identity.generate();
    final store = MemoryEnvelopeStore();
    final n = GossipNode(
      identity: me,
      store: store,
      transport: net.register(id),
      syncCooldown: Duration.zero,
    );
    await n.start();
    return _Node(id, n, store);
  }

  /// Let the async pushes settle. Sends are futures, not instant.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

  test('4-node chain converges: A reaches D without ever linking to D', () async {
    final net = MemoryNetwork();
    final a = await node(net, 'A');
    final b = await node(net, 'B');
    final c = await node(net, 'C');
    final d = await node(net, 'D');

    // chain topology: A ── B ── C ── D. A and D are NOT linked.
    net.link('A', 'B');
    net.link('B', 'C');
    net.link('C', 'D');
    await settle();

    final sent = await a.node.publish(
      EnvelopeType.chat,
      encodePayload({'t': 'bridge at Mirpur is closed'}),
    );
    await settle();

    for (final n in [a, b, c, d]) {
      final got = await n.store.get(sent.id);
      expect(got, isNotNull, reason: '${n.id} should have the envelope');
    }

    final atD = await d.store.get(sent.id);
    expect(atD!.path.length, 3, reason: 'three relays appended their fingerprint');
    expect(atD.ttl, defaultTtl - 3, reason: 'ttl burned one per hop');
    expect(
      decodePayload(atD.payload)['t'],
      'bridge at Mirpur is closed',
      reason: 'payload survived the relay intact',
    );
  });

  test('partition does not converge until a mule carries between the halves',
      () async {
    final net = MemoryNetwork();
    final a = await node(net, 'A');
    final b = await node(net, 'B');
    final mule = await node(net, 'M');
    final c = await node(net, 'C');
    final d = await node(net, 'D');

    // Two isolated pairs. Nothing links them.
    net.link('A', 'B');
    net.link('C', 'D');
    await settle();

    final sos = await a.node.publish(
      EnvelopeType.sos,
      encodePayload({'kind': 'medical', 'note': 'leg injury, water rising'}),
    );
    await settle();

    expect(await b.store.get(sos.id), isNotNull, reason: 'same side gets it');
    expect(await d.store.get(sos.id), isNull, reason: 'far side is cut off');

    // The mule walks to the first group...
    net.link('M', 'A');
    await settle();
    expect(await mule.store.get(sos.id), isNotNull, reason: 'mule picked it up');

    // ...then walks away and reaches the second group.
    net.unlinkAll('M');
    net.link('M', 'D');
    await settle();

    expect(
      await d.store.get(sos.id),
      isNotNull,
      reason: 'the SOS crossed a partition no radio link ever spanned',
    );
    expect(await c.store.get(sos.id), isNotNull, reason: 'and spread onward');
  });

  test('an envelope is never stored twice, however many paths reach it',
      () async {
    final net = MemoryNetwork();
    final a = await node(net, 'A');
    final b = await node(net, 'B');
    final c = await node(net, 'C');

    // Triangle: every node has two routes to every other node.
    net.link('A', 'B');
    net.link('B', 'C');
    net.link('A', 'C');
    await settle();

    await a.node.publish(EnvelopeType.chat, encodePayload({'t': 'hi'}));
    await settle();

    for (final n in [a, b, c]) {
      expect((await n.store.all()).length, 1, reason: '${n.id} deduped');
    }
  });

  test('a forged envelope is dropped and never relayed onward', () async {
    final net = MemoryNetwork();
    final a = await node(net, 'A');
    final b = await node(net, 'B');
    final c = await node(net, 'C');
    net.link('A', 'B');
    net.link('B', 'C');
    await settle();

    final real = await a.identityCompose();
    final forged = Envelope(
      id: real.id,
      typeWire: real.typeWire,
      timestamp: real.timestamp,
      lifetime: real.lifetime,
      senderPubkey: real.senderPubkey,
      payload: encodePayload({'t': 'evacuate immediately, this is fake'}),
      signature: real.signature, // signature no longer matches the payload
      ttl: real.ttl,
      remaining: real.remaining,
    );

    await net.register('X').send('B', _envelopeFrame(forged));
    await settle();

    expect(await b.store.get(forged.id), isNull, reason: 'B dropped it');
    expect(await c.store.get(forged.id), isNull, reason: 'and never relayed it');
  });

  test('sync is skipped when nothing changed, so a flapping link cannot storm',
      () async {
    final net = MemoryNetwork();
    final me = await Identity.generate();
    final n = GossipNode(
      identity: me,
      store: MemoryEnvelopeStore(),
      transport: net.register('A'),
      syncCooldown: const Duration(seconds: 30),
    );
    await n.start();
    net.register('B');
    net.link('A', 'B');
    await settle();

    final after = n.syncCount;
    for (var i = 0; i < 10; i++) {
      await n.syncWith('B'); // ten reconnects in a row, nothing new to send
    }
    expect(n.syncCount, after, reason: 'cooldown suppressed all ten');
  });
}

class _Node {
  _Node(this.id, this.node, this.store);
  final String id;
  final GossipNode node;
  final MemoryEnvelopeStore store;

  Future<Envelope> identityCompose() => node.identity.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'original'}),
      );
}

/// Frame an envelope the way GossipNode expects to receive one.
Uint8List _envelopeFrame(Envelope e) => Uint8List.fromList([0x11, ...e.encode()]);
