import 'dart:typed_data';

import 'package:crisis_mesh/app/sos.dart';
import 'package:crisis_mesh/gossip/envelope.dart';
import 'package:crisis_mesh/gossip/identity.dart';
import 'package:crisis_mesh/store/envelope_store.dart';
import 'package:crisis_mesh/store/sqflite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The persistent store is only safe to swap in if it behaves exactly like the
/// in-memory one every test and the 4-node simulation are written against.
/// So the contract is run against BOTH, and a divergence fails the build.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Identity me;
  late Identity other;
  setUpAll(() async {
    me = await Identity.generate();
    other = await Identity.generate();
  });

  Future<Envelope> chat(String t) => me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': t}),
      );

  Future<Envelope> sos({int? ttl, DateTime? now}) => me.compose(
        type: EnvelopeType.sos,
        payload: encodePayload(SosPayload(kind: SosKind.medical).toJson()),
        ttl: ttl,
        now: now,
      );

  /// Runs the same expectations against both implementations.
  void contract(String name, Future<void> Function(EnvelopeStore) body) {
    test('$name [memory]', () => body(MemoryEnvelopeStore()));
    test('$name [sqflite]', () async {
      final db = await SqfliteEnvelopeStore.open(path: inMemoryDatabasePath);
      await body(db);
      await db.close();
    });
  }

  group('store contract', () {
    contract('put stores, second put dedups', (s) async {
      final e = await chat('hi');
      expect(await s.put(e), isTrue);
      expect(await s.put(e), isFalse);
      expect((await s.all()).length, 1);
    });

    contract('get returns the envelope with fields intact', (s) async {
      final e = await chat('bridge is closed');
      await s.put(e);
      final back = await s.get(e.id);
      expect(back, isNotNull);
      expect(back!.idHex, e.idHex);
      expect(decodePayload(back.payload)['t'], 'bridge is closed');
      expect(back.senderPubkey, equals(e.senderPubkey));
      expect(back.signature, equals(e.signature));
      expect(back.ttl, e.ttl);
    });

    contract('signature still verifies after a storage round trip', (s) async {
      final e = await chat('authentic');
      await s.put(e);
      final back = (await s.get(e.id))!;
      expect(
        await Identity.verify(
            back.signingInput, back.signature, back.senderPubkey),
        isTrue,
        reason: 'storage must not corrupt the signed bytes',
      );
    });

    contract('relay path survives storage', (s) async {
      final e = await chat('relayed');
      e.path
        ..add(Uint8List.fromList([1, 2, 3, 4]))
        ..add(Uint8List.fromList([5, 6, 7, 8]));
      await s.put(e);
      final back = (await s.get(e.id))!;
      expect(back.path.length, 2);
      expect(back.path[1], equals(Uint8List.fromList([5, 6, 7, 8])));
    });

    contract('knownIds is sorted for the HAVE exchange', (s) async {
      for (var i = 0; i < 6; i++) {
        await s.put(await chat('m$i'));
      }
      final ids = await s.knownIds();
      expect(ids.length, 6);
      for (final id in ids) {
        expect(id.length, 16, reason: 'raw 16-byte ids, never uuid strings');
      }
      final hexes = [for (final i in ids) hexOf(i)];
      final sorted = [...hexes]..sort();
      expect(hexes, equals(sorted));
    });

    contract('offerable puts SOS ahead of chat', (s) async {
      for (var i = 0; i < 3; i++) {
        await s.put(await chat('filler $i'));
      }
      final alarm = await sos();
      await s.put(alarm);
      final offered = await s.offerable();
      expect(offered.first.idHex, alarm.idHex);
    });

    contract('ttl 0 non-SOS is kept but not offered', (s) async {
      final e = await me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'spent'}),
        ttl: 0,
      );
      await s.put(e);
      expect(await s.offerable(), isEmpty);
      expect((await s.all()).length, 1);
      expect(await s.get(e.id), isNotNull);
    });

    contract('ttl 0 SOS is still offered until it expires', (s) async {
      await s.put(await sos(ttl: 0));
      expect((await s.offerable()).length, 1);
    });

    contract('expired envelopes are neither offered nor kept', (s) async {
      final t0 = DateTime(2026, 7, 30, 12);
      await s.put(await sos(now: t0), now: t0);
      final later = t0.add(const Duration(hours: 3)); // 2h lifetime
      expect(await s.offerable(now: later), isEmpty);
      expect(await s.sweepExpired(now: later), 1);
      expect(await s.all(), isEmpty);
    });

    contract('expiry stamp is receivedAt + remaining', (s) async {
      final now = DateTime(2026, 7, 30, 12);
      final e = await chat('hi');
      e.remaining = const Duration(minutes: 10);
      await s.put(e, now: now);
      expect(await s.expiryOf(e.idHex), now.add(const Duration(minutes: 10)));
    });

    contract('confirms dedup per identity', (s) async {
      await s.markConfirm('R1', 'AAAA1111');
      await s.markConfirm('R1', 'AAAA1111');
      await s.markConfirm('R1', 'BBBB2222');
      expect(await s.confirmCount('R1'), 2);
    });

    contract('a confirm arriving before its report is still counted', (s) async {
      await s.markConfirm('LATER', 'AAAA1111');
      expect(await s.confirmCount('LATER'), 1);
    });

    contract('the sender can cancel their own SOS', (s) async {
      final alarm = await sos();
      await s.put(alarm);
      expect((await s.offerable()).length, 1);
      await s.markCancelled(alarm.idHex, me.fingerprint);
      expect(await s.offerable(), isEmpty);
      expect(await s.isCancelledBy(alarm.idHex, me.fingerprint), isTrue);
    });

    contract('a stranger cannot cancel someone else\'s SOS', (s) async {
      final alarm = await sos();
      await s.put(alarm);
      await s.markCancelled(alarm.idHex, other.fingerprint);
      expect((await s.offerable()).length, 1,
          reason: 'a forged cancel must be ignored');
      expect(await s.isCancelledBy(alarm.idHex, me.fingerprint), isFalse);
    });

    contract('a cancel arriving before its SOS still works', (s) async {
      final alarm = await sos();
      await s.markCancelled(alarm.idHex, me.fingerprint);
      await s.put(alarm);
      expect(await s.offerable(), isEmpty);
    });

    contract('cancelling one SOS does not silence another', (s) async {
      final a = await sos();
      final b = await sos();
      await s.put(a);
      await s.put(b);
      await s.markCancelled(a.idHex, me.fingerprint);
      final live = await s.offerable();
      expect(live.length, 1);
      expect(live.single.idHex, b.idHex);
    });
  });

  group('persistence across a restart', () {
    test('messages survive closing and reopening the database', () async {
      final dir = await databaseFactory.getDatabasesPath();
      final path = '$dir/restart_test.db';
      await databaseFactory.deleteDatabase(path);

      final first = await SqfliteEnvelopeStore.open(path: path);
      final e = await chat('still here after restart');
      await first.put(e);
      await first.markConfirm('R1', 'AAAA1111');
      await first.close();

      final second = await SqfliteEnvelopeStore.open(path: path);
      final back = await second.get(e.id);
      expect(back, isNotNull, reason: 'this is the whole point of the feature');
      expect(decodePayload(back!.payload)['t'], 'still here after restart');
      expect(await second.confirmCount('R1'), 1);
      await second.close();
      await databaseFactory.deleteDatabase(path);
    });

    test('a cancel survives a restart', () async {
      final dir = await databaseFactory.getDatabasesPath();
      final path = '$dir/restart_cancel.db';
      await databaseFactory.deleteDatabase(path);

      final first = await SqfliteEnvelopeStore.open(path: path);
      final alarm = await sos();
      await first.put(alarm);
      await first.markCancelled(alarm.idHex, me.fingerprint);
      await first.close();

      final second = await SqfliteEnvelopeStore.open(path: path);
      expect(await second.offerable(), isEmpty,
          reason: 'a cancelled SOS must not come back to life on restart');
      await second.close();
      await databaseFactory.deleteDatabase(path);
    });

    test('expired messages do not return after a restart', () async {
      final dir = await databaseFactory.getDatabasesPath();
      final path = '$dir/restart_expiry.db';
      await databaseFactory.deleteDatabase(path);
      final t0 = DateTime(2026, 7, 30, 12);

      final first = await SqfliteEnvelopeStore.open(path: path);
      await first.put(await sos(now: t0), now: t0);
      await first.close();

      final second = await SqfliteEnvelopeStore.open(path: path);
      final later = t0.add(const Duration(hours: 3));
      expect(await second.sweepExpired(now: later), 1);
      expect(await second.all(), isEmpty);
      await second.close();
      await databaseFactory.deleteDatabase(path);
    });
  });
}
