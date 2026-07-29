import 'dart:async';
import 'dart:typed_data';

/// The seam. The gossip layer talks to exactly these two things and never
/// imports a single `nearby_connections` type.
///
/// This is load-bearing, not tidiness: it is what lets the 4-node convergence
/// simulation run with no phones, and it is the only reason the gate-failure
/// fallback ladder (P2P_STAR hub → 3-phone/2-hop → hotspot+TCP) is reachable
/// at all. Code the pipeline against Nearby types directly — the path of least
/// resistance on day 1 — and you silently lose both.
abstract class Transport {
  /// Peers currently connected and usable.
  Stream<PeerEvent> get events;

  Set<String> get connectedPeers;

  Future<void> send(String peerId, Uint8List bytes);

  Stream<InboundMessage> get inbound;

  Future<void> start();

  Future<void> stop();
}

class InboundMessage {
  InboundMessage(this.peerId, this.bytes);
  final String peerId;
  final Uint8List bytes;
}

enum PeerEventKind { connected, disconnected }

class PeerEvent {
  PeerEvent(this.kind, this.peerId);
  final PeerEventKind kind;
  final String peerId;
}

/// Forces a chain topology so multi-hop is real rather than narrated.
///
/// Four phones on one table are all in radio range, so P2P_CLUSTER will connect
/// A straight to D and the "20-run A→B→C→D relay test" would measure a direct
/// link with extra steps.
///
///   chain (beat 1)                  mule-pairs (beat 2)
///   A ── B ── C ── D                A ── B     C     D ── E
///   ▲            ▲                  └pair┘   mule   └pair┘
///   A cannot see D                  C carries between groups that never meet
///
/// OFF by default. A judge's phone is on nobody's allowlist, so a lock that
/// ships enabled produces an app that connects to nothing and looks broken.
class TopologyLock {
  TopologyLock();

  bool enabled = false;
  final Set<String> _allowed = {};

  Set<String> get allowed => Set.unmodifiable(_allowed);

  void allow(Iterable<String> fingerprints) {
    _allowed
      ..clear()
      ..addAll(fingerprints.map((f) => f.toUpperCase()));
  }

  /// Checked at discovery time, not only at accept time: a blocked peer you
  /// keep requesting keeps re-attempting and eats radio from the links the
  /// demo actually needs.
  bool permits(String peerFingerprint) =>
      !enabled || _allowed.contains(peerFingerprint.toUpperCase());

  void clear() {
    enabled = false;
    _allowed.clear();
  }
}

/// In-memory transport: the whole point of the seam. Drives the convergence
/// simulation with no radios, no plugins, no phones.
class MemoryTransport implements Transport {
  MemoryTransport(this.id, this._net);

  final String id;
  final MemoryNetwork _net;
  final _inbound = StreamController<InboundMessage>.broadcast();
  final _events = StreamController<PeerEvent>.broadcast();

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  @override
  Stream<PeerEvent> get events => _events.stream;

  @override
  Set<String> get connectedPeers => _net.peersOf(id);

  @override
  Future<void> send(String peerId, Uint8List bytes) async =>
      _net.deliver(from: id, to: peerId, bytes: bytes);

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    await _inbound.close();
    await _events.close();
  }

  void receive(String from, Uint8List bytes) {
    if (!_inbound.isClosed) _inbound.add(InboundMessage(from, bytes));
  }

  void notify(PeerEventKind kind, String peerId) {
    if (!_events.isClosed) _events.add(PeerEvent(kind, peerId));
  }
}

/// A wire the test controls: link and unlink nodes to model a chain, a
/// partition, or a mule walking between two isolated groups.
class MemoryNetwork {
  final Map<String, MemoryTransport> _nodes = {};
  final Map<String, Set<String>> _links = {};

  MemoryTransport register(String id) {
    final t = MemoryTransport(id, this);
    _nodes[id] = t;
    _links.putIfAbsent(id, () => <String>{});
    return t;
  }

  void link(String a, String b) {
    _links.putIfAbsent(a, () => <String>{}).add(b);
    _links.putIfAbsent(b, () => <String>{}).add(a);
    _nodes[a]?.notify(PeerEventKind.connected, b);
    _nodes[b]?.notify(PeerEventKind.connected, a);
  }

  void unlink(String a, String b) {
    _links[a]?.remove(b);
    _links[b]?.remove(a);
    _nodes[a]?.notify(PeerEventKind.disconnected, b);
    _nodes[b]?.notify(PeerEventKind.disconnected, a);
  }

  void unlinkAll(String a) {
    for (final b in {...?_links[a]}) {
      unlink(a, b);
    }
  }

  Set<String> peersOf(String id) => {...?_links[id]};

  void deliver({
    required String from,
    required String to,
    required Uint8List bytes,
  }) {
    if (!(_links[from]?.contains(to) ?? false)) return; // out of range: dropped
    _nodes[to]?.receive(from, bytes);
  }
}
