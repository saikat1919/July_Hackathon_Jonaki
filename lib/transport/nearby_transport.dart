import 'dart:async';
import 'dart:typed_data';

import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

import 'transport.dart';

/// The only file in the project allowed to know Nearby Connections exists.
/// Everything above it talks to [Transport]. That boundary is what makes the
/// in-Dart 4-node simulation runnable and the gate-failure fallback ladder
/// (P2P_STAR hub → 3-phone/2-hop → hotspot+TCP) reachable at all.
///
///  IDLE ─advertise+discover─► FOUND ─┬─ blocked by lock ──► ignored (never
///                                    │                      requested, so it
///                                    │                      stops re-attempting)
///                                    └─ allowed ──► REQUESTING
///                                                      │
///                        collision: lower id backs off ─┤ (with a TIMEOUT, or
///                                                      │  the link deadlocks)
///                                                      ▼
///                                                  CONNECTED
///                                                      │
///                                         disconnect ──┴──► COOLDOWN ──► IDLE
class NearbyTransport implements Transport {
  NearbyTransport({
    required this.myFingerprint,
    required this.serviceId,
    TopologyLock? lock,
    this.reconnectCooldown = const Duration(seconds: 3),
    this.collisionTimeout = const Duration(seconds: 8),
  }) : lock = lock ?? TopologyLock();

  /// Advertised as the Nearby endpointName. The topology lock has nothing to
  /// match on otherwise — `endpointName` is the only string we control.
  final String myFingerprint;

  /// Demo builds MUST use a different serviceId from the distributed build.
  /// Judges install the APK during judging; with the lock off by default their
  /// phones would otherwise join the demo's radio cluster, and 3+ simultaneous
  /// advertisers is the top known Nearby failure mode.
  final String serviceId;

  final TopologyLock lock;
  final Duration reconnectCooldown;
  final Duration collisionTimeout;

  final _nearby = Nearby();
  final _inbound = StreamController<InboundMessage>.broadcast();
  final _events = StreamController<PeerEvent>.broadcast();
  final _connected = <String>{};
  final _pendingBackoff = <String, Timer>{};
  final _lastAttempt = <String, DateTime>{};

  /// endpointId -> the peer's advertised fingerprint.
  final _fingerprints = <String, String>{};

  @override
  Stream<InboundMessage> get inbound => _inbound.stream;

  @override
  Stream<PeerEvent> get events => _events.stream;

  @override
  Set<String> get connectedPeers => Set.unmodifiable(_connected);

  bool _starting = false;

  /// Start must be safe to call twice.
  ///
  /// Nearby throws STATUS_ALREADY_ADVERTISING (8001) if you advertise while
  /// already advertising, and the failure modes that get you there are exactly
  /// the ones a presenter hits: double-tapping the button, tapping again during
  /// the permission dialog, or advertising succeeding while discovery throws so
  /// the caller believes nothing started. So: reset the radios first, and treat
  /// "already doing it" as success rather than an error, because it is.
  @override
  Future<void> start() async {
    if (_starting) return;
    _starting = true;
    try {
      await _resetRadios();
      await _guard('advertising', () async {
        await _nearby.startAdvertising(
          myFingerprint,
          Strategy.P2P_CLUSTER,
          serviceId: serviceId,
          onConnectionInitiated: _onConnectionInitiated,
          onConnectionResult: _onConnectionResult,
          onDisconnected: _onDisconnected,
        );
      });
      await _guard('discovery', () async {
        await _nearby.startDiscovery(
          myFingerprint,
          Strategy.P2P_CLUSTER,
          serviceId: serviceId,
          onEndpointFound: _onEndpointFound,
          onEndpointLost: (id) {
            if (id != null) _drop(id);
          },
        );
      });
    } finally {
      _starting = false;
    }
  }

  /// Clears any advertising or discovery left over from a previous run, a hot
  /// restart, or a half-failed start.
  Future<void> _resetRadios() async {
    try {
      await _nearby.stopAdvertising();
    } catch (_) {/* was not advertising */}
    try {
      await _nearby.stopDiscovery();
    } catch (_) {/* was not discovering */}
  }

  /// Swallows only the "already running" statuses. Anything else is a genuine
  /// failure and must reach the user rather than being hidden.
  Future<void> _guard(String what, Future<void> Function() body) async {
    try {
      await body();
    } catch (err) {
      final text = err.toString();
      if (text.contains('ALREADY_ADVERTISING') ||
          text.contains('ALREADY_DISCOVERING') ||
          text.contains('8001') ||
          text.contains('8002')) {
        return; // already doing the thing we asked for
      }
      throw Exception('$what failed: $err');
    }
  }

