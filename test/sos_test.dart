import 'package:crisis_mesh/app/sos.dart';
import 'package:crisis_mesh/gossip/envelope.dart';
import 'package:crisis_mesh/gossip/identity.dart';
import 'package:crisis_mesh/store/envelope_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Identity me;
  late Identity other;
  setUpAll(() async {
    me = await Identity.generate();
    other = await Identity.generate();
  });

  group('sos payload', () {
    test('round-trips through the envelope', () async {
      final payload = SosPayload(
        kind: SosKind.flood,
        note: 'second floor, water rising',
        lat: 23.8103,
        lon: 90.4125,
        fix: FixSource.gps,
        battery: 18,
      );
      final e = await me.compose(
        type: EnvelopeType.sos,
        payload: encodePayload(payload.toJson()),
      );
      final back = SosPayload.fromJson(decodePayload(Envelope.decode(e.encode()).payload));

      expect(back.kind, SosKind.flood);
      expect(back.note, 'second floor, water rising');
      expect(back.lat, closeTo(23.8103, 0.00001));
      expect(back.battery, 18);
      expect(back.fix, FixSource.gps);
    });

    test('survives with no location at all, because that beats no SOS', () {
      final p = SosPayload(kind: SosKind.medical);
      expect(p.hasLocation, isFalse);
      expect(p.locationLabel, 'no location');
      final back = SosPayload.fromJson(p.toJson());
      expect(back.kind, SosKind.medical);
      expect(back.hasLocation, isFalse);
    });

    test('labels a stale fix as stale rather than pretending it is live', () {
      final p = SosPayload(
        kind: SosKind.fire,
        lat: 1,
        lon: 2,
        fix: FixSource.cached,
        fixAge: const Duration(minutes: 12),
      );
      expect(p.locationLabel, contains('last known'));
      expect(p.locationLabel, contains('12m ago'));
    });

    test('a manually placed pin says so', () {
      final p =
          SosPayload(kind: SosKind.missing, lat: 1, lon: 2, fix: FixSource.manual);
      expect(p.locationLabel, contains('placed by hand'));
    });

    test('unknown kind falls back to medical rather than crashing', () {
      final p = SosPayload.fromJson({'kind': 'zombie-apocalypse'});
      expect(p.kind, SosKind.medical);
    });

    test('every kind carries both languages', () {
      for (final k in SosKind.values) {
        expect(k.english, isNotEmpty);
        expect(k.bangla, isNotEmpty);
        expect(k.emoji, isNotEmpty);
      }
    });
  });

  group('sos cancellation', () {
    test('the sender can cancel their own SOS and it stops being offered',
        () async {
      final store = MemoryEnvelopeStore();
      final sos = await me.compose(
        type: EnvelopeType.sos,
        payload: encodePayload(SosPayload(kind: SosKind.medical).toJson()),
      );
      await store.put(sos);
      expect(await store.offerable(), hasLength(1));

      await store.markCancelled(sos.idHex, me.fingerprint);

      expect(await store.offerable(), isEmpty,
          reason: 'a cancelled SOS stops travelling immediately');
    });

    test('a stranger CANNOT cancel someone else\'s SOS', () async {
      // Otherwise anyone on the mesh could silence a real call for help.
      final store = MemoryEnvelopeStore();
      final sos = await me.compose(
        type: EnvelopeType.sos,
        payload: encodePayload(SosPayload(kind: SosKind.violence).toJson()),
      );
      await store.put(sos);

      await store.markCancelled(sos.idHex, other.fingerprint);

      expect(await store.offerable(), hasLength(1),
          reason: 'the forged cancel must be ignored');
      expect(await store.isCancelledBy(sos.idHex, me.fingerprint), isFalse);
    });

    test('a cancel arriving before its SOS still works', () async {
      // Gossip takes different paths; ordering is not guaranteed.
      final store = MemoryEnvelopeStore();
      final sos = await me.compose(
        type: EnvelopeType.sos,
        payload: encodePayload(SosPayload(kind: SosKind.fire).toJson()),
      );

      await store.markCancelled(sos.idHex, me.fingerprint); // cancel first
      await store.put(sos); // SOS arrives afterwards

      expect(await store.offerable(), isEmpty);
    });

    test('cancelling one SOS does not silence another', () async {
      final store = MemoryEnvelopeStore();
      final a = await me.compose(
        type: EnvelopeType.sos,
        payload: encodePayload(SosPayload(kind: SosKind.medical).toJson()),
      );
      final b = await me.compose(
        type: EnvelopeType.sos,
        payload: encodePayload(SosPayload(kind: SosKind.flood).toJson()),
      );
      await store.put(a);
      await store.put(b);

      await store.markCancelled(a.idHex, me.fingerprint);

      final live = await store.offerable();
      expect(live, hasLength(1));
      expect(live.single.idHex, b.idHex);
    });
  });

  group('sos priority', () {
    test('an SOS is offered before chat regardless of arrival order', () async {
      final store = MemoryEnvelopeStore();
      for (var i = 0; i < 5; i++) {
        await store.put(await me.compose(
          type: EnvelopeType.chat,
          payload: encodePayload({'t': 'filler $i'}),
        ));
      }
      final sos = await me.compose(
        type: EnvelopeType.sos,
        payload: encodePayload(SosPayload(kind: SosKind.medical).toJson()),
      );
      await store.put(sos); // arrives last

      final offered = await store.offerable();
      expect(offered.first.idHex, sos.idHex,
          reason: 'SOS jumps the queue on the wire');
    });
  });
}
