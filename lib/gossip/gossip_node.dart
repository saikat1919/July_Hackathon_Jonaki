import 'dart:async';
import 'dart:typed_data';

import '../store/envelope_store.dart';
import '../transport/transport.dart';
import 'envelope.dart';
import 'identity.dart';

/// The whole product is this one loop. Chat, SOS, map reports, confirms and the
/// mule carry are all the same code path.
///
///   IDLE ──peer connected──► changed since last sync? ──no──► IDLE_LINKED
///                                     │yes
///                                     ▼
///                       HAVE(ids) ⇄ HAVE(ids)      both directions
///                                     │
///                                     ▼
///                       SEND: sos → report/confirm → chat
///                             ONE envelope = ONE payload
///                                     │
///                        disconnect ──┴──► COOLDOWN ──► IDLE
///
/// One envelope per payload is deliberate. Batching them into a single blob
/// makes priority invisible (there is no moment where the SOS arrives first)
/// and turns a mule that walks out of range mid-transfer into a total loss
/// rather than a partial delivery of whole messages.
class GossipNode {
  GossipNode({
    required this.identity,
    required this.store,
    required this.transport,
    TopologyLock? lock,
    this.syncCooldown = const Duration(seconds: 3),
    DateTime Function()? clock,
  })  : lock = lock ?? TopologyLock(),
        _clock = clock ?? DateTime.now;

  final Identity identity;
  final EnvelopeStore store;
  final Transport transport;
  final TopologyLock lock;
  final Duration syncCooldown;
  final DateTime Function() _clock;

  /// Fires for every envelope newly accepted by this node (UI listens here).
  final _accepted = StreamController<Envelope>.broadcast();
  Stream<Envelope> get accepted => _accepted.stream;

  /// Envelopes rejected for a bad signature. Never stored, never relayed.
  int rejectedSignatures = 0;

  /// Diagnostics for the debug screen: how many HAVE exchanges we have run.
  int syncCount = 0;

  final Map<String, DateTime> _lastSync = {};
  final Map<String, int> _lastSyncSize = {};
  StreamSubscription<InboundMessage>? _sub;
  StreamSubscription<PeerEvent>? _peers;

  static const int _msgHave = 0x10;
  static const int _msgEnvelope = 0x11;

  Future<void> start() async {
    await transport.start();
    _sub = transport.inbound.listen(_onBytes);
    _peers = transport.events.listen((e) {
      if (e.kind == PeerEventKind.connected) syncWith(e.peerId);
    });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    await _peers?.cancel();
    await _accepted.close();
  }

  /// Compose, store locally, and push to every live peer immediately.
  Future<Envelope> publish(EnvelopeType type, Uint8List payload) async {
    final e = await identity.compose(type: type, payload: payload, now: _clock());
    await _accept(e, local: true);
    for (final peer in transport.connectedPeers) {
      await _sendEnvelope(peer, e);
    }
    return e;
  }

  /// Exchange with one peer. Skips the whole thing when nothing has changed
  /// since the last successful sync: "sync on connect" plus "reconnect on
  /// disconnect" otherwise turn a flapping link into a storm that spends the
  /// radio on handshakes instead of messages.
  Future<void> syncWith(String peerId, {bool force = false}) async {
    final now = _clock();
    final last = _lastSync[peerId];
    final size = (await store.knownIds()).length;
    if (!force &&
        last != null &&
        now.difference(last) < syncCooldown &&
        _lastSyncSize[peerId] == size) {
      return;
    }
    _lastSync[peerId] = now;
    _lastSyncSize[peerId] = size;
    syncCount++;
    await transport.send(peerId, await _buildHave());
  }

  /// HAVE = raw 16-byte ids concatenated. No base64, no framing, no JSON.
  /// 2000 ids fit in Nearby's 32 KB BYTES cap; with 24h expiry on four phones
  /// you will have dozens. The cap is a known ceiling, not a thing to engineer
  /// around at this scale.
  Future<Uint8List> _buildHave() async {
    final ids = await store.knownIds();
    final b = BytesBuilder()..addByte(_msgHave);
    for (final id in ids) {
      b.add(id);
    }
    return b.toBytes();
  }

