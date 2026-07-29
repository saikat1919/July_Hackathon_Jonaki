import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Every feature in this app is an Envelope wearing a different costume:
/// chat, SOS, map reports and confirms all ride the same store-and-forward
/// pipeline. Adding a feature means adding a payload type, not a subsystem.
///
///                   ┌──────────────────────────────────────┐
///    compose        │ SIGNED (immutable, fixed byte order) │  UNSIGNED header
///    ───────►       │ id ‖ type ‖ ts ‖ lifetime ‖ pk ‖ pl  │  ttl, remaining, path
///                   └──────────────────────────────────────┘  (rewritten per hop)
///                               │
///                               ▼
///                     store, expiresAt = receivedAt + remaining
///                               │
///              ┌────────────────┴────────────────┐
///              ▼                                 ▼
///        ttl > 0                            ttl == 0
///        offer in diff              ┌───────────┴───────────┐
///                                   ▼                       ▼
///                               non-SOS                    SOS
///                          keep + readable,        unexpired → STILL OFFER
///                          stop offering           expired   → delete
///
/// `lifetime` is signed and never changes. `remaining` is NOT signed: each hop
/// rewrites it to the time actually left, so the clock never restarts and an
/// envelope cannot become immortal by being forwarded.
enum EnvelopeType {
  chat(0, priority: 2, defaultLifetime: Duration(hours: 24)),
  sos(1, priority: 0, defaultLifetime: Duration(hours: 2)),
  sosCancel(2, priority: 0, defaultLifetime: Duration(hours: 2)),
  mapReport(3, priority: 1, defaultLifetime: Duration(hours: 24)),
  reportConfirm(4, priority: 1, defaultLifetime: Duration(hours: 24));

  const EnvelopeType(this.wire,
      {required this.priority, required this.defaultLifetime});

  /// Byte written to the wire. Never renumber these.
  final int wire;

  /// Lower sorts first in the diff exchange. SOS beats everything.
  final int priority;

  final Duration defaultLifetime;

  /// SOS keeps being offered past ttl 0 until it expires. Nothing else does.
  bool get outlivesTtl => this == EnvelopeType.sos || this == EnvelopeType.sosCancel;

  static EnvelopeType? fromWire(int b) {
    for (final t in EnvelopeType.values) {
      if (t.wire == b) return t;
    }
    return null; // unknown type: caller stores and relays it anyway
  }
}

const int defaultTtl = 8;
const int sosTtl = 16;
const int maxPayloadBytes = 4096;
const int maxTextChars = 1000;
const int fingerprintBytes = 4;

class Envelope {
  Envelope({
    required this.id,
    required this.typeWire,
    required this.timestamp,
    required this.lifetime,
    required this.senderPubkey,
    required this.payload,
    required this.signature,
    required this.ttl,
    required this.remaining,
    List<Uint8List>? path,
  }) : path = path ?? <Uint8List>[];

  // --- signed, immutable ---
  final Uint8List id; // 16 raw bytes, never a 36-char UUID string
  final int typeWire;
  final DateTime timestamp;
  final Duration lifetime;
  final Uint8List senderPubkey;
  final Uint8List payload;
  final Uint8List signature;

  // --- unsigned, rewritten as the envelope travels ---
  int ttl;
  Duration remaining;
  final List<Uint8List> path;

  EnvelopeType? get type => EnvelopeType.fromWire(typeWire);

  /// Unknown types are forward-compatible: stored and relayed, just not rendered.
  int get priority => type?.priority ?? 3;
  bool get outlivesTtl => type?.outlivesTtl ?? false;

  String get idHex => _hex(id);
  String get senderFingerprint => _hex(senderPubkey.sublist(0, fingerprintBytes));

