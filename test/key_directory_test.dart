import 'dart:convert';
import 'dart:typed_data';

import 'package:crisis_mesh/app/key_directory.dart';
import 'package:crisis_mesh/gossip/envelope.dart';
import 'package:crisis_mesh/gossip/identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Identity alice;
  late Identity bob;

  setUpAll(() async {
    alice = await Identity.generate();
    bob = await Identity.generate();
  });

  Future<Envelope> globalFrom(Identity who, {bool advertiseKey = true}) =>
      who.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({
          't': 'hello',
          if (advertiseKey) 'ek': base64Encode(who.encPublicKey),
        }),
      );

  group('trust on first use', () {
    test('learns both keys from one ordinary message', () async {
      final dir = KeyDirectory();
      expect(await dir.learnFrom(await globalFrom(alice)), isTrue);

      final known = dir[alice.fingerprint]!;
      expect(known.signingKey, equals(alice.publicKey));
      expect(known.encryptionKey, equals(alice.encPublicKey));
      expect(known.canEncrypt, isTrue);
      expect(dir.canEncryptTo(alice.fingerprint), isTrue);
    });

    test('fingerprint lookup is case-insensitive', () async {
      final dir = KeyDirectory();
      await dir.learnFrom(await globalFrom(alice));
      expect(dir[alice.fingerprint.toLowerCase()], isNotNull);
    });

    test('a message with no advertised key still teaches the signing key',
        () async {
      final dir = KeyDirectory();
      expect(
        await dir.learnFrom(await globalFrom(alice, advertiseKey: false)),
        isTrue,
      );
      expect(dir[alice.fingerprint]!.signingKey, equals(alice.publicKey));
      expect(dir.canEncryptTo(alice.fingerprint), isFalse,
          reason: 'cannot encrypt until they advertise an encryption key');
    });

    test('a later message fills in the encryption key', () async {
      final dir = KeyDirectory();
      await dir.learnFrom(await globalFrom(alice, advertiseKey: false));
      expect(dir.canEncryptTo(alice.fingerprint), isFalse);

      await dir.learnFrom(await globalFrom(alice));
      expect(dir.canEncryptTo(alice.fingerprint), isTrue);
    });

    test('an SOS payload teaches keys too', () async {
      final dir = KeyDirectory();
      final sos = await alice.compose(
        type: EnvelopeType.sos,
        payload: encodePayload({
          'kind': 'medical',
          'ek': base64Encode(alice.encPublicKey),
        }),
      );
      expect(await dir.learnFrom(sos), isTrue);
      expect(dir.canEncryptTo(alice.fingerprint), isTrue);
    });

    test('two peers are tracked independently', () async {
      final dir = KeyDirectory();
      await dir.learnFrom(await globalFrom(alice));
      await dir.learnFrom(await globalFrom(bob));
      expect(dir.all.length, 2);
      expect(dir[alice.fingerprint]!.encryptionKey,
          isNot(dir[bob.fingerprint]!.encryptionKey));
    });
  });

  group('pinning — the security property', () {
    test('a different signing key on a pinned fingerprint is REJECTED',
        () async {
      // An impersonator grinding a fingerprint collision must not be able to
      // silently replace a stored identity.
      final dir = KeyDirectory();
      await dir.learnFrom(await globalFrom(alice));

      final impostor = await _forgeWithFingerprint(alice.fingerprint);
      final accepted = await dir.learnFrom(impostor);

      expect(accepted, isFalse);
      expect(dir[alice.fingerprint]!.signingKey, equals(alice.publicKey),
          reason: 'the original key must survive');
      expect(dir.conflicts, contains(alice.fingerprint));
    });

    test('rotating the encryption key under a pinned identity is REJECTED',
        () async {
      final dir = KeyDirectory();
      await dir.learnFrom(await globalFrom(alice));

      // Same signing identity, but now advertising somebody else's enc key.
      final swapped = await alice.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({
          't': 'hello',
          'ek': base64Encode(bob.encPublicKey),
        }),
      );
      expect(await dir.learnFrom(swapped), isFalse);
      expect(dir[alice.fingerprint]!.encryptionKey,
          equals(alice.encPublicKey),
          reason: 'key substitution is exactly what pinning prevents');
      expect(dir.conflicts, contains(alice.fingerprint));
    });

    test('re-learning the identical keys is fine and not a conflict', () async {
      final dir = KeyDirectory();
      await dir.learnFrom(await globalFrom(alice));
      expect(await dir.learnFrom(await globalFrom(alice)), isTrue);
      expect(dir.conflicts, isEmpty);
    });
  });

  group('malformed input never corrupts the directory', () {
    test('a non-JSON payload is tolerated', () async {
      final dir = KeyDirectory();
      final e = await alice.compose(
        type: EnvelopeType.chat,
        payload: Uint8List.fromList([0xFF, 0xFE, 0x00, 0x01]),
      );
      expect(await dir.learnFrom(e), isTrue);
      expect(dir[alice.fingerprint]!.signingKey, equals(alice.publicKey));
      expect(dir.canEncryptTo(alice.fingerprint), isFalse);
    });

    test('a wrong-length encryption key is ignored, not stored', () async {
      final dir = KeyDirectory();
      final e = await alice.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({
          't': 'hi',
          'ek': base64Encode(List<int>.filled(8, 1)), // too short for X25519
        }),
      );
      expect(await dir.learnFrom(e), isTrue);
      expect(dir.canEncryptTo(alice.fingerprint), isFalse);
    });

    test('a non-base64 encryption key is ignored', () async {
      final dir = KeyDirectory();
      final e = await alice.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'hi', 'ek': 'not-base64!!!'}),
      );
      expect(await dir.learnFrom(e), isTrue);
      expect(dir.canEncryptTo(alice.fingerprint), isFalse);
    });

    test('an unknown peer reports as unencryptable rather than throwing', () {
      final dir = KeyDirectory();
      expect(dir['NEVERSEEN'], isNull);
      expect(dir.canEncryptTo('NEVERSEEN'), isFalse);
    });
  });
}

/// Builds an envelope from a *different* keypair that reports the same short
/// fingerprint, simulating a collision or a deliberate impersonation attempt.
Future<Envelope> _forgeWithFingerprint(String target) async {
  final impostor = await Identity.generate();
  final e = await impostor.compose(
    type: EnvelopeType.chat,
    payload: encodePayload({
      't': 'I am totally them',
      'ek': base64Encode(impostor.encPublicKey),
    }),
  );
  // Rewrite the sender key's leading bytes so senderFingerprint matches the
  // victim's. The signature no longer verifies, which is the real defence —
  // this test exists to prove the directory does not depend on that alone.
  final faked = Uint8List.fromList(e.senderPubkey);
  final targetBytes = <int>[];
  for (var i = 0; i < target.length; i += 2) {
    targetBytes.add(int.parse(target.substring(i, i + 2), radix: 16));
  }
  for (var i = 0; i < targetBytes.length; i++) {
    faked[i] = targetBytes[i];
  }
  return Envelope(
    id: e.id,
    typeWire: e.typeWire,
    timestamp: e.timestamp,
    lifetime: e.lifetime,
    senderPubkey: faked,
    payload: e.payload,
    signature: e.signature,
    ttl: e.ttl,
    remaining: e.remaining,
  );
}
