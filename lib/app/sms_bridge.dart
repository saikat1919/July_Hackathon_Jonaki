import 'dart:async';

import 'package:another_telephony/telephony.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../gossip/envelope.dart';
import 'mesh_service.dart';
import 'sos.dart';

/// What a feature phone's text turned into.
class ParsedSms {
  const ParsedSms({required this.kind, this.note});
  final SosKind kind;
  final String? note;
}

/// Turns a text message into an SOS.
///
/// Pure function, no plugins, so the whole thing is testable without a SIM.
/// It has to cope with how people actually type under stress: wrong case, no
/// punctuation, Bangla or English, and often no keyword at all.
///
/// Rule: the detected kind only chooses an icon. The person's ACTUAL WORDS are
/// always kept as the note, because a guessed category is worth far less to a
/// rescuer than what someone wrote themselves.
class SmsParser {
  /// A message must open with one of these to count. Deliberately narrow:
  /// every false positive is a fake emergency broadcast to every phone in
  /// range, which is worse than missing an oddly-worded real one.
  static const _triggers = ['sos', 'help', 'সাহায্য', 'বিপদ', 'উদ্ধার'];

  static const Map<SosKind, List<String>> _keywords = {
    SosKind.fire: ['fire', 'burning', 'আগুন', 'অগ্নি'],
    SosKind.flood: ['flood', 'water', 'drown', 'বন্যা', 'পানি', 'ডুব'],
    SosKind.violence: [
      'violence', 'attack', 'shot', 'beaten', 'police',
      'সহিংসতা', 'হামলা', 'মারধর',
    ],
    SosKind.missing: ['missing', 'lost', 'নিখোঁজ', 'হারিয়ে'],
    SosKind.medical: [
      'medical', 'doctor', 'injured', 'hurt', 'bleeding', 'ambulance',
      'চিকিৎসা', 'আহত', 'ডাক্তার',
    ],
  };

  /// Returns null when the message is not a call for help.
  static ParsedSms? parse(String? body) {
    if (body == null) return null;
    final text = body.trim();
    if (text.isEmpty) return null;

    final lower = text.toLowerCase();
    final trigger = _triggers.firstWhere(
      (t) => lower.startsWith(t),
      orElse: () => '',
    );
    if (trigger.isEmpty) return null;

    // Everything after the trigger word is the human's own description.
    var rest = text.substring(trigger.length).trim();
    // Strip a leading separator people naturally type: "SOS - fire", "SOS: fire"
    rest = rest.replaceFirst(RegExp(r'^[\s:,\-–—]+'), '').trim();

    var kind = SosKind.medical; // default; the note carries the truth
    final restLower = rest.toLowerCase();
    for (final entry in _keywords.entries) {
      if (entry.value.any(restLower.contains)) {
        kind = entry.key;
        break;
      }
    }

    return ParsedSms(
      kind: kind,
      note: rest.isEmpty ? null : (rest.length > 160 ? rest.substring(0, 160) : rest),
    );
  }

  /// The reply a feature phone gets back. Short: it may be read on a two-line
  /// screen, and every character costs the gateway money.
  static String acknowledgement(SosKind kind) =>
      'Jonaki: your ${kind.english.toLowerCase()} SOS was relayed to phones '
      'nearby. Stay where you are if you can.';

  /// How a mesh SOS is described to a feature phone.
  static String outboundSms(SosPayload sos, String senderLabel) {
    final where = sos.hasLocation
        ? '${sos.lat!.toStringAsFixed(4)},${sos.lon!.toStringAsFixed(4)}'
        : 'location unknown';
    final note = (sos.note == null || sos.note!.isEmpty) ? '' : ' - ${sos.note}';
    return 'JONAKI SOS: ${sos.kind.english} from $senderLabel at $where$note';
  }
}

/// Bridges feature phones into the mesh over SMS.
///
///   button phone --SMS--> gateway (Jonaki + SIM) --> mesh --> every user
///   mesh SOS --> gateway --SMS--> registered feature phones
///
/// USSD would be the nicer channel for a feature phone (menu-driven, no
/// syntax to remember) but a shortcode requires an operator agreement. The
/// bridge is deliberately channel-agnostic: if a shortcode ever arrives, it
/// feeds this same logic and nothing below changes.
///
/// This helps in exactly one failure mode, and it is the common one: the
/// internet is cut but GSM voice and SMS still work, which is what happened in
/// July 2024. If the towers themselves are down, only the mesh survives — and
/// that is precisely why the app does not depend on this.
class SmsBridge extends ChangeNotifier {
  SmsBridge(this.mesh);

  final MeshService mesh;
  final _telephony = Telephony.instance;

  static const _enabledKey = 'sms.gateway.enabled';
  static const _numbersKey = 'sms.gateway.numbers';

  bool enabled = false;
  bool listening = false;
  final List<String> subscribers = [];
  final List<String> log = [];

