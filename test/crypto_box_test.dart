import 'dart:convert';

import 'package:crisis_mesh/gossip/crypto_box.dart';
import 'package:crisis_mesh/gossip/identity.dart';
import 'package:flutter_test/flutter_test.dart';

/// The failure paths matter more than the happy path here. An encryption bug
/// that still round-trips looks like it works right up until it matters.
void main() {
  late Identity alice;
  late Identity bob;
  late Identity relay; // Carol: forwards traffic, must never read it

  setUpAll(() async {
    alice = await Identity.generate();
    bob = await Identity.generate();
    relay = await Identity.generate();
  });

  Future<String> aliceToBob(String text) => CryptoBox.seal(
        plaintext: text,
        myKeyPair: alice.encKeyPair,
        theirPublicKey: bob.encPublicKey,
        senderFingerprint: alice.fingerprint,
        recipientFingerprint: bob.fingerprint,
      );

  group('round trip', () {
    test('Bob can read what Alice sealed for him', () async {
      final sealed = await aliceToBob('meet at the shelter at 6');
      final opened = await CryptoBox.open(
        sealed: sealed,
        myKeyPair: bob.encKeyPair,
        theirPublicKey: alice.encPublicKey,
        senderFingerprint: alice.fingerprint,
        recipientFingerprint: bob.fingerprint,
      );
      expect(opened, 'meet at the shelter at 6');
    });

    test('Alice can reopen her own sent message', () async {
      // X25519 is symmetric, so the sender can render their own thread without
      // storing a second plaintext copy.
      final sealed = await aliceToBob('my own copy');
      final opened = await CryptoBox.open(
        sealed: sealed,
        myKeyPair: alice.encKeyPair,
        theirPublicKey: bob.encPublicKey,
        senderFingerprint: alice.fingerprint,
        recipientFingerprint: bob.fingerprint,
      );
      expect(opened, 'my own copy');
    });

    test('survives unicode, Bangla and emoji intact', () async {
      const text = 'রাস্তা বন্ধ 🚧 second floor';
      final sealed = await aliceToBob(text);
      final opened = await CryptoBox.open(
        sealed: sealed,
        myKeyPair: bob.encKeyPair,
        theirPublicKey: alice.encPublicKey,
        senderFingerprint: alice.fingerprint,
        recipientFingerprint: bob.fingerprint,
      );
      expect(opened, text);
    });

    test('handles a full-length message', () async {
      final text = 'x' * 1000;
      final sealed = await aliceToBob(text);
      final opened = await CryptoBox.open(
        sealed: sealed,
        myKeyPair: bob.encKeyPair,
        theirPublicKey: alice.encPublicKey,
        senderFingerprint: alice.fingerprint,
        recipientFingerprint: bob.fingerprint,
      );
      expect(opened, text);
    });
  });

  group('a relay cannot read it', () {
    test('Carol, holding the ciphertext, gets null', () async {
      final sealed = await aliceToBob('only for Bob');
      final opened = await CryptoBox.open(
        sealed: sealed,
        myKeyPair: relay.encKeyPair,
        theirPublicKey: alice.encPublicKey,
        senderFingerprint: alice.fingerprint,
        recipientFingerprint: bob.fingerprint,
      );
      expect(opened, isNull, reason: 'relays carry, they do not read');
    });

    test('the plaintext never appears in the transmitted bytes', () async {
      const secret = 'RENDEZVOUS-AT-MIRPUR';
      final sealed = await aliceToBob(secret);
      final raw = base64Decode(sealed);
      expect(utf8.decode(raw, allowMalformed: true), isNot(contains(secret)));
      expect(sealed, isNot(contains(secret)));
    });

    test('Carol substituting her own key still gets nothing', () async {
      final sealed = await aliceToBob('only for Bob');
      final opened = await CryptoBox.open(
        sealed: sealed,
        myKeyPair: relay.encKeyPair,
        theirPublicKey: relay.encPublicKey,
        senderFingerprint: alice.fingerprint,
        recipientFingerprint: bob.fingerprint,
      );
      expect(opened, isNull);
    });
  });

  group('tampering is detected', () {
    test('a flipped ciphertext byte fails the MAC', () async {
      final sealed = await aliceToBob('transfer the supplies');
      final raw = base64Decode(sealed);
      raw[raw.length - 1] ^= 0xFF; // corrupt the last ciphertext byte

      final opened = await CryptoBox.open(
        sealed: base64Encode(raw),
        myKeyPair: bob.encKeyPair,
        theirPublicKey: alice.encPublicKey,
        senderFingerprint: alice.fingerprint,
        recipientFingerprint: bob.fingerprint,
      );
      expect(opened, isNull);
    });

    test('a flipped nonce byte fails', () async {
      final sealed = await aliceToBob('hello');
      final raw = base64Decode(sealed);
      raw[0] ^= 0x01;
      expect(
        await CryptoBox.open(
          sealed: base64Encode(raw),
          myKeyPair: bob.encKeyPair,
          theirPublicKey: alice.encPublicKey,
          senderFingerprint: alice.fingerprint,
          recipientFingerprint: bob.fingerprint,
        ),
        isNull,
      );
    });

    test('a flipped MAC byte fails', () async {
      final sealed = await aliceToBob('hello');
      final raw = base64Decode(sealed);
      raw[13] ^= 0x01; // inside the 16-byte tag
      expect(
        await CryptoBox.open(
          sealed: base64Encode(raw),
          myKeyPair: bob.encKeyPair,
          theirPublicKey: alice.encPublicKey,
          senderFingerprint: alice.fingerprint,
          recipientFingerprint: bob.fingerprint,
        ),
        isNull,
      );
    });

    test('re-addressing a captured message fails (AAD binding)', () async {
      // Carol intercepts a message for Bob and tries to pass it off as one
      // addressed to her. The AAD binds sender>recipient, so it will not open
      // even with the right keys in hand.
      final sealed = await aliceToBob('secret');
      final opened = await CryptoBox.open(
        sealed: sealed,
        myKeyPair: bob.encKeyPair,
        theirPublicKey: alice.encPublicKey,
        senderFingerprint: alice.fingerprint,
        recipientFingerprint: relay.fingerprint, // claim it was for Carol
      );
      expect(opened, isNull);
    });

    test('claiming a different sender fails', () async {
      final sealed = await aliceToBob('secret');
      expect(
        await CryptoBox.open(
          sealed: sealed,
          myKeyPair: bob.encKeyPair,
          theirPublicKey: alice.encPublicKey,
          senderFingerprint: relay.fingerprint, // pretend Carol wrote it
          recipientFingerprint: bob.fingerprint,
        ),
        isNull,
      );
    });
  });

  group('garbage in, null out, never a crash', () {
    Future<void> expectNull(String input) async {
      expect(
        await CryptoBox.open(
          sealed: input,
          myKeyPair: bob.encKeyPair,
          theirPublicKey: alice.encPublicKey,
          senderFingerprint: alice.fingerprint,
          recipientFingerprint: bob.fingerprint,
        ),
        isNull,
      );
    }

    test('empty string', () => expectNull(''));
    test('not base64', () => expectNull('!!!not base64!!!'));
    test('valid base64 but far too short', () => expectNull(base64Encode([1, 2, 3])));
    test('exactly at the nonce+mac boundary with no ciphertext', () async {
      // 28 bytes = 12 nonce + 16 mac, zero ciphertext. Must not crash.
      await expectNull(base64Encode(List<int>.filled(28, 0)));
    });
    test('a megabyte of noise', () async {
      await expectNull(base64Encode(List<int>.generate(1 << 20, (i) => i & 0xFF)));
    });
  });

  group('nonce hygiene', () {
    test('sealing the same text twice produces different ciphertexts',
        () async {
      // Nonce reuse under a fixed key destroys AES-GCM. Identical plaintexts
      // must not produce identical output.
      final a = await aliceToBob('identical text');
      final b = await aliceToBob('identical text');
      expect(a, isNot(b));

      final nonceA = base64Decode(a).sublist(0, 12);
      final nonceB = base64Decode(b).sublist(0, 12);
      expect(nonceA, isNot(nonceB));
    });

    test('20 seals produce 20 distinct nonces', () async {
      final seen = <String>{};
      for (var i = 0; i < 20; i++) {
        final s = await aliceToBob('same');
        seen.add(base64Encode(base64Decode(s).sublist(0, 12)));
      }
      expect(seen.length, 20);
    });
  });

  group('identity key derivation', () {
    test('signing and encryption keys are different', () async {
      expect(alice.encPublicKey, isNot(alice.publicKey));
      expect(alice.encPublicKey.length, 32);
    });

    test('the same seed reproduces the same encryption key', () async {
      final restored = await Identity.fromSeed(await alice.seed());
      expect(restored.encPublicKey, equals(alice.encPublicKey));
      expect(restored.publicKey, equals(alice.publicKey));
    });

    test('different identities get different encryption keys', () {
      expect(alice.encPublicKey, isNot(bob.encPublicKey));
    });

    test('a restored identity can still decrypt earlier messages', () async {
      final sealed = await aliceToBob('before restart');
      final restoredBob = await Identity.fromSeed(await bob.seed());
      final opened = await CryptoBox.open(
        sealed: sealed,
        myKeyPair: restoredBob.encKeyPair,
        theirPublicKey: alice.encPublicKey,
        senderFingerprint: alice.fingerprint,
        recipientFingerprint: bob.fingerprint,
      );
      expect(opened, 'before restart');
    });
  });
}
