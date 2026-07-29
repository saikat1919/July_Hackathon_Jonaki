import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../gossip/identity.dart';

/// Keeps the identity seed across restarts.
///
/// Without this the app generates a new keypair on every launch, so your ID
/// changes, contacts point at a stranger, and every pinned encryption key is
/// orphaned. Persistent storage of anything else is pointless until the
/// identity itself is stable.
///
/// The seed lives in Android Keystore-backed secure storage, never in the
/// SQLite file. The database holds messages; losing it costs history. Losing
/// this costs the identity, and there is no recovery — which is also the
/// honest answer to "what if I lose my phone": you get a new ID.
class IdentityStore {
  static const _key = 'identity.seed.v1';
  // Defaults are correct on this version: the plugin uses its own ciphers and
  // the old encryptedSharedPreferences flag is deprecated and ignored.
  static const _storage = FlutterSecureStorage();

  /// Loads the saved identity, or creates and saves one on first run.
  static Future<Identity> loadOrCreate() async {
    try {
      final saved = await _storage.read(key: _key);
      if (saved != null) {
        final seed = base64Decode(saved);
        if (seed.length == 32) return Identity.fromSeed(seed);
      }
    } catch (_) {
      // Keystore unavailable or the entry is corrupt. Fall through and make a
      // fresh identity rather than refusing to start: an app that will not
      // open is worse than one that lost its history.
    }

    final identity = await Identity.generate();
    try {
      await _storage.write(
        key: _key,
        value: base64Encode(await identity.seed()),
      );
    } catch (_) {
      // Could not persist. The app still works for this session; the ID will
      // change next launch. Better than crashing on boot.
    }
    return identity;
  }

  /// Only for a deliberate reset. Wipes the identity permanently: no backup,
  /// no recovery, and every peer who pinned this key sees a conflict.
  static Future<void> forget() => _storage.delete(key: _key);
}
