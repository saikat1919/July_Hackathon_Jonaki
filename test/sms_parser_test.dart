import 'package:crisis_mesh/app/sms_bridge.dart';
import 'package:crisis_mesh/app/sos.dart';
import 'package:flutter_test/flutter_test.dart';

/// The parser reads what frightened people actually type on a keypad: wrong
/// case, no punctuation, Bangla or English, often no keyword at all.
///
/// Two failure directions, and they are not equally bad. Missing a real SOS
/// costs someone help. A false positive broadcasts a fake emergency to every
/// phone in range and burns the gateway's credit. So the trigger is narrow and
/// the classification is generous.
void main() {
  group('recognising a call for help', () {
    test('plain SOS', () {
      expect(SmsParser.parse('SOS'), isNotNull);
    });

    test('case does not matter', () {
      for (final s in ['sos', 'SOS', 'Sos', 'sOs']) {
        expect(SmsParser.parse(s), isNotNull, reason: s);
      }
    });

    test('HELP works too', () {
      expect(SmsParser.parse('help my house is flooding'), isNotNull);
    });

    test('Bangla triggers work', () {
      expect(SmsParser.parse('সাহায্য আগুন'), isNotNull);
      expect(SmsParser.parse('বিপদ'), isNotNull);
      expect(SmsParser.parse('উদ্ধার করুন'), isNotNull);
    });

    test('leading and trailing whitespace is tolerated', () {
      expect(SmsParser.parse('   SOS fire   '), isNotNull);
    });

    test('separators people actually type are stripped from the note', () {
      expect(SmsParser.parse('SOS: fire')!.note, 'fire');
      expect(SmsParser.parse('SOS - fire')!.note, 'fire');
      expect(SmsParser.parse('SOS, fire')!.note, 'fire');
    });
  });

  group('NOT a call for help', () {
    test('ordinary texts are ignored', () {
      for (final s in [
        'hello are you coming',
        'your balance is 50 taka',
        'I heard there was an SOS in Mirpur', // mentions it, does not start
        'no sos here',
      ]) {
        expect(SmsParser.parse(s), isNull, reason: s);
      }
    });

    test('empty and null are ignored', () {
      expect(SmsParser.parse(''), isNull);
      expect(SmsParser.parse('   '), isNull);
      expect(SmsParser.parse(null), isNull);
    });
  });

  group('classification picks an icon, the note keeps the truth', () {
    test('detects each emergency type from English', () {
      expect(SmsParser.parse('SOS fire in the building')!.kind, SosKind.fire);
      expect(SmsParser.parse('SOS water rising fast')!.kind, SosKind.flood);
      expect(SmsParser.parse('SOS my father is injured')!.kind, SosKind.medical);
      expect(SmsParser.parse('SOS attack on the road')!.kind, SosKind.violence);
      expect(SmsParser.parse('SOS my son is missing')!.kind, SosKind.missing);
    });

    test('detects types from Bangla', () {
      expect(SmsParser.parse('SOS আগুন')!.kind, SosKind.fire);
      expect(SmsParser.parse('সাহায্য বন্যা')!.kind, SosKind.flood);
      expect(SmsParser.parse('SOS নিখোঁজ')!.kind, SosKind.missing);
    });

    test('the human words are always preserved verbatim', () {
      // A guessed category is worth far less to a rescuer than what the person
      // actually wrote.
      final p = SmsParser.parse('SOS trapped on the second floor of 14 Green Rd');
      expect(p!.note, 'trapped on the second floor of 14 Green Rd');
    });

    test('an unclassifiable SOS still gets through', () {
      final p = SmsParser.parse('SOS please come quickly');
      expect(p, isNotNull, reason: 'never drop a real call for help');
      expect(p!.note, 'please come quickly');
    });

    test('a bare SOS has no note rather than an empty one', () {
      expect(SmsParser.parse('SOS')!.note, isNull);
    });

    test('an overlong text is truncated, not rejected', () {
      final p = SmsParser.parse('SOS ${'x' * 500}');
      expect(p, isNotNull);
      expect(p!.note!.length, 160);
    });
  });

  group('phone number matching', () {
    test('the same number in different formats is recognised', () {
      // So an SMS-originated SOS is never texted back to the person who sent it.
      expect(
          SmsBridge.sameNumberForTest('+8801712345678', '01712345678'), isTrue);
      expect(
          SmsBridge.sameNumberForTest('8801712345678', '01712345678'), isTrue);
      expect(SmsBridge.sameNumberForTest('+880 1712 345678', '01712345678'),
          isTrue);
    });

    test('different numbers do not match', () {
      expect(
          SmsBridge.sameNumberForTest('01712345678', '01812345678'), isFalse);
    });

    test('empty input never matches', () {
      expect(SmsBridge.sameNumberForTest('', '01712345678'), isFalse);
    });
  });

  group('outbound text', () {
    test('fits what a two-line feature phone screen can show', () {
      final sos = SosPayload(
        kind: SosKind.fire,
        note: 'building 3',
        lat: 23.8103,
        lon: 90.4125,
        fix: FixSource.gps,
      );
      final text = SmsParser.outboundSms(sos, 'Niloy');
      expect(text, contains('Fire'));
      expect(text, contains('Niloy'));
      expect(text, contains('23.8103'));
      expect(text, contains('building 3'));
      expect(text.length, lessThan(160),
          reason: 'one SMS segment, so it costs one message');
    });

    test('says so plainly when there is no location', () {
      final text =
          SmsParser.outboundSms(SosPayload(kind: SosKind.medical), 'Rakib');
      expect(text, contains('location unknown'));
    });
  });
}
