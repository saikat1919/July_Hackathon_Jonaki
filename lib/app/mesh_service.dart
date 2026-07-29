import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../gossip/envelope.dart';
import '../gossip/gossip_node.dart';
import '../gossip/identity.dart';
import '../store/envelope_store.dart';
import '../transport/nearby_transport.dart';
import '../transport/transport.dart';
import '../gossip/crypto_box.dart';
import 'chat.dart';
import 'key_directory.dart';
import 'report.dart';
import 'sos.dart';

/// Owns the mesh for the whole app: identity, store, transport, node.
/// The UI reads this and nothing else.
class MeshService extends ChangeNotifier {
  MeshService({required this.serviceId});

  /// MUST differ between the demo build and the APK handed to judges. With the
  /// topology lock off by default, judges' phones would otherwise advertise
  /// into the demo's radio cluster, and 3+ simultaneous advertisers is the top
  /// known Nearby failure mode.
  final String serviceId;

  Identity? identity;
  MemoryEnvelopeStore? store;
  NearbyTransport? transport;
  GossipNode? node;

  final List<String> log = [];
  final List<Envelope> inbox = [];

  /// Peer keys learned from traffic and then pinned.
  final KeyDirectory keys = KeyDirectory();

  final _sosAlerts = StreamController<Envelope>.broadcast();

  /// Fires when someone else's SOS arrives, so the UI can take over the screen
  /// regardless of which tab is open.
  Stream<Envelope> get incomingSos => _sosAlerts.stream;
  bool running = false;
  String? startupError;

  String get fingerprint => identity?.fingerprint ?? '········';
  Set<String> get peers => transport?.connectedPeers ?? const {};
  int get syncCount => node?.syncCount ?? 0;
  int get rejected => node?.rejectedSignatures ?? 0;

  void _say(String line) {
    log.insert(0, line);
    if (log.length > 200) log.removeLast();
    notifyListeners();
  }

  Future<void> bootIdentity() async {
    identity = await Identity.generate();
    _say('identity ${identity!.fingerprint}');
  }

