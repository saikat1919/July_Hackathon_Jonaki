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
  Identity._(this.keyPair, this.publicKey);

  final SimpleKeyPair keyPair;
  final Uint8List publicKey;

  static final _ed25519 = Ed25519();

  static Future<Identity> generate() async {
    final kp = await _ed25519.newKeyPair();
    final pk = await kp.extractPublicKey();
    return Identity._(kp, Uint8List.fromList(pk.bytes));
  }

  /// Restore from the 32-byte seed held in secure storage (never in SQLite).
  static Future<Identity> fromSeed(List<int> seed) async {
    final kp = await _ed25519.newKeyPairFromSeed(seed);
    final pk = await kp.extractPublicKey();
    return Identity._(kp, Uint8List.fromList(pk.bytes));
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
