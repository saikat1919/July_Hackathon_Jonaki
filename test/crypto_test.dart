import 'dart:typed_data';

import 'package:crisis_mesh/gossip/envelope.dart';
import 'package:crisis_mesh/gossip/identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('signature policy', () {
    test('valid signature verifies', () async {
      final me = await Identity.generate();
      final e = await me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'hello'}),
      );
      expect(
        await Identity.verify(e.signingInput, e.signature, e.senderPubkey),
        isTrue,
      );
    });

    test('tampered payload fails verification', () async {
      final me = await Identity.generate();
      final e = await me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'transfer 100'}),
      );
      final forged = Envelope(
        id: e.id,
        typeWire: e.typeWire,
        timestamp: e.timestamp,
        lifetime: e.lifetime,
        senderPubkey: e.senderPubkey,
        payload: encodePayload({'t': 'transfer 9000'}),
        signature: e.signature,
        ttl: e.ttl,
        remaining: e.remaining,
      );
      expect(
        await Identity.verify(
            forged.signingInput, forged.signature, forged.senderPubkey),
        isFalse,
      );
    });

    test('garbage signature is rejected without throwing', () async {
      final me = await Identity.generate();
      final e = await me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'hi'}),
      );
      expect(
        await Identity.verify(
          e.signingInput,
          Uint8List.fromList(List.filled(64, 0)),
          e.senderPubkey,
        ),
        isFalse,
      );
    });

    test('malformed public key is rejected without throwing', () async {
      final me = await Identity.generate();
      final e = await me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'hi'}),
      );
      expect(
        await Identity.verify(
            e.signingInput, e.signature, Uint8List.fromList([1, 2, 3])),
        isFalse,
      );
    });
  });

  group('identity', () {
    test('fingerprint is a stable 8-char hex of the public key', () async {
      final me = await Identity.generate();
      expect(me.fingerprint.length, fingerprintBytes * 2);
      expect(me.fingerprint, me.fingerprint);
      expect(RegExp(r'^[0-9A-F]+$').hasMatch(me.fingerprint), isTrue);
    });

    test('two identities differ', () async {
      final a = await Identity.generate();
      final b = await Identity.generate();
      expect(a.fingerprint, isNot(b.fingerprint));
    });

    test('restoring from seed reproduces the same key', () async {
      final a = await Identity.generate();
      final restored = await Identity.fromSeed(await a.seed());
      expect(restored.publicKey, equals(a.publicKey));
      expect(restored.fingerprint, a.fingerprint);
    });

    test('sos composes with the longer ttl', () async {
      final me = await Identity.generate();
      final sos = await me.compose(
        type: EnvelopeType.sos,
        payload: encodePayload({'kind': 'fire'}),
      );
      final chat = await me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'hi'}),
      );
      expect(sos.ttl, sosTtl);
      expect(chat.ttl, defaultTtl);
      expect(sos.lifetime, const Duration(hours: 2));
    });
  });
}
