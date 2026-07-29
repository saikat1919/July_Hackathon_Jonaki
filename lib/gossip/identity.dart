import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'envelope.dart';

/// Identity is a keypair, not a phone number. The public key IS the user id;
/// the first 4 bytes shown as hex are the human-readable fingerprint (8J4K91LP).
///
/// Trust rule that makes the mesh work: a valid signature earns a relay whether
/// or not the sender is a known contact. Rakib must forward for people he has
/// never met, or there is no mesh. Contacts only supply a display name.
class Identity {
  Identity._(this.keyPair, this.publicKey, this.encKeyPair, this.encPublicKey);

  /// Ed25519. Signs every envelope; its public key IS the user id.
  final SimpleKeyPair keyPair;
  final Uint8List publicKey;

  /// X25519. Used only to encrypt personal messages. Separate curve because
  /// signing and key agreement are different jobs and sharing one key across
  /// both is a well-known way to weaken each.
  final SimpleKeyPair encKeyPair;
  final Uint8List encPublicKey;

  static final _ed25519 = Ed25519();
  static final _x25519 = X25519();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static Future<Identity> generate() async {
    final kp = await _ed25519.newKeyPair();
    return _build(kp, await kp.extractPrivateKeyBytes());
  }

  /// Restore from the 32-byte seed held in secure storage (never in SQLite).
  static Future<Identity> fromSeed(List<int> seed) async {
    final kp = await _ed25519.newKeyPairFromSeed(seed);
    return _build(kp, seed);
  }

  /// The X25519 keypair is DERIVED from the signing seed rather than generated
  /// independently, so there is still exactly one secret to back up and lose.
  /// HKDF with a distinct info string keeps the two keys cryptographically
  /// unrelated despite the shared origin.
  static Future<Identity> _build(SimpleKeyPair signing, List<int> seed) async {
    final signPub = await signing.extractPublicKey();

    final encSeed = await _hkdf.deriveKey(
      secretKey: SecretKey(seed),
      nonce: utf8.encode('crisis-mesh-enc-salt-v1'),
      info: utf8.encode('crisis-mesh-x25519-v1'),
    );
    final encKp = await _x25519.newKeyPairFromSeed(
      await encSeed.extractBytes(),
    );
    final encPub = await encKp.extractPublicKey();

    return Identity._(
      signing,
      Uint8List.fromList(signPub.bytes),
      encKp,
      Uint8List.fromList(encPub.bytes),
    );
  }

  Future<Uint8List> seed() async =>
      Uint8List.fromList(await keyPair.extractPrivateKeyBytes());

  String get fingerprint => publicKey
      .sublist(0, fingerprintBytes)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  Future<Uint8List> sign(Uint8List message) async {
    final sig = await _ed25519.sign(message, keyPair: keyPair);
    return Uint8List.fromList(sig.bytes);
  }

  static Future<bool> verify(
    Uint8List message,
    Uint8List signature,
    Uint8List publicKey,
  ) async {
    try {
      return await _ed25519.verify(
        message,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false; // malformed key or signature is just an invalid envelope
    }
  }

  /// Build and sign an envelope. `remaining` starts as the full lifetime; every
  /// later hop overwrites it with the time actually left.
  Future<Envelope> compose({
    required EnvelopeType type,
    required Uint8List payload,
    Duration? lifetime,
    int? ttl,
    DateTime? now,
  }) async {
    final life = lifetime ?? type.defaultLifetime;
    final id = Envelope.newId();
    final ts = now ?? DateTime.now();
    final signed = Envelope.signedBytes(
      id: id,
      typeWire: type.wire,
      timestamp: ts,
      lifetime: life,
      senderPubkey: publicKey,
      payload: payload,
    );
    return Envelope(
      id: id,
      typeWire: type.wire,
      timestamp: ts,
      lifetime: life,
      senderPubkey: publicKey,
      payload: payload,
      signature: await sign(signed),
      ttl: ttl ?? (type == EnvelopeType.sos ? sosTtl : defaultTtl),
      remaining: life,
    );
  }
}
