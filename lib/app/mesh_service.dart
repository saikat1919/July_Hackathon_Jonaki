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
import '../store/sqflite_store.dart';
import 'chat.dart';
import 'contacts.dart';
import 'identity_store.dart';
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
  EnvelopeStore? store;
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

  /// Restores identity and history before the mesh starts. Both survive a
  /// restart: the identity from secure storage, everything else from SQLite.
  Future<void> bootIdentity() async {
    identity = await IdentityStore.loadOrCreate();
    _say('identity ${identity!.fingerprint}');

    try {
      final db = await SqfliteEnvelopeStore.open();
      store = db;
      // Drop anything that expired while the app was closed, then restore what
      // is left so a restart does not look like a factory reset.
      final swept = await db.sweepExpired();
      final restored = await db.all();
      inbox
        ..clear()
        ..addAll(restored);
      _say('restored ${restored.length} message'
          '${restored.length == 1 ? '' : 's'}'
          '${swept > 0 ? ' ($swept expired)' : ''}');
    } catch (err) {
      // Storage is a nice-to-have, not a prerequisite for communicating.
      _say('storage unavailable, running in memory only: $err');
      store ??= MemoryEnvelopeStore();
    }
    notifyListeners();
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

    identity ??= await IdentityStore.loadOrCreate();
    // Reuse the store opened at boot so restored history is not thrown away
    // the moment the mesh starts.
    final s = store ??= MemoryEnvelopeStore();
    final t = NearbyTransport(
      myFingerprint: identity!.fingerprint,
      serviceId: serviceId,
    );
    final n = GossipNode(identity: identity!, store: s, transport: t);

    n.accepted.listen((e) async {
      // Announces are plumbing, not messages: they teach keys and names and
      // then get out of the way. Keeping them out of the inbox stops them
      // cluttering threads and peer lists.
      if (e.type != EnvelopeType.announce) inbox.insert(0, e);
      // Learn keys from ordinary traffic. Hearing one global message from
      // someone is enough to message them privately afterwards.
      final trusted = await keys.learnFrom(e);
      if (!trusted) {
        _say('KEY CONFLICT from ${e.senderFingerprint} — not trusted');
      }
      _learnName(e);
      if (e.type == EnvelopeType.announce) {
        _say('met ${nameOf(e.senderFingerprint)}');
      } else {
        _say('recv ${_label(e)} via ${e.path.length} hops');
      }
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
      // Introduce ourselves the moment someone appears. This is what stops key
      // exchange being a chore the user has to understand: by the time they
      // open a personal thread, the key is already there.
      if (e.kind == PeerEventKind.connected) _announce();
      notifyListeners();
    });

    try {
      await n.start();
      // Screen-on is the demo posture: Android throttles radios for locked
      // devices, so the mule carry fails silently in a pocket.
      await WakelockPlus.enable();
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

  /// Your own display name, broadcast so peers see a name instead of hex.
  String myName = '';

  /// Set by the app so announced names can reach the contact book.
  Contacts? contacts;

  String nameOf(String fingerprint) =>
      contacts?.nameFor(fingerprint) ?? fingerprint;

  void _learnName(Envelope e) {
    final c = contacts;
    if (c == null) return;
    try {
      final name = decodePayload(e.payload)['name'];
      if (name is String) c.learnAnnouncedName(e.senderFingerprint, name);
    } catch (_) {
      // Payload is not JSON or has no name. Nothing to learn, nothing broken.
    }
  }

  /// Publishes our key and name. Cheap, short-lived, never rendered.
  Future<void> _announce() async {
    final n = node;
    final me = identity;
    if (n == null || me == null) return;
    await n.publish(
      EnvelopeType.announce,
      encodePayload({
        'ek': base64Encode(me.encPublicKey),
        'name': ?(myName.trim().isEmpty ? null : myName.trim()),
      }),
      ttl: announceTtl,
    );
  }

  /// Called after the user sets or changes their name.
  Future<void> setMyName(String name) async {
    myName = name.trim();
    await _announce();
    notifyListeners();
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
  /// Everyone worth offering a personal thread with.
  ///
  /// Three sources, because any one alone leaves the feature looking broken:
  /// peers connected right now (so a thread appears the moment someone is in
  /// range, before they have said anything), everyone who has ever messaged
  /// us, and every key we have pinned (so threads survive a restart).
  Set<String> get knownFingerprints {
    final out = <String>{};
    final t = transport;
    if (t != null) {
      for (final peerId in t.connectedPeers) {
        final fp = t.fingerprintOf(peerId);
        if (fp != null) out.add(fp.toUpperCase());
      }
    }
    for (final e in inbox) {
      out.add(e.senderFingerprint.toUpperCase());
    }
    for (final k in keys.all) {
      out.add(k.fingerprint.toUpperCase());
    }
    return out..remove(fingerprint.toUpperCase());
  }

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