  /// Numbers we have already replied to recently, so a stuck feature phone
  /// resending the same text cannot drain the gateway's credit.
  final Map<String, DateTime> _lastReplyTo = {};
  static const _replyCooldown = Duration(minutes: 2);

  /// Outbound budget. A gateway that silently spends 500 SMS is a worse
  /// outcome than one that stops and says so.
  int sentThisSession = 0;
  static const maxSendsPerSession = 50;

  StreamSubscription<Envelope>? _sosSub;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool(_enabledKey) ?? false;
    subscribers
      ..clear()
      ..addAll(prefs.getStringList(_numbersKey) ?? const []);
    if (enabled) await start();
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    enabled = value;
    await prefs.setBool(_enabledKey, value);
    if (value) {
      await start();
    } else {
      await stop();
    }
    notifyListeners();
  }

  Future<void> addSubscriber(String number) async {
    final n = number.trim();
    if (n.isEmpty || subscribers.contains(n)) return;
    subscribers.add(n);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_numbersKey, subscribers);
    notifyListeners();
  }

  Future<void> removeSubscriber(String number) async {
    subscribers.remove(number);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_numbersKey, subscribers);
    notifyListeners();
  }

  void _say(String line) {
    log.insert(0, line);
    if (log.length > 60) log.removeLast();
    notifyListeners();
  }

  Future<void> start() async {
    if (listening) return;
    final granted = await _telephony.requestPhoneAndSmsPermissions ?? false;
    if (!granted) {
      _say('SMS permission denied — gateway cannot run');
      enabled = false;
      notifyListeners();
      return;
    }

    // Foreground only. Background delivery needs a top-level isolate handler
    // and more moving parts than this earns; the demo posture is screen-on
    // anyway. Worth revisiting if the gateway ever runs unattended.
    _telephony.listenIncomingSms(
      onNewMessage: _onSms,
      listenInBackground: false,
    );
    listening = true;

    _sosSub = mesh.incomingSos.listen(_relayToSubscribers);
    _say('gateway listening for SMS');
    notifyListeners();
  }

  Future<void> stop() async {
    await _sosSub?.cancel();
    _sosSub = null;
    listening = false;
    _say('gateway stopped');
    notifyListeners();
  }

  Future<void> _onSms(SmsMessage message) async {
    final from = message.address ?? 'unknown';
    final parsed = SmsParser.parse(message.body);
    if (parsed == null) {
      _say('ignored non-SOS text from $from');
      return;
    }

    _say('SOS by SMS from $from → ${parsed.kind.english}');

    // Signed by THIS phone, not by the sender: a feature phone has no key.
    // smsOrigin makes that explicit everywhere the SOS is displayed.
    await mesh.sendSos(
      kind: parsed.kind,
      note: parsed.note,
      smsOrigin: from,
    );

    await _reply(from, SmsParser.acknowledgement(parsed.kind));
  }

  Future<void> _reply(String to, String text) async {
    final last = _lastReplyTo[to];
    if (last != null && DateTime.now().difference(last) < _replyCooldown) {
      return; // already acknowledged them a moment ago
    }
    _lastReplyTo[to] = DateTime.now();
    await _send(to, text);
  }

  /// Pushes a mesh SOS out to every registered feature phone.
  Future<void> _relayToSubscribers(Envelope e) async {
    if (!enabled || subscribers.isEmpty) return;
    final sos = SosPayload.fromJson(decodePayload(e.payload));

    // Never bounce an SMS-originated SOS back to the person who sent it.
    final origin = sos.smsOrigin;
    final label = mesh.nameOf(e.senderFingerprint);
    final text = SmsParser.outboundSms(sos, label);

    for (final number in subscribers) {
      if (origin != null && _sameNumber(number, origin)) continue;
      await _send(number, text);
    }
  }

  Future<void> _send(String to, String text) async {
    if (sentThisSession >= maxSendsPerSession) {
      _say('send budget reached ($maxSendsPerSession) — not sending');
      return;
    }
    try {
      await _telephony.sendSms(to: to, message: text, isMultipart: true);
      sentThisSession++;
      _say('sent SMS to $to');
    } catch (err) {
      _say('SMS to $to failed: $err');
    }
  }

  /// Compares numbers by their last 9 digits, so +8801712345678, 01712345678
  /// and 8801712345678 are recognised as the same person.
  static bool _sameNumber(String a, String b) {
    String tail(String s) {
      final digits = s.replaceAll(RegExp(r'\D'), '');
      return digits.length <= 9 ? digits : digits.substring(digits.length - 9);
    }

    final ta = tail(a);
    return ta.isNotEmpty && ta == tail(b);
  }

  @visibleForTesting
  static bool sameNumberForTest(String a, String b) => _sameNumber(a, b);

  @override
  void dispose() {
    _sosSub?.cancel();
    super.dispose();
  }
}