  Future<void> _onBytes(InboundMessage msg) async {
    if (msg.bytes.isEmpty) return;
    switch (msg.bytes[0]) {
      case _msgHave:
        await _onHave(msg.peerId, msg.bytes);
      case _msgEnvelope:
        await _onEnvelope(Uint8List.sublistView(msg.bytes, 1), msg.peerId);
    }
  }

  /// Send what the peer lacks, highest priority first, one payload each.
  Future<void> _onHave(String peerId, Uint8List frame) async {
    final theirs = <String>{};
    for (var o = 1; o + 16 <= frame.length; o += 16) {
      theirs.add(hexOf(Uint8List.sublistView(frame, o, o + 16)));
    }
    final mine = await store.offerable(now: _clock());
    final missing = mine.where((e) => !theirs.contains(e.idHex)).toList();
    if (missing.isEmpty) return;
    for (final e in missing) {
      await _sendEnvelope(peerId, e);
    }
  }

  /// Rewrites the mutable header on the way out: append this hop to the path,
  /// decrement ttl, and set `remaining` to the time actually left. Sending a
  /// fresh lifetime instead would restart the clock at every hop and nothing
  /// would ever expire.
  Future<void> _sendEnvelope(String peerId, Envelope e) async {
    final out = e.copy();
    out.path.add(Uint8List.fromList(
        identity.publicKey.sublist(0, fingerprintBytes)));
    out.ttl = out.ttl > 0 ? out.ttl - 1 : 0;
    out.remaining = await remainingFor(e);
    if (out.remaining <= Duration.zero) return; // expired: do not propagate
    final b = BytesBuilder()
      ..addByte(_msgEnvelope)
      ..add(out.encode());
    await transport.send(peerId, b.toBytes());
  }

  /// Time actually left, from this node's own expiry stamp. Forwarding this
  /// rather than the origin lifetime is what stops envelopes becoming immortal.
  Future<Duration> remainingFor(Envelope e) async {
    final expiry = await store.expiryOf(e.idHex);
    return expiry?.difference(_clock()) ?? e.remaining;
  }

  Future<void> _onEnvelope(Uint8List bytes, String from) async {
    final Envelope e;
    try {
      e = Envelope.decode(bytes);
    } on FormatException {
      return; // malformed frame, nothing to do
    }
    final ok = await Identity.verify(e.signingInput, e.signature, e.senderPubkey);
    if (!ok) {
      rejectedSignatures++;
      return; // invalid signature: dropped, never relayed
    }
    // Valid signature from a stranger still gets stored and relayed. Contacts
    // only supply a display name; requiring one would break the mesh.
    await _accept(e, local: false, from: from);
  }

  Future<void> _accept(Envelope e, {required bool local, String? from}) async {
    final fresh = await store.put(e, now: _clock());
    if (!fresh) return; // dedup by id: already seen, no re-store, no re-relay
    if (e.type == EnvelopeType.reportConfirm) {
      final p = decodePayload(e.payload);
      final reportId = p['report'] as String?;
      if (reportId != null) {
        await store.markConfirm(reportId, e.senderFingerprint);
      }
    }
    if (!_accepted.isClosed) _accepted.add(e);
    if (!local) {
      // Push onward immediately rather than waiting for the next HAVE, so an
      // SOS crosses a live chain in one pass instead of three sync rounds.
      // Skip the peer it came from: dedup would stop the echo anyway, but not
      // before it burned radio time we need for the links that matter.
      for (final peer in transport.connectedPeers.where((p) => p != from)) {
        await _sendEnvelope(peer, e);
      }
    }
  }

  Future<int> sweep() => store.sweepExpired(now: _clock());
}
