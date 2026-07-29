import 'package:crisis_mesh/app/report.dart';
import 'package:crisis_mesh/gossip/envelope.dart';
import 'package:crisis_mesh/gossip/identity.dart';
import 'package:crisis_mesh/store/envelope_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Identity me;
  setUpAll(() async => me = await Identity.generate());

  Future<Envelope> report(ReportKind kind, {String? note}) => me.compose(
        type: EnvelopeType.mapReport,
        payload: encodePayload(MapReport.toJson(
          kind: kind,
          lat: 23.8103,
          lon: 90.4125,
          note: note,
        )),
      );

  group('map report', () {
    test('round-trips through the envelope', () async {
      final e = await report(ReportKind.roadBlocked, note: 'bridge is down');
      final r = MapReport.fromEnvelope(Envelope.decode(e.encode()))!;

      expect(r.kind, ReportKind.roadBlocked);
      expect(r.lat, closeTo(23.8103, 0.00001));
      expect(r.lon, closeTo(90.4125, 0.00001));
      expect(r.note, 'bridge is down');
      expect(r.reporter, me.fingerprint);
    });

    test('a report with no coordinates is rejected, not half-drawn', () async {
      final e = await me.compose(
        type: EnvelopeType.mapReport,
        payload: encodePayload({'kind': 'fire'}),
      );
      expect(MapReport.fromEnvelope(e), isNull);
    });

    test('an unknown kind falls back to danger rather than vanishing', () async {
      final e = await me.compose(
        type: EnvelopeType.mapReport,
        payload: encodePayload({'kind': 'alien-landing', 'lat': 1.0, 'lon': 2.0}),
      );
      expect(MapReport.fromEnvelope(e)!.kind, ReportKind.danger);
    });

    test('a non-report envelope is not a report', () async {
      final chat = await me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'hi'}),
      );
      expect(MapReport.fromEnvelope(chat), isNull);
    });

    test('every kind carries both languages and an icon', () {
      for (final k in ReportKind.values) {
        expect(k.english, isNotEmpty);
        expect(k.bangla, isNotEmpty);
        expect(k.emoji, isNotEmpty);
      }
    });
  });

  group('confidence', () {
    test('thresholds are reachable in a four-phone demo', () async {
      final e = await report(ReportKind.shelter);
      final r = MapReport.fromEnvelope(e)!;

      expect(r.confidence, 'UNCONFIRMED');
      expect(r.withConfirms(1).confidence, 'LOW');
      expect(r.withConfirms(2).confidence, 'MEDIUM');
      expect(r.withConfirms(3).confidence, 'HIGH');
      expect(r.withConfirms(30).confidence, 'HIGH');
    });

    test('confirms from the same person count once', () async {
      final store = MemoryEnvelopeStore();
      await store.markConfirm('R1', 'AAAA1111');
      await store.markConfirm('R1', 'AAAA1111');
      await store.markConfirm('R1', 'BBBB2222');

      expect(await store.confirmCount('R1'), 2);
    });

    test('a confirm that outruns its report is still counted', () async {
      // Different gossip paths mean ordering is never guaranteed. Dropping
      // orphan confirms would under-count silently, and it would look fine in
      // rehearsal, which is the worst way for a bug to behave.
      final store = MemoryEnvelopeStore();
      await store.markConfirm('LATER', 'AAAA1111');

      final e = await report(ReportKind.water);
      await store.put(e);

      expect(await store.confirmCount('LATER'), 1);
    });
  });
}