  /// Starts advertising and discovering. On one phone this finds nobody, which
  /// is fine — what it proves is that permissions are real and the Nearby
  /// startup path does not throw. That is most of the day-2 startup risk.
  Future<void> start() async {
    if (running) return;
    startupError = null;

    final missing = await NearbyTransport.ensurePermissions();
    if (missing.isNotEmpty) {
      startupError = 'missing permissions: ${missing.map(_short).join(', ')}';
      _say(startupError!);
      return;
    }
    if (!await NearbyTransport.locationServicesEnabled()) {
      // Granting the permission is not the same as having Location switched on.
      // Nearby thrashes without the service itself running.
      startupError = 'turn Location ON (the service, not just the permission)';
      _say(startupError!);
      return;
    }

    identity ??= await Identity.generate();
    final s = MemoryEnvelopeStore();
    final t = NearbyTransport(
      myFingerprint: identity!.fingerprint,
      serviceId: serviceId,
    );
    final n = GossipNode(identity: identity!, store: s, transport: t);

    n.accepted.listen((e) async {
      inbox.insert(0, e);
      // Learn keys from ordinary traffic. Hearing one global message from
      // someone is enough to message them privately afterwards.
      final trusted = await keys.learnFrom(e);
      if (!trusted) {
        _say('KEY CONFLICT from ${e.senderFingerprint} — not trusted');
      }
      _say('recv ${_label(e)} via ${e.path.length} hops');
      // Someone else's live SOS takes over the screen. Mine does not: I already
      // know, and alerting the sender would bury the cancel button.
      if (e.type == EnvelopeType.sos &&
          e.senderFingerprint != fingerprint &&
          !_sosAlerts.isClosed) {
        _sosAlerts.add(e);
      }
      notifyListeners();
    });
    t.events.listen((e) {
      _say(e.kind == PeerEventKind.connected
          ? 'peer + ${t.fingerprintOf(e.peerId) ?? e.peerId}'
          : 'peer − ${t.fingerprintOf(e.peerId) ?? e.peerId}');
      notifyListeners();
    });

    try {
      await n.start();
      // Screen-on is the demo posture: Android throttles radios for locked
      // devices, so the mule carry fails silently in a pocket.
      await WakelockPlus.enable();
      store = s;
      transport = t;
      node = n;
      running = true;
      _say('advertising + discovering on "$serviceId"');
    } catch (err) {
      startupError = 'start failed: $err';
      _say(startupError!);
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await node?.stop();
    await transport?.stop();
    await WakelockPlus.disable();
    running = false;
    _say('stopped');
  }

  /// Sends a chat message.
  ///
  /// [to] null  → GLOBAL: plaintext, readable by everyone the mesh reaches.
  /// [to] set   → PERSONAL: sealed so only that phone can read the text.
  ///
  /// Returns an error string when it refuses to send, null on success. It
  /// REFUSES rather than falling back to plaintext when the recipient's
  /// encryption key is unknown: a silent downgrade would turn the privacy
  /// promise into theatre, and the user would never know.
  Future<String?> sendChat(String text, {String? to}) async {
    final n = node;
    final me = identity;
    if (n == null || me == null) return 'mesh is not running';
    if (text.trim().isEmpty) return null;
    if (text.length > maxTextChars) {
      return 'message too long (${text.length}/$maxTextChars)';
    }

    final myEnc = base64Encode(me.encPublicKey);

    if (to == null) {
      await n.publish(
        EnvelopeType.chat,
        encodePayload({'t': text, 'ek': myEnc}),
      );
      _say(peers.isEmpty
          ? 'queued global (no peers yet)'
          : 'sent global to ${peers.length} peer(s)');
      return null;
    }

    final peerKeys = keys[to];
    if (peerKeys == null || !peerKeys.canEncrypt) {
      return 'Cannot encrypt to $to yet — no key received from them. '
          'Ask them to send a global message first.';
    }

    final sealed = await CryptoBox.seal(
      plaintext: text,
      myKeyPair: me.encKeyPair,
      theirPublicKey: peerKeys.encryptionKey!,
      senderFingerprint: fingerprint,
      recipientFingerprint: to,
    );

    await n.publish(
      EnvelopeType.chat,
      encodePayload({'to': to, 'enc': sealed, 'ek': myEnc}),
    );
    _say(peers.isEmpty
        ? 'queued personal to $to (no peers yet)'
        : 'sent personal to $to (encrypted)');
    return null;
  }

  /// Opens a sealed message. Returns null whenever this phone is not a party to
  /// it, which is the normal outcome for a relay and must never throw.
  Future<String?> _decrypt(
      String sealed, String senderFp, String recipientFp) async {
    final me = identity;
    if (me == null) return null;
    // The counterparty is whichever end of the pair is not me.
    final peerFp =
        senderFp.toUpperCase() == fingerprint.toUpperCase() ? recipientFp : senderFp;
    final peer = keys[peerFp];
    if (peer == null || !peer.canEncrypt) return null;
    return CryptoBox.open(
      sealed: sealed,
      myKeyPair: me.encKeyPair,
      theirPublicKey: peer.encryptionKey!,
      senderFingerprint: senderFp,
      recipientFingerprint: recipientFp,
    );
  }

  /// Everyone this phone has heard from, whether or not they are in range now.
  /// A peer who walked away still has a thread; the mesh will deliver later.
  Set<String> get knownFingerprints => {
        for (final e in inbox) e.senderFingerprint,
      }..remove(fingerprint);

  Future<List<ChatMessage>> messagesWith(String? peer) async {
    final me = fingerprint;
    final out = <ChatMessage>[];
    for (final e in inbox) {
      final m = await ChatMessage.fromEnvelope(e, me, decrypt: _decrypt);
      if (m != null && m.inThreadWith(peer, me)) out.add(m);
    }
    out.sort((a, b) => a.sentAt.compareTo(b.sentAt));
    return out;
  }

  /// Resolves location and battery, then sends. Location resolution is bounded
  /// (see [LocationResolver]) so an SOS is never held up waiting on a satellite
  /// fix that will not arrive indoors.
  Future<Envelope?> sendSos({
    required SosKind kind,
    String? note,
    double? manualLat,
    double? manualLon,
  }) async {
    final n = node;
    if (n == null) return null;

    double? lat = manualLat;
    double? lon = manualLon;
    var fix = FixSource.manual;
    Duration? age;

    if (manualLat == null || manualLon == null) {
      final r = await LocationResolver().resolve();
      lat = r.lat;
      lon = r.lon;
      fix = r.fix;
      age = r.age;
    }

    final payload = SosPayload(
      kind: kind,
      note: (note == null || note.trim().isEmpty) ? null : note.trim(),
      lat: lat,
      lon: lon,
      fix: fix,
      fixAge: age,
      battery: await readBatteryLevel(),
    );

    final e = await n.publish(EnvelopeType.sos, encodePayload(payload.toJson()));
    mySosIds.add(e.idHex);
    _say('SENT SOS ${kind.emoji} ${kind.english} · ${payload.locationLabel}');
    notifyListeners();
    return e;
  }

  /// SOS ids raised by this phone, so the UI can offer "I'm safe" only for
  /// alerts you actually raised.
  final Set<String> mySosIds = {};

  /// "I'm safe". Stops the SOS being re-offered across the mesh even though it
  /// has not expired. Only the original sender's cancel is honoured.
  Future<void> cancelSos(String sosIdHex) async {
    final n = node;
    if (n == null) return;
    await n.publish(EnvelopeType.sosCancel, encodePayload({'ref': sosIdHex}));
    _say('CANCELLED SOS (I am safe)');
    notifyListeners();
  }

  Future<void> publishReport({
    required ReportKind kind,
    required double lat,
    required double lon,
    String? note,
  }) async {
    final n = node;
    if (n == null) return;
    await n.publish(
      EnvelopeType.mapReport,
      encodePayload(
          MapReport.toJson(kind: kind, lat: lat, lon: lon, note: note)),
    );
    _say('reported ${kind.emoji} ${kind.english}');
    notifyListeners();
  }

  /// Confirms someone else's report. The reporter cannot confirm their own, and
  /// each fingerprint counts once, so confidence means "several people saw it"
  /// rather than "one person tapped a lot".
  Future<bool> confirmReport(MapReport report) async {
    final n = node;
    if (n == null) return false;
    if (report.reporter == fingerprint) return false;
    if (_confirmedByMe.contains(report.id)) return false;
    _confirmedByMe.add(report.id);
    await n.publish(
      EnvelopeType.reportConfirm,
      encodePayload({'report': report.id}),
    );
    // Count my own confirm locally too: the envelope I just published is
    // addressed to everyone else, and I should see the badge move immediately.
    await store?.markConfirm(report.id, fingerprint);
    _say('confirmed ${report.kind.english}');
    notifyListeners();
    return true;
  }

  final Set<String> _confirmedByMe = {};

  bool alreadyConfirmed(MapReport r) =>
      _confirmedByMe.contains(r.id) || r.reporter == fingerprint;

  /// Live reports with their confirm counts attached.
  Future<List<MapReport>> reports() async {
    final s = store;
    if (s == null) return const [];
    final out = <MapReport>[];
    for (final e in inbox) {
      final r = MapReport.fromEnvelope(e);
      if (r == null) continue;
      out.add(r.withConfirms(await s.confirmCount(r.id)));
    }
    return out;
  }

  /// Live SOS alerts worth showing: not mine, not cancelled by their sender.
  Future<List<Envelope>> activeSosAlerts() async {
    final s = store;
    if (s == null) return const [];
    final out = <Envelope>[];
    for (final e in inbox) {
      if (e.type != EnvelopeType.sos) continue;
      if (await s.isCancelledBy(e.idHex, e.senderFingerprint)) continue;
      out.add(e);
    }
    return out;
  }

  /// Queues 50 chat messages so the SOS visibly jumps the line on stage. With
  /// four phones and a handful of messages the queue drains in under a second
  /// and priority is otherwise impossible to observe.
  Future<void> floodChat() async {
    final n = node;
    if (n == null) return;
    for (var i = 0; i < 50; i++) {
      await n.publish(EnvelopeType.chat, encodePayload({'t': 'filler $i'}));
    }
    _say('queued 50 chat messages');
  }

  /// Demo presets. `chain` proves multi-hop is real; `mule-pairs` sets up two
  /// isolated groups for the carry. Reconfiguring four allowlists by hand
  /// mid-demo does not fit in a three minute run.
  void applyPreset(String name, List<String> fingerprints) {
    final t = transport;
    if (t == null) return;
    t.lock
      ..allow(fingerprints)
      ..enabled = true;
    _say('topology "$name": ${fingerprints.join(", ")}');
    notifyListeners();
  }

  void unlockTopology() {
    transport?.lock.clear();
    _say('topology lock OFF (ship state)');
    notifyListeners();
  }

  bool get locked => transport?.lock.enabled ?? false;

  String _label(Envelope e) {
    final t = e.type;
    if (t == EnvelopeType.sos) {
      final p = decodePayload(e.payload);
      return 'SOS ${p['kind']}';
    }
    if (t == EnvelopeType.chat) return 'chat "${decodePayload(e.payload)['t']}"';
    return t?.name ?? 'type ${e.typeWire}';
  }

  static String _short(Object p) => p.toString().split('.').last;
}
