import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../gossip/envelope.dart';
import 'envelope_store.dart';

/// The store that survives a restart.
///
/// Same contract as [MemoryEnvelopeStore], which is why the interface exists:
/// the in-memory one runs the 4-node simulation and every unit test with no
/// plugins, this one runs on the phone. Both must behave identically or the
/// tests stop meaning anything.
///
/// Why it matters for the demo: without it, killing the app loses every
/// message, alert and report. The mule beat is the sharpest case — a phone
/// carrying messages across a gap would arrive empty if Android killed it
/// during the walk.
class SqfliteEnvelopeStore implements EnvelopeStore {
  SqfliteEnvelopeStore._(this._db);

  final Database _db;

  static const _schema = 2;

  static Future<SqfliteEnvelopeStore> open({String? path}) async {
    final dbPath = path ?? '${await getDatabasesPath()}/crisis_mesh.db';
    final db = await openDatabase(
      dbPath,
      version: _schema,
      onCreate: (db, _) async => _create(db),
      onUpgrade: (db, _, _) async {
        // Envelopes are transient by design (24h/2h lifetimes), so a schema
        // change drops and recreates rather than carrying migration code that
        // would be written once and never exercised.
        await db.execute('DROP TABLE IF EXISTS envelopes');
        await db.execute('DROP TABLE IF EXISTS confirms');
        await db.execute('DROP TABLE IF EXISTS cancels');
        await _create(db);
      },
    );
    return SqfliteEnvelopeStore._(db);
  }

  static Future<void> _create(Database db) async {
    await db.execute('''
      CREATE TABLE envelopes (
        id          TEXT PRIMARY KEY,
        type        INTEGER NOT NULL,
        priority    INTEGER NOT NULL,
        timestamp   INTEGER NOT NULL,
        lifetime    INTEGER NOT NULL,
        sender      BLOB NOT NULL,
        sender_fp   TEXT NOT NULL,
        payload     BLOB NOT NULL,
        signature   BLOB NOT NULL,
        ttl         INTEGER NOT NULL,
        remaining   INTEGER NOT NULL,
        path        BLOB NOT NULL,
        expires_at  INTEGER NOT NULL
      )''');
    // Every read path filters on expiry, and the sweep deletes by it.
    await db.execute('CREATE INDEX idx_expires ON envelopes(expires_at)');
    // offerable() orders by priority then time; this is the query that runs on
    // every peer connection.
    await db.execute('CREATE INDEX idx_offer ON envelopes(priority, timestamp)');

    // Confirms live in their own table keyed by report id and are stored even
    // when the report has not arrived yet: gossip takes different paths, so a
    // confirm can outrun the thing it confirms.
    await db.execute('''
      CREATE TABLE confirms (
        report_id TEXT NOT NULL,
        confirmer TEXT NOT NULL,
        PRIMARY KEY (report_id, confirmer)
      )''');

    // A cancel is stored as a CLAIM. Only a cancel whose fingerprint matches
    // the SOS's real sender is honoured, or anyone could silence a call for
    // help. Storing it unverified also handles a cancel arriving first.
    await db.execute('''
      CREATE TABLE cancels (
        sos_id         TEXT PRIMARY KEY,
        by_fingerprint TEXT NOT NULL
      )''');
  }

