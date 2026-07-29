import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// End-to-end encryption for personal messages.
///
/// X25519 to agree a shared secret, HKDF to turn it into an AES key, AES-GCM
/// to seal the text. Relays carry an opaque blob and cannot read it.
///
///   sender                    relays                   recipient
///   ------                    ------                   ---------
///   plaintext
///     │ X25519(my priv, their pub)
///     ▼
///   shared secret
///     │ HKDF-SHA256
///     ▼
///   AES-256 key
///     │ AES-GCM (+ AAD binding sender→recipient)
///     ▼
///   nonce ‖ mac ‖ ciphertext ──► carried, not readable ──► decrypt ──► plaintext
///
/// What this does NOT do, and should never be claimed: it does not hide that a
/// message exists, who sent it, or who it is addressed to. Store-and-forward
/// requires every relay to carry the envelope, and routing needs the recipient
/// in the clear. Only the text is protected.
///
/// No forward secrecy either: keys are long-term, so a stolen private key
/// decrypts past messages that were captured. Real ratcheting is out of scope
/// for a six-day build, and saying so is better than implying otherwise.
class CryptoBox {
  static final _x25519 = X25519();
  static final _aes = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// Domain separation. Changing this string makes every existing ciphertext
  /// undecryptable, which is exactly what a protocol version bump should do.
  static const _info = 'crisis-mesh-dm-v1';

  /// Fixed salt: the X25519 output is already high-entropy, and a per-message
  /// salt would have to travel with the message for no gain here.
  static final _salt = Uint8List.fromList(utf8.encode('crisis-mesh-salt-v1'));

  static Future<SecretKey> _sharedKey({
    required SimpleKeyPair myKeyPair,
    required Uint8List theirPublicKey,
  }) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey:
          SimplePublicKey(theirPublicKey, type: KeyPairType.x25519),
    );
    return _hkdf.deriveKey(
      secretKey: shared,
      nonce: _salt,
      info: utf8.encode(_info),
    );
  }

  /// Binds the ciphertext to this exact sender and recipient. Without it, a
  /// captured blob could be re-addressed and replayed at a third party. The
  /// envelope signature already covers the payload, so this is belt and braces
  /// rather than the only defence, and it costs nothing.
  static Uint8List _aad(String senderFp, String recipientFp) =>
      Uint8List.fromList(utf8.encode('$senderFp>$recipientFp'));

  /// Returns base64 of `nonce ‖ mac ‖ ciphertext`.
  static Future<String> seal({
    required String plaintext,
    required SimpleKeyPair myKeyPair,
    required Uint8List theirPublicKey,
    required String senderFingerprint,
    required String recipientFingerprint,
  }) async {
    final key = await _sharedKey(
      myKeyPair: myKeyPair,
      theirPublicKey: theirPublicKey,
    );
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      // Left to the library: a random nonce per message. Reuse under a fixed
      // key is the classic way to destroy GCM, so it is never hand-rolled.
      aad: _aad(senderFingerprint, recipientFingerprint),
    );
    final out = BytesBuilder()
      ..add(box.nonce)
      ..add(box.mac.bytes)
      ..add(box.cipherText);
    return base64Encode(out.toBytes());
  }

  /// Returns null on any failure: wrong key, tampering, re-addressing, or
  /// garbage. A relay calling this is *expected* to get null, so it must never
  /// throw and must never leak a partial plaintext.
  static Future<String?> open({
    required String sealed,
    required SimpleKeyPair myKeyPair,
    required Uint8List theirPublicKey,
    required String senderFingerprint,
    required String recipientFingerprint,
  }) async {
    try {
      final raw = base64Decode(sealed);
      // 12-byte GCM nonce, 16-byte tag.
      if (raw.length < 12 + 16) return null;
      final nonce = raw.sublist(0, 12);
      final mac = raw.sublist(12, 28);
      final cipherText = raw.sublist(28);

      final key = await _sharedKey(
        myKeyPair: myKeyPair,
        theirPublicKey: theirPublicKey,
      );
      final clear = await _aes.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
        aad: _aad(senderFingerprint, recipientFingerprint),
      );
      return utf8.decode(clear);
    } catch (_) {
      // SecretBoxAuthenticationError for tampering, FormatException for
      // garbage. Both mean the same thing to a caller: not for you, or not
      // intact.
      return null;
    }
  }
}
