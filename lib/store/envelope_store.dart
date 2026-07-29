import 'dart:typed_data';

import '../gossip/envelope.dart';

/// One table, one relay path. Chat, SOS, map reports and confirms all live here.
/// A per-feature repository would triplicate store/relay/dedup/expiry — the exact
/// logic the day-2 gate depends on — and guarantee the copies drift apart.
///
/// Two implementations exist for a real reason: memory for tests and the 4-node
/// simulation (fast, no plugins), sqflite for the app.
abstract class EnvelopeStore {
  /// Stores if unseen. Returns false when the id is already known (dedup), in
  /// which case nothing is re-stored and nothing is re-relayed.
  Future<bool> put(Envelope e, {DateTime? now});

  Future<Envelope?> get(Uint8List id);

  /// Local expiry stamp = receivedAt + remaining. Clock-free by construction:
  /// a peer with a wrong clock only mis-expires its own copy.
  Future<DateTime?> expiryOf(String idHex);

  /// Ids known locally, sorted, for the HAVE exchange. Raw 16-byte ids.
  Future<List<Uint8List>> knownIds();

  /// What this node will hand to a peer, already in send order.
  Future<List<Envelope>> offerable({DateTime? now});

  Future<List<Envelope>> all();

  /// Drops everything past its local expiry. Returns how many went.
  Future<int> sweepExpired({DateTime? now});

  Future<void> markConfirm(String reportIdHex, String confirmerFingerprint);

  Future<int> confirmCount(String reportIdHex);
}

class StoredEnvelope {
  StoredEnvelope(this.envelope, this.expiresAt);
  final Envelope envelope;
  final DateTime expiresAt;
}

class MemoryEnvelopeStore implements EnvelopeStore {
  final Map<String, StoredEnvelope> _byId = {};

  /// report id -> set of confirmer fingerprints. Confirms are kept in their own
  /// map keyed by report id and stored even when the report has not arrived yet:
  /// gossip takes different paths, so a confirm can outrun the thing it confirms.
  /// Dropping orphans would silently under-count on stage.
  final Map<String, Set<String>> _confirms = {};

  @override
  Future<bool> put(Envelope e, {DateTime? now}) async {
    final key = e.idHex;
    if (_byId.containsKey(key)) return false;
    final t = now ?? DateTime.now();
    _byId[key] = StoredEnvelope(e, t.add(e.remaining));
    return true;
  }

  @override
  Future<Envelope?> get(Uint8List id) async => _byId[hexOf(id)]?.envelope;

  @override
  Future<List<Uint8List>> knownIds() async {
    final ids = _byId.values.map((s) => s.envelope.id).toList();
    ids.sort(_compareBytes);
    return ids;
  }

  @override
  Future<List<Envelope>> offerable({DateTime? now}) async {
    final t = now ?? DateTime.now();
    final out = <Envelope>[];
    for (final s in _byId.values) {
      if (!s.expiresAt.isAfter(t)) continue; // expired: not offered, swept later
      final e = s.envelope;
      // ttl bounds forwarding only. At ttl 0 an envelope stays readable but
      // stops being offered — except SOS, which keeps going until it expires.
      if (e.ttl > 0 || e.outlivesTtl) out.add(e);
    }
    out.sort((a, b) {
      final p = a.priority.compareTo(b.priority);
      return p != 0 ? p : a.timestamp.compareTo(b.timestamp);
    });
    return out;
  }

  @override
  Future<List<Envelope>> all() async =>
      _byId.values.map((s) => s.envelope).toList();

  @override
  Future<int> sweepExpired({DateTime? now}) async {
    final t = now ?? DateTime.now();
    final dead = _byId.entries
        .where((e) => !e.value.expiresAt.isAfter(t))
        .map((e) => e.key)
        .toList();
    for (final k in dead) {
      _byId.remove(k);
    }
    return dead.length;
  }

  @override
  Future<void> markConfirm(String reportIdHex, String confirmerFingerprint) async {
    _confirms.putIfAbsent(reportIdHex, () => <String>{}).add(confirmerFingerprint);
  }

  @override
  Future<int> confirmCount(String reportIdHex) async =>
      _confirms[reportIdHex]?.length ?? 0;

  @override
  Future<DateTime?> expiryOf(String idHex) async => _byId[idHex]?.expiresAt;
}

String hexOf(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

int _compareBytes(Uint8List a, Uint8List b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    final c = a[i].compareTo(b[i]);
    if (c != 0) return c;
  }
  return a.length.compareTo(b.length);
}

/// 1 = LOW, 2 = MEDIUM, 3+ = HIGH. Tuned so HIGH is reachable with 4 phones;
/// the original 5+ threshold could never be hit during judging.
String confidenceLabel(int confirms) {
  if (confirms >= 3) return 'HIGH';
  if (confirms == 2) return 'MEDIUM';
  if (confirms == 1) return 'LOW';
  return 'UNCONFIRMED';
}
