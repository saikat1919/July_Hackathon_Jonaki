import '../gossip/envelope.dart';

/// What people actually need to tell each other when the network is down.
/// Fixed set, because a map covered in free-text notes is unreadable at a
/// glance and unreadable at a glance is useless in a crisis.
enum ReportKind {
  roadBlocked('road', '🚧', 'Road blocked', 'রাস্তা বন্ধ'),
  fire('fire', '🔥', 'Fire', 'আগুন'),
  medical('medical', '🚑', 'Medical camp', 'চিকিৎসা কেন্দ্র'),
  shelter('shelter', '🏠', 'Shelter', 'আশ্রয়'),
  food('food', '🍞', 'Food', 'খাবার'),
  water('water', '💧', 'Clean water', 'বিশুদ্ধ পানি'),
  charging('charging', '⚡', 'Charging point', 'চার্জিং'),
  danger('danger', '🚨', 'Danger zone', 'বিপদ');

  const ReportKind(this.wire, this.emoji, this.english, this.bangla);

  final String wire;
  final String emoji;
  final String english;
  final String bangla;

  static ReportKind fromWire(String? s) => ReportKind.values.firstWhere(
        (k) => k.wire == s,
        orElse: () => ReportKind.danger,
      );
}

class MapReport {
  MapReport({
    required this.id,
    required this.kind,
    required this.lat,
    required this.lon,
    required this.reporter,
    required this.at,
    this.note,
    this.confirms = 0,
  });

  final String id;
  final ReportKind kind;
  final double lat;
  final double lon;

  /// Fingerprint of whoever raised it. Kept so the reporter cannot confirm
  /// their own report and inflate its confidence.
  final String reporter;
  final DateTime at;
  final String? note;
  final int confirms;

  /// 1 = LOW, 2 = MEDIUM, 3+ = HIGH. Tuned so HIGH is reachable in a
  /// four-phone demo; the 5+ threshold it replaced never could be.
  String get confidence {
    if (confirms >= 3) return 'HIGH';
    if (confirms == 2) return 'MEDIUM';
    if (confirms == 1) return 'LOW';
    return 'UNCONFIRMED';
  }

  MapReport withConfirms(int n) => MapReport(
        id: id,
        kind: kind,
        lat: lat,
        lon: lon,
        reporter: reporter,
        at: at,
        note: note,
        confirms: n,
      );

  static Map<String, Object?> toJson({
    required ReportKind kind,
    required double lat,
    required double lon,
    String? note,
  }) =>
      {'kind': kind.wire, 'lat': lat, 'lon': lon, 'note': ?note};

  static MapReport? fromEnvelope(Envelope e) {
    if (e.type != EnvelopeType.mapReport) return null;
    final j = decodePayload(e.payload);
    final lat = (j['lat'] as num?)?.toDouble();
    final lon = (j['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    return MapReport(
      id: e.idHex,
      kind: ReportKind.fromWire(j['kind'] as String?),
      lat: lat,
      lon: lon,
      reporter: e.senderFingerprint,
      at: e.timestamp,
      note: j['note'] as String?,
    );
  }
}