  @override
  Future<void> stop() async {
    for (final t in _pendingBackoff.values) {
      t.cancel();
    }
    _pendingBackoff.clear();
    await _nearby.stopAdvertising();
    await _nearby.stopDiscovery();
    await _nearby.stopAllEndpoints();
    await _inbound.close();
    await _events.close();
  }

  @override
  Future<void> send(String peerId, Uint8List bytes) async {
    if (!_connected.contains(peerId)) return;
    // One envelope per payload, always. Batching makes SOS priority invisible
    // and turns a mule walking out of range into a total loss instead of a
    // partial delivery of whole messages.
    await _nearby.sendBytesPayload(peerId, bytes);
  }

  /// Filter at discovery, not only at accept: a blocked peer you keep
  /// requesting keeps re-attempting and eats radio from the links the demo
  /// actually needs.
  void _onEndpointFound(String id, String name, String service) {
    _fingerprints[id] = name;
    if (!lock.permits(name)) return;

    final last = _lastAttempt[id];
    if (last != null && DateTime.now().difference(last) < reconnectCooldown) {
      return; // cooldown: stops a flapping link becoming a handshake storm
    }
    _lastAttempt[id] = DateTime.now();

    // Symmetric requestConnection races are the #1 Nearby integration bug:
    // both sides request, both reject. Deterministic tiebreak — the
    // lexicographically lower endpointId yields and waits for the other.
    if (myFingerprint.compareTo(name) < 0) {
      _pendingBackoff[id]?.cancel();
      // ...but never wait forever. Asymmetric discovery is common, and without
      // this timeout the yielding side waits for a request that never comes and
      // the link is dead for the whole session.
      _pendingBackoff[id] = Timer(collisionTimeout, () {
        if (!_connected.contains(id)) _request(id);
      });
      return;
    }
    _request(id);
  }

  Future<void> _request(String id) async {
    try {
      await _nearby.requestConnection(
        myFingerprint,
        id,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (_) {
      // Rejected or already connecting. Discovery will surface it again.
    }
  }

  Future<void> _onConnectionInitiated(String id, ConnectionInfo info) async {
    _fingerprints[id] = info.endpointName;
    if (!lock.permits(info.endpointName)) {
      await _nearby.rejectConnection(id);
      return;
    }
    try {
      await _nearby.acceptConnection(
        id,
        onPayLoadRecieved: (endpointId, payload) {
          final bytes = payload.bytes;
          if (bytes != null && !_inbound.isClosed) {
            _inbound.add(InboundMessage(endpointId, bytes));
          }
        },
        onPayloadTransferUpdate: (_, _) {},
      );
    } catch (_) {
      // Peer vanished mid-handshake.
    }
  }

  void _onConnectionResult(String id, Status status) {
    _pendingBackoff.remove(id)?.cancel();
    if (status == Status.CONNECTED) {
      _connected.add(id);
      if (!_events.isClosed) {
        _events.add(PeerEvent(PeerEventKind.connected, id));
      }
    } else {
      _drop(id);
    }
  }

  void _onDisconnected(String id) => _drop(id);

  void _drop(String id) {
    _pendingBackoff.remove(id)?.cancel();
    if (_connected.remove(id) && !_events.isClosed) {
      _events.add(PeerEvent(PeerEventKind.disconnected, id));
    }
  }

  String? fingerprintOf(String endpointId) => _fingerprints[endpointId];

  /// Permissions Nearby needs on Android 12+/13+. The plugin does not request
  /// these; the app must. Miss any one and discovery fails silently, which on
  /// stage reads as "the mesh is broken" rather than "a checkbox is off".
  ///
  /// Location in particular is non-obvious: Nearby needs it even though the app
  /// never asks where you are, and without it connections thrash.
  static const List<Permission> required = [
    Permission.bluetoothScan, // Android 12+
    Permission.bluetoothAdvertise, // Android 12+
    Permission.bluetoothConnect, // Android 12+
    Permission.nearbyWifiDevices, // Android 13+
    Permission.locationWhenInUse, // Nearby requires it regardless
    Permission.notification, // Android 13+, for the foreground service
  ];

  /// Returns the permissions still missing after asking. Empty means ready.
  static Future<List<Permission>> ensurePermissions() async {
    final results = await required.request();
    return results.entries
        .where((e) => !e.value.isGranted)
        .map((e) => e.key)
        .toList();
  }

  /// Nearby also needs Location SERVICES on, not just the permission granted.
  static Future<bool> locationServicesEnabled() =>
      Permission.location.serviceStatus.isEnabled;
}