  /// The exact bytes a signature covers. Fixed order, built by hand: no encoder
  /// gets to decide this, so there is no canonical-mode setting to trust and no
  /// cross-device serializer drift to discover on stage.
  static Uint8List signedBytes({
    required Uint8List id,
    required int typeWire,
    required DateTime timestamp,
    required Duration lifetime,
    required Uint8List senderPubkey,
    required Uint8List payload,
  }) {
    final b = BytesBuilder();
    b.add(id);
    b.addByte(typeWire);
    b.add(_u64le(timestamp.millisecondsSinceEpoch));
    b.add(_u32le(lifetime.inSeconds));
    b.add(senderPubkey);
    b.add(payload);
    return b.toBytes();
  }

  Uint8List get signingInput => signedBytes(
        id: id,
        typeWire: typeWire,
        timestamp: timestamp,
        lifetime: lifetime,
        senderPubkey: senderPubkey,
        payload: payload,
      );

  static Uint8List newId() {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(16, (_) => r.nextInt(256)));
  }

  /// Wire frame. Mutable fields sit outside the signed region, so a relay can
  /// append to `path` and rewrite `remaining`/`ttl` without breaking the signature.
  Uint8List encode() {
    final b = BytesBuilder();
    b.addByte(1); // frame version
    b.addByte(typeWire);
    b.add(id);
    b.add(_u64le(timestamp.millisecondsSinceEpoch));
    b.add(_u32le(lifetime.inSeconds));
    b.add(_u32le(remaining.inSeconds < 0 ? 0 : remaining.inSeconds));
    b.addByte(ttl.clamp(0, 255));
    b.addByte(senderPubkey.length);
    b.add(senderPubkey);
    b.addByte(signature.length);
    b.add(signature);
    b.addByte(path.length.clamp(0, 255));
    for (final hop in path.take(255)) {
      b.add(hop);
    }
    b.add(_u32le(payload.length));
    b.add(payload);
    return b.toBytes();
  }

  static Envelope decode(Uint8List bytes) {
    var o = 0;
    int u8() => bytes[o++];
    Uint8List take(int n) {
      if (o + n > bytes.length) {
        throw const FormatException('envelope truncated');
      }
      final s = Uint8List.sublistView(bytes, o, o + n);
      o += n;
      return Uint8List.fromList(s);
    }

    int u32() {
      final v = ByteData.sublistView(bytes, o, o + 4).getUint32(0, Endian.little);
      o += 4;
      return v;
    }

    int u64() {
      final v = ByteData.sublistView(bytes, o, o + 8).getUint64(0, Endian.little);
      o += 8;
      return v;
    }

    final version = u8();
    if (version != 1) throw FormatException('unknown frame version $version');
    final typeWire = u8();
    final id = take(16);
    final ts = DateTime.fromMillisecondsSinceEpoch(u64());
    final lifetime = Duration(seconds: u32());
    final remaining = Duration(seconds: u32());
    final ttl = u8();
    final pubkey = take(u8());
    final sig = take(u8());
    final hops = u8();
    final path = <Uint8List>[for (var i = 0; i < hops; i++) take(fingerprintBytes)];
    final payload = take(u32());

    return Envelope(
      id: id,
      typeWire: typeWire,
      timestamp: ts,
      lifetime: lifetime,
      senderPubkey: pubkey,
      payload: payload,
      signature: sig,
      ttl: ttl,
      remaining: remaining,
      path: path,
    );
  }

  Envelope copy() => Envelope(
        id: id,
        typeWire: typeWire,
        timestamp: timestamp,
        lifetime: lifetime,
        senderPubkey: senderPubkey,
        payload: payload,
        signature: signature,
        ttl: ttl,
        remaining: remaining,
        path: [...path],
      );
}

/// Payloads are JSON only for human-readable feature data. They are opaque to
/// the pipeline: signing covers the raw bytes, so encoding never affects trust.
Uint8List encodePayload(Map<String, Object?> json) {
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
  if (bytes.length > maxPayloadBytes) {
    throw ArgumentError('payload ${bytes.length}B exceeds $maxPayloadBytes');
  }
  return bytes;
}

Map<String, Object?> decodePayload(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;

Uint8List _u32le(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
Uint8List _u64le(int v) => Uint8List(8)..buffer.asByteData().setUint64(0, v, Endian.little);

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
