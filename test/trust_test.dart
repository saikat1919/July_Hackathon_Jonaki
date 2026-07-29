import 'dart:typed_data';

import 'package:crisis_mesh/gossip/envelope.dart';
import 'package:crisis_mesh/store/envelope_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('confirm counting', () {
    test('a confirm arriving before its report is still counted', () async {
      // Gossip takes different paths, so a confirm can outrun the report it
      // confirms. Dropping orphans would silently under-count on stage — and
      // it would work fine in rehearsal, which is the worst kind of bug.
      final store = MemoryEnvelopeStore();
      const reportId = 'ABCD1234';

      await store.markConfirm(reportId, 'AAAA1111');
      expect(await store.confirmCount(reportId), 1);
    });

    test('the same pubkey confirming twice counts once', () async {
      final store = MemoryEnvelopeStore();
      await store.markConfirm('R1', 'AAAA1111');
      await store.markConfirm('R1', 'AAAA1111');
      expect(await store.confirmCount('R1'), 1);
    });

    test('distinct confirmers accumulate', () async {
      final store = MemoryEnvelopeStore();
      await store.markConfirm('R1', 'AAAA1111');
      await store.markConfirm('R1', 'BBBB2222');
      await store.markConfirm('R1', 'CCCC3333');
      expect(await store.confirmCount('R1'), 3);
    });

    test('unknown report has zero confirms', () async {
      final store = MemoryEnvelopeStore();
      expect(await store.confirmCount('NOPE'), 0);
    });
  });

  group('confidence badge', () {
    test('thresholds are reachable with four phones', () {
      expect(confidenceLabel(0), 'UNCONFIRMED');
      expect(confidenceLabel(1), 'LOW');
      expect(confidenceLabel(2), 'MEDIUM');
      expect(confidenceLabel(3), 'HIGH');
      expect(confidenceLabel(9), 'HIGH');
    });
  });

  group('dedup', () {
    test('the same envelope id is stored once', () async {
      final store = MemoryEnvelopeStore();
      final e = _fake();
      expect(await store.put(e), isTrue);
      expect(await store.put(e), isFalse, reason: 'second put is a no-op');
      expect((await store.all()).length, 1);
    });

    test('known ids come back sorted for the HAVE exchange', () async {
      final store = MemoryEnvelopeStore();
      for (var i = 0; i < 5; i++) {
        await store.put(_fake());
      }
      final ids = await store.knownIds();
      expect(ids.length, 5);
      for (var i = 1; i < ids.length; i++) {
        expect(ids[i - 1][0] <= ids[i][0], isTrue);
      }
    });
  });
}

Envelope _fake() => Envelope(
      id: Envelope.newId(),
      typeWire: EnvelopeType.chat.wire,
      timestamp: DateTime.now(),
      lifetime: const Duration(hours: 24),
      senderPubkey: Uint8List.fromList(List.filled(32, 1)),
      payload: Uint8List(0),
      signature: Uint8List.fromList(List.filled(64, 2)),
      ttl: defaultTtl,
      remaining: const Duration(hours: 24),
    );
