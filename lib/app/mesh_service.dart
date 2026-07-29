import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../gossip/envelope.dart';
import '../gossip/gossip_node.dart';
import '../gossip/identity.dart';
import '../store/envelope_store.dart';
import '../transport/nearby_transport.dart';
import '../transport/transport.dart';
import 'chat.dart';

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

    n.accepted.listen((e) {
      inbox.insert(0, e);
      _say('recv ${_label(e)} via ${e.path.length} hops');
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

  /// [to] is a peer fingerprint, or null to broadcast to everyone nearby.
  /// Addressing, not privacy: every relay can still read it until X25519 lands.
  Future<void> sendChat(String text, {String? to}) async {
    final n = node;
    if (n == null || text.trim().isEmpty) return;
    if (text.length > maxTextChars) {
      _say('message too long (${text.length}/$maxTextChars)');
      return;
    }
    await n.publish(
      EnvelopeType.chat,
      encodePayload({'t': text, 'to': ?to}),
    );
    _say(peers.isEmpty
        ? 'queued (no peers yet) "$text"'
        : 'sent to ${peers.length} peer(s) "$text"');
  }

  /// Everyone this phone has heard from, whether or not they are in range now.
  /// A peer who walked away still has a thread; the mesh will deliver later.
  Set<String> get knownFingerprints => {
        for (final e in inbox) e.senderFingerprint,
      }..remove(fingerprint);

  List<ChatMessage> messagesWith(String? peer) {
    final me = fingerprint;
    final out = <ChatMessage>[];
    for (final e in inbox) {
      final m = ChatMessage.fromEnvelope(e, me);
      if (m != null && m.inThreadWith(peer, me)) out.add(m);
    }
    out.sort((a, b) => a.sentAt.compareTo(b.sentAt));
    return out;
  }

  Future<void> sendSos(String kind, String note) async {
    final n = node;
    if (n == null) return;
    await n.publish(
      EnvelopeType.sos,
      encodePayload({'kind': kind, 'note': note}),
    );
    _say('SENT SOS ($kind)');
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
