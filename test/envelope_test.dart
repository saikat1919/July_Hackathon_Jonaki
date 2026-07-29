import 'dart:typed_data';

import 'package:crisis_mesh/gossip/envelope.dart';
import 'package:crisis_mesh/gossip/identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('envelope wire format', () {
    test('signed bytes are identical for the same logical envelope', () {
      final id = Envelope.newId();
      final ts = DateTime.fromMillisecondsSinceEpoch(1750000000000);
      final pk = Uint8List.fromList(List.filled(32, 7));
      final pl = Uint8List.fromList([1, 2, 3]);

      Uint8List build() => Envelope.signedBytes(
            id: id,
            typeWire: EnvelopeType.chat.wire,
            timestamp: ts,
            lifetime: const Duration(hours: 24),
            senderPubkey: pk,
            payload: pl,
          );

      expect(build(), equals(build()));
    });

    test('signed region excludes ttl, remaining and path so relays cannot break it',
        () async {
      final me = await Identity.generate();
      final e = await me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'hi'}),
      );
      final before = e.signingInput;

      // Simulate three hops rewriting every mutable field.
      e.ttl -= 3;
      e.remaining = const Duration(minutes: 5);
      e.path
        ..add(Uint8List.fromList([1, 1, 1, 1]))
        ..add(Uint8List.fromList([2, 2, 2, 2]))
        ..add(Uint8List.fromList([3, 3, 3, 3]));

      expect(e.signingInput, equals(before));
      expect(
        await Identity.verify(e.signingInput, e.signature, e.senderPubkey),
        isTrue,
        reason: 'signature must survive three relays',
      );
    });

    test('round-trips through encode/decode with the mutable header intact',
        () async {
      final me = await Identity.generate();
      final e = await me.compose(
        type: EnvelopeType.sos,
        payload: encodePayload({'kind': 'medical', 'note': 'leg injury'}),
      );
      e.path.add(Uint8List.fromList([9, 8, 7, 6]));
      e.remaining = const Duration(minutes: 42);

      final back = Envelope.decode(e.encode());

      expect(back.idHex, e.idHex);
      expect(back.typeWire, EnvelopeType.sos.wire);
      expect(back.ttl, e.ttl);
      expect(back.remaining, const Duration(minutes: 42));
      expect(back.path.length, 1);
      expect(decodePayload(back.payload)['kind'], 'medical');
      expect(
        await Identity.verify(back.signingInput, back.signature, back.senderPubkey),
        isTrue,
      );
    });

    test('ids are 16 raw bytes, not 36-char uuid strings', () {
      expect(Envelope.newId().length, 16);
    });

    test('oversize payload is rejected at build time', () {
      expect(
        () => encodePayload({'t': 'x' * (maxPayloadBytes + 100)}),
        throwsArgumentError,
      );
    });

    test('truncated frame throws rather than yielding a half envelope', () {
      final bytes = Uint8List.fromList([1, 0, 1, 2, 3]);
      expect(() => Envelope.decode(bytes), throwsA(isA<FormatException>()));
    });

    test('unknown type still decodes and keeps priority behind known types', () {
      final e = Envelope(
        id: Envelope.newId(),
        typeWire: 99,
        timestamp: DateTime.now(),
        lifetime: const Duration(hours: 1),
        senderPubkey: Uint8List.fromList(List.filled(32, 1)),
        payload: Uint8List(0),
        signature: Uint8List.fromList(List.filled(64, 2)),
        ttl: 4,
        remaining: const Duration(hours: 1),
      );
      final back = Envelope.decode(e.encode());
      expect(back.type, isNull);
      expect(back.priority, greaterThan(EnvelopeType.chat.priority));
    });
  });

  group('priority order', () {
    test('sos sorts ahead of reports, reports ahead of chat', () {
      expect(EnvelopeType.sos.priority, lessThan(EnvelopeType.mapReport.priority));
      expect(
        EnvelopeType.mapReport.priority,
        lessThan(EnvelopeType.chat.priority),
      );
    });

    test('only sos types outlive their ttl', () {
      expect(EnvelopeType.sos.outlivesTtl, isTrue);
      expect(EnvelopeType.sosCancel.outlivesTtl, isTrue);
      expect(EnvelopeType.chat.outlivesTtl, isFalse);
      expect(EnvelopeType.mapReport.outlivesTtl, isFalse);
    });
  });
}
