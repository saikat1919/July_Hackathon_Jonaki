import 'dart:typed_data';

import 'package:crisis_mesh/app/chat.dart';
import 'package:crisis_mesh/gossip/envelope.dart';
import 'package:crisis_mesh/gossip/identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Identity me;
  setUpAll(() async => me = await Identity.generate());

  group('chat payload', () {
    test('broadcast has no recipient', () async {
      final e = await me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'road is blocked'}),
      );
      final m = ChatMessage.fromEnvelope(e, me.fingerprint)!;
      expect(m.isBroadcast, isTrue);
      expect(m.to, isNull);
      expect(m.text, 'road is blocked');
      expect(m.mine, isTrue);
    });

    test('addressed message carries the recipient fingerprint', () async {
      final e = await me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'meet at the camp', 'to': 'AAAA1111'}),
      );
      final m = ChatMessage.fromEnvelope(e, me.fingerprint)!;
      expect(m.isBroadcast, isFalse);
      expect(m.to, 'AAAA1111');
    });

    test('hop count comes from the relay path', () async {
      final e = await me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'t': 'hi'}),
      );
      final relayed = Envelope.decode(e.encode());
      relayed.path
        ..add(Uint8List.fromList([1, 1, 1, 1]))
        ..add(Uint8List.fromList([2, 2, 2, 2]));
      final m = ChatMessage.fromEnvelope(relayed, 'SOMEONEELSE')!;
      expect(m.hops, 2);
      expect(m.mine, isFalse);
    });

    test('a non-chat envelope is not a chat message', () async {
      final sos = await me.compose(
        type: EnvelopeType.sos,
        payload: encodePayload({'kind': 'fire'}),
      );
      expect(ChatMessage.fromEnvelope(sos, me.fingerprint), isNull);
    });

    test('a chat envelope with no text is ignored rather than crashing',
        () async {
      final e = await me.compose(
        type: EnvelopeType.chat,
        payload: encodePayload({'nonsense': true}),
      );
      expect(ChatMessage.fromEnvelope(e, me.fingerprint), isNull);
    });
  });

  group('threading', () {
    const me1 = 'AAAA1111';
    const peer = 'BBBB2222';
    const other = 'CCCC3333';

    ChatMessage msg({required String from, String? to}) => ChatMessage(
          id: 'x',
          from: from,
          to: to,
          text: 't',
          sentAt: DateTime.now(),
          hops: 1,
          mine: from == me1,
        );

    test('broadcasts land in the broadcast thread only', () {
      final b = msg(from: peer);
      expect(b.inThreadWith(null, me1), isTrue);
      expect(b.inThreadWith(peer, me1), isFalse);
    });

    test('a DM to me appears in that sender thread, not in broadcast', () {
      final dm = msg(from: peer, to: me1);
      expect(dm.inThreadWith(peer, me1), isTrue);
      expect(dm.inThreadWith(null, me1), isFalse);
    });

    test('my DM to a peer appears in that peer thread', () {
      final dm = msg(from: me1, to: peer);
      expect(dm.inThreadWith(peer, me1), isTrue);
    });

    test("someone else's DM never leaks into my thread view", () {
      // It still relays through my phone; it just is not mine to display.
      final notMine = msg(from: peer, to: other);
      expect(notMine.inThreadWith(peer, me1), isFalse);
      expect(notMine.inThreadWith(other, me1), isFalse);
      expect(notMine.inThreadWith(null, me1), isFalse);
    });
  });
}
