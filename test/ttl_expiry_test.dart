import 'package:crisis_mesh/gossip/envelope.dart';
import 'package:crisis_mesh/gossip/identity.dart';
import 'package:crisis_mesh/store/envelope_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The silent-failure cluster. None of these fail loudly on stage — the message
/// is simply not there — so they get tested rather than eyeballed.
void main() {
  late Identity me;
  setUpAll(() async => me = await Identity.generate());

  group('ttl bounds forwarding, never deletion', () {
    test('ttl > 0 is offered', () async {
      final store = MemoryEnvelopeStore();
      final e = await me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'hi'}),
      );
      await store.put(e);
      expect((await store.offerable()).length, 1);
    });

    test('ttl 0 non-SOS is retained and readable but no longer offered',
        () async {
      final store = MemoryEnvelopeStore();
      final e = await me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'hi'}),
        ttl: 0,
      );
      await store.put(e);

      expect(await store.offerable(), isEmpty, reason: 'stops being offered');
      expect((await store.all()).length, 1, reason: 'but is NOT deleted');
      expect(await store.get(e.id), isNotNull, reason: 'and stays readable');
    });

    test('ttl 0 SOS that has not expired is STILL offered', () async {
      final store = MemoryEnvelopeStore();
      final sos = await me.compose(
        type: EnvelopeType.sos,
        payload: encodePayload({'kind': 'medical'}),
        ttl: 0,
      );
      await store.put(sos);

      expect(
        (await store.offerable()).length,
        1,
        reason: 'SOS outlives its hop budget until it expires',
      );
    });

    test('expired SOS is neither offered nor kept', () async {
      final store = MemoryEnvelopeStore();
      final t0 = DateTime(2026, 7, 29, 12);
      final sos = await me.compose(
        type: EnvelopeType.sos,
        payload: encodePayload({'kind': 'medical'}),
        ttl: 0,
        now: t0,
      );
      await store.put(sos, now: t0);

      final later = t0.add(const Duration(hours: 3)); // lifetime is 2h
      expect(await store.offerable(now: later), isEmpty);
      expect(await store.sweepExpired(now: later), 1);
      expect(await store.all(), isEmpty);
    });
  });

  group('expiry is clock-free', () {
    test('a peer with a wildly wrong clock does not poison expiry', () async {
      final store = MemoryEnvelopeStore();
      final localNow = DateTime(2026, 7, 29, 12);

      // Sender's clock is two days fast. Under absolute expiry this SOS would
      // arrive already dead (or immortal); with remaining-time it is unaffected.
      final skewed = await me.compose(
        type: EnvelopeType.sos,
        payload: encodePayload({'kind': 'fire'}),
        now: localNow.add(const Duration(days: 2)),
      );
      await store.put(skewed, now: localNow);

      expect(
        await store.offerable(now: localNow.add(const Duration(minutes: 30))),
        hasLength(1),
        reason: 'still alive 30 min later on the local clock',
      );
      expect(
        await store.offerable(now: localNow.add(const Duration(hours: 3))),
        isEmpty,
        reason: 'and correctly dead after its 2h lifetime',
      );
    });

    test('forwarding remaining time does not restart the clock (immortality bug)',
        () async {
      // The bug this guards: if each hop stamped a FRESH lifetime, an envelope
      // re-offered on every reconnect would never expire, and every rehearsal
      // SOS would become permanent mesh garbage.
      final t0 = DateTime(2026, 7, 29, 12);
      final origin = await me.compose(
        type: EnvelopeType.sos,
        payload: encodePayload({'kind': 'flood'}),
        now: t0,
      );

      var hopTime = t0;
      var carried = origin;
      // Three hops, each dwelling 50 minutes: 150 min total against a 2h life.
      for (var hop = 0; hop < 3; hop++) {
        final store = MemoryEnvelopeStore();
        await store.put(carried, now: hopTime);
        hopTime = hopTime.add(const Duration(minutes: 50));

        final expiry = await store.expiryOf(carried.idHex);
        final remaining = expiry!.difference(hopTime);

        if (remaining <= Duration.zero) {
          expect(hop, 2, reason: 'must die on the third hop, not live forever');
          expect(await store.offerable(now: hopTime), isEmpty);
          return;
        }
        final next = carried.copy()..remaining = remaining;
        carried = next;
      }
      fail('envelope survived 150 minutes of a 120 minute lifetime');
    });

    test('local expiry stamp is receivedAt + remaining', () async {
      final store = MemoryEnvelopeStore();
      final now = DateTime(2026, 7, 29, 12);
      final e = await me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'hi'}),
        now: now,
      );
      e.remaining = const Duration(minutes: 10);
      await store.put(e, now: now);

      expect(
        await store.expiryOf(e.idHex),
        now.add(const Duration(minutes: 10)),
      );
    });
  });
}
