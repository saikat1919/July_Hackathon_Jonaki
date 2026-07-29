import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../gossip/envelope.dart';

/// What we know about one peer's keys.
class PeerKeys {
  const PeerKeys({
    required this.fingerprint,
    required this.signingKey,
    required this.encryptionKey,
  });

  final String fingerprint;

  /// Ed25519. The real identity; the fingerprint is only its first four bytes.
  final Uint8List signingKey;

  /// X25519. Needed to encrypt to this peer. Null until they have sent
  /// something that advertised it.
  final Uint8List? encryptionKey;

  bool get canEncrypt => encryptionKey != null;
}

/// Learns peer keys from ordinary traffic, then pins them.
///
/// Trust on first use: the first time a phone hears from someone, it records
/// their keys. No QR exchange, no key server. Every envelope already carries
/// the sender's signing key, and messages advertise the encryption key, so
/// hearing one global message from someone is enough to message them privately.
///
/// PINNING IS THE SECURITY PROPERTY. Once a fingerprint is bound to a signing
/// key, a later envelope claiming the same fingerprint with a DIFFERENT signing
/// key is rejected, not silently accepted. Quietly replacing a stored key is
/// how an impersonator would take over a conversation.
///
/// Known limit, stated rather than hidden: fingerprints are four bytes, so a
/// determined attacker could grind a keypair sharing a prefix with someone
/// else's (~2^32 work, and far less to collide with *anyone*). Everything that
/// matters is keyed by the full signing key; the fingerprint is a display
/// convenience. Longer fingerprints would be the fix beyond a hackathon.
class KeyDirectory extends ChangeNotifier {
  static const _prefix = 'keys.';

  final Map<String, PeerKeys> _byFingerprint = {};
  SharedPreferences? _prefs;

  /// Fingerprints where a conflicting signing key showed up. Surfaced in the
  /// UI rather than swallowed: it means either a collision or an attack.
  final Set<String> conflicts = {};

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    for (final key in _prefs!.getKeys()) {
      if (!key.startsWith(_prefix)) continue;
      final raw = _prefs!.getString(key);
      if (raw == null) continue;
      try {
        final j = jsonDecode(raw) as Map<String, Object?>;
        final fp = key.substring(_prefix.length);
        _byFingerprint[fp] = PeerKeys(
          fingerprint: fp,
          signingKey: base64Decode(j['sig'] as String),
          encryptionKey: j['enc'] == null
              ? null
              : base64Decode(j['enc'] as String),
        );
      } catch (_) {
        // Corrupt entry: drop it rather than crash on boot.
      }
    }
    notifyListeners();
  }

  PeerKeys? operator [](String fingerprint) =>
      _byFingerprint[fingerprint.toUpperCase()];

  bool canEncryptTo(String fingerprint) =>
      this[fingerprint]?.canEncrypt ?? false;

  List<PeerKeys> get all => _byFingerprint.values.toList();

  /// Records what an envelope tells us about its sender.
  ///
  /// Returns false when the envelope conflicts with a pinned key, in which case
  /// nothing is stored. Callers should treat false as "do not trust this".
  Future<bool> learnFrom(Envelope e) async {
    final fp = e.senderFingerprint.toUpperCase();
    final existing = _byFingerprint[fp];

    if (existing != null &&
        !_sameBytes(existing.signingKey, e.senderPubkey)) {
      // Same short fingerprint, different identity. Never overwrite.
      if (conflicts.add(fp)) notifyListeners();
      return false;
    }

    // The encryption key is advertised inside the payload, which sits within
    // the signed region — so it is authenticated, not injectable by a relay.
    Uint8List? encKey = existing?.encryptionKey;
    try {
      final advertised = decodePayload(e.payload)['ek'];
      if (advertised is String) {
        final bytes = base64Decode(advertised);
        if (bytes.length == 32) {
          if (encKey != null && !_sameBytes(encKey, bytes)) {
            // Pinned identity trying to rotate its encryption key. Refuse:
            // key substitution is exactly what pinning exists to stop.
            if (conflicts.add(fp)) notifyListeners();
            return false;
          }
          encKey = bytes;
        }
      }
    } catch (_) {
      // Payload is not JSON (or has no 'ek'). Fine: signing key still learned.
    }

    if (existing != null &&
        _sameBytes(existing.signingKey, e.senderPubkey) &&
        _sameNullable(existing.encryptionKey, encKey)) {
      return true; // nothing new
    }

    final peer = PeerKeys(
      fingerprint: fp,
      signingKey: Uint8List.fromList(e.senderPubkey),
      encryptionKey: encKey,
    );
    _byFingerprint[fp] = peer;
    await _persist(peer);
    notifyListeners();
    return true;
  }

  Future<void> _persist(PeerKeys p) async => _prefs?.setString(
        '$_prefix${p.fingerprint}',
        jsonEncode({
          'sig': base64Encode(p.signingKey),
          'enc': p.encryptionKey == null
              ? null
              : base64Encode(p.encryptionKey!),
        }),
      );

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameNullable(Uint8List? a, Uint8List? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return _sameBytes(a, b);
  }

  @visibleForTesting
  void clear() {
    _byFingerprint.clear();
    conflicts.clear();
  }
}