  @override
  Future<bool> put(Envelope e, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    final count = await _db.insert(
      'envelopes',
      {
        'id': e.idHex,
        'type': e.typeWire,
        'priority': e.priority,
        'timestamp': e.timestamp.millisecondsSinceEpoch,
        'lifetime': e.lifetime.inSeconds,
        'sender': e.senderPubkey,
        'sender_fp': e.senderFingerprint,
        'payload': e.payload,
        'signature': e.signature,
        'ttl': e.ttl,
        'remaining': e.remaining.inSeconds,
        'path': _packPath(e.path),
        'expires_at': t.add(e.remaining).millisecondsSinceEpoch,
      },
      // Dedup by id: a second sighting is a no-op, not an overwrite.
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return count != 0;
  }

  @override
  Future<Envelope?> get(Uint8List id) async {
    final rows = await _db.query('envelopes',
        where: 'id = ?', whereArgs: [hexOf(id)], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  @override
  Future<DateTime?> expiryOf(String idHex) async {
    final rows = await _db.query('envelopes',
        columns: ['expires_at'],
        where: 'id = ?',
        whereArgs: [idHex.toUpperCase()],
        limit: 1);
    if (rows.isEmpty) return null;
    return DateTime.fromMillisecondsSinceEpoch(rows.first['expires_at'] as int);
  }

  @override
  Future<List<Uint8List>> knownIds() async {
    final rows =
        await _db.query('envelopes', columns: ['id'], orderBy: 'id ASC');
    return [for (final r in rows) _unhex(r['id'] as String)];
  }

  @override
  Future<List<Envelope>> offerable({DateTime? now}) async {
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    // ttl > 0, OR an SOS that has not expired (SOS outlives its hop budget).
    // Cancelled SOSes are excluded, but only when the cancel came from the
    // person who raised it.
    final rows = await _db.rawQuery('''
      SELECT e.* FROM envelopes e
      LEFT JOIN cancels c ON c.sos_id = e.id
      WHERE e.expires_at > ?
        AND (e.ttl > 0 OR e.type IN (?, ?))
        AND NOT (
          e.type = ?
          AND c.by_fingerprint IS NOT NULL
          AND c.by_fingerprint = e.sender_fp
        )
      ORDER BY e.priority ASC, e.timestamp ASC
    ''', [
      t,
      EnvelopeType.sos.wire,
      EnvelopeType.sosCancel.wire,
      EnvelopeType.sos.wire,
    ]);
    return [for (final r in rows) _fromRow(r)];
  }

  @override
  Future<List<Envelope>> all() async {
    final rows = await _db.query('envelopes', orderBy: 'timestamp DESC');
    return [for (final r in rows) _fromRow(r)];
  }

  @override
  Future<int> sweepExpired({DateTime? now}) async {
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return _db.delete('envelopes', where: 'expires_at <= ?', whereArgs: [t]);
  }

  @override
  Future<void> markConfirm(
      String reportIdHex, String confirmerFingerprint) async {
    await _db.insert(
      'confirms',
      {
        'report_id': reportIdHex.toUpperCase(),
        'confirmer': confirmerFingerprint.toUpperCase(),
      },
      // One confirm per identity: the primary key does the deduplication, so
      // confidence means "several people saw it", not "someone tapped a lot".
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  @override
  Future<int> confirmCount(String reportIdHex) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) c FROM confirms WHERE report_id = ?',
      [reportIdHex.toUpperCase()],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  @override
  Future<void> markCancelled(String sosIdHex, String byFingerprint) async {
    await _db.insert(
      'cancels',
      {
        'sos_id': sosIdHex.toUpperCase(),
        'by_fingerprint': byFingerprint.toUpperCase(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<bool> isCancelledBy(
      String sosIdHex, String senderFingerprint) async {
    final rows = await _db.query('cancels',
        columns: ['by_fingerprint'],
        where: 'sos_id = ?',
        whereArgs: [sosIdHex.toUpperCase()],
        limit: 1);
    if (rows.isEmpty) return false;
    return rows.first['by_fingerprint'] == senderFingerprint.toUpperCase();
  }

  Future<void> close() => _db.close();

  static Envelope _fromRow(Map<String, Object?> r) => Envelope(
        id: _unhex(r['id'] as String),
        typeWire: r['type'] as int,
        timestamp:
            DateTime.fromMillisecondsSinceEpoch(r['timestamp'] as int),
        lifetime: Duration(seconds: r['lifetime'] as int),
        senderPubkey: Uint8List.fromList(r['sender'] as List<int>),
        payload: Uint8List.fromList(r['payload'] as List<int>),
        signature: Uint8List.fromList(r['signature'] as List<int>),
        ttl: r['ttl'] as int,
        remaining: Duration(seconds: r['remaining'] as int),
        path: _unpackPath(Uint8List.fromList(r['path'] as List<int>)),
      );

  static Uint8List _packPath(List<Uint8List> path) {
    final b = BytesBuilder();
    for (final hop in path) {
      b.add(hop);
    }
    return b.toBytes();
  }

  static List<Uint8List> _unpackPath(Uint8List packed) => [
        for (var i = 0; i + fingerprintBytes <= packed.length;
            i += fingerprintBytes)
          Uint8List.fromList(
              packed.sublist(i, i + fingerprintBytes)),
      ];

  static Uint8List _unhex(String hex) => Uint8List.fromList([
        for (var i = 0; i + 2 <= hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
}
