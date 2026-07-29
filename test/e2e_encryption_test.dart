import 'dart:convert';

import 'package:crisis_mesh/app/chat.dart';
import 'package:crisis_mesh/app/key_directory.dart';
import 'package:crisis_mesh/gossip/crypto_box.dart';
import 'package:crisis_mesh/gossip/envelope.dart';
import 'package:crisis_mesh/gossip/gossip_node.dart';
import 'package:crisis_mesh/gossip/identity.dart';
import 'package:crisis_mesh/store/envelope_store.dart';
import 'package:crisis_mesh/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// The claim this whole feature makes: a personal message crosses a relay that
/// cannot read it. Proven here through the real gossip pipeline rather than by
/// calling the crypto directly.
void main() {
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 80));

  test('A→B→C: B relays a personal message it cannot read, C reads it',
      () async {
    final net = MemoryNetwork();

    final a = await Identity.generate();
    final b = await Identity.generate();
    final c = await Identity.generate();

    final storeA = MemoryEnvelopeStore();
    final storeB = MemoryEnvelopeStore();
    final storeC = MemoryEnvelopeStore();

    final nodeA = GossipNode(
        identity: a,
        store: storeA,
        transport: net.register('A'),
        syncCooldown: Duration.zero);
    final nodeB = GossipNode(
        identity: b,
        store: storeB,
        transport: net.register('B'),
        syncCooldown: Duration.zero);
    final nodeC = GossipNode(
        identity: c,
        store: storeC,
        transport: net.register('C'),
        syncCooldown: Duration.zero);

    final dirA = KeyDirectory();
    final dirB = KeyDirectory();
    final dirC = KeyDirectory();
    nodeA.accepted.listen(dirA.learnFrom);
    nodeB.accepted.listen(dirB.learnFrom);
    nodeC.accepted.listen(dirC.learnFrom);

    await nodeA.start();
    await nodeB.start();
    await nodeC.start();

    // A ── B ── C. A and C are never linked.
    net.link('A', 'B');
    net.link('B', 'C');
    await settle();

    // Bootstrap: C says hello globally, so A learns C's encryption key.
    await nodeC.publish(
      EnvelopeType.chat,
      encodePayload({'t': 'hello', 'ek': base64Encode(c.encPublicKey)}),
    );
    await settle();

    expect(dirA.canEncryptTo(c.fingerprint), isTrue,
        reason: 'one global message is enough to bootstrap encryption');

    // A now sends C a personal message. B is the only route.
    const secret = 'the shelter is full, go to the school instead';
    final sealed = await CryptoBox.seal(
      plaintext: secret,
      myKeyPair: a.encKeyPair,
      theirPublicKey: dirA[c.fingerprint]!.encryptionKey!,
      senderFingerprint: a.fingerprint,
      recipientFingerprint: c.fingerprint,
    );
    final sent = await nodeA.publish(
      EnvelopeType.chat,
      encodePayload({
        'to': c.fingerprint,
        'enc': sealed,
        'ek': base64Encode(a.encPublicKey),
      }),
    );
    await settle();

    // It physically reached everyone, including the relay.
    expect(await storeB.get(sent.id), isNotNull, reason: 'B carried it');
    expect(await storeC.get(sent.id), isNotNull, reason: 'C received it');

    // The relay cannot read it.
    final atB = await storeB.get(sent.id);
    final asSeenByB = await ChatMessage.fromEnvelope(
      atB!,
      b.fingerprint,
      decrypt: (s, senderFp, recipientFp) async {
        final peer = dirB[senderFp];
        if (peer == null || !peer.canEncrypt) return null;
        return CryptoBox.open(
          sealed: s,
          myKeyPair: b.encKeyPair,
          theirPublicKey: peer.encryptionKey!,
          senderFingerprint: senderFp,
          recipientFingerprint: recipientFp,
        );
      },
    );
    expect(asSeenByB!.encrypted, isTrue);
    expect(asSeenByB.readable, isFalse,
        reason: 'the relay carries the message but cannot read it');
    expect(asSeenByB.text, isNull);

    // The plaintext is nowhere in the bytes B stored.
    expect(utf8.decode(atB.payload, allowMalformed: true),
        isNot(contains('shelter')));

    // The intended recipient can read it.
    final atC = await storeC.get(sent.id);
    final asSeenByC = await ChatMessage.fromEnvelope(
      atC!,
      c.fingerprint,
      decrypt: (s, senderFp, recipientFp) async {
        final peer = dirC[senderFp];
        if (peer == null || !peer.canEncrypt) return null;
        return CryptoBox.open(
          sealed: s,
          myKeyPair: c.encKeyPair,
          theirPublicKey: peer.encryptionKey!,
          senderFingerprint: senderFp,
          recipientFingerprint: recipientFp,
        );
      },
    );
    expect(asSeenByC!.readable, isTrue);
    expect(asSeenByC.text, secret);
    expect(asSeenByC.hops, 2, reason: 'it travelled A → B → C');
  });

  test('a global message stays readable by every node', () async {
    final net = MemoryNetwork();
    final a = await Identity.generate();
    final b = await Identity.generate();
    final storeB = MemoryEnvelopeStore();

    final nodeA = GossipNode(
        identity: a,
        store: MemoryEnvelopeStore(),
        transport: net.register('A'),
        syncCooldown: Duration.zero);
    final nodeB = GossipNode(
        identity: b,
        store: storeB,
        transport: net.register('B'),
        syncCooldown: Duration.zero);
    await nodeA.start();
    await nodeB.start();
    net.link('A', 'B');
    await settle();

    final sent = await nodeA.publish(
      EnvelopeType.chat,
      encodePayload({'t': 'road is blocked', 'ek': base64Encode(a.encPublicKey)}),
    );
    await settle();

    final atB = await storeB.get(sent.id);
    final seen = await ChatMessage.fromEnvelope(atB!, b.fingerprint);
    expect(seen!.readable, isTrue);
    expect(seen.encrypted, isFalse);
    expect(seen.text, 'road is blocked',
        reason: 'global chat is deliberately plaintext');
  });

  test('a personal message arriving unsealed is not shown as encrypted',
      () async {
    // Guards against a downgrade being mistaken for privacy: if something
    // addressed lands without a seal, it must present as plain, not private.
    final a = await Identity.generate();
    final e = await a.compose(
      type: EnvelopeType.chat,
      payload: encodePayload({'to': 'BBBB2222', 't': 'plaintext DM'}),
    );
    final m = await ChatMessage.fromEnvelope(e, 'BBBB2222');
    expect(m!.encrypted, isFalse);
    expect(m.readable, isTrue);
    expect(m.text, 'plaintext DM');
  });
}
