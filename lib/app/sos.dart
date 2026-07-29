import 'package:battery_plus/battery_plus.dart';
import 'package:geolocator/geolocator.dart';

/// What kind of help is needed. Fixed set: a free-text emergency is useless to
/// someone scanning a list of alerts, and these five cover what July 2024 and
/// the flood seasons actually produce.
enum SosKind {
  medical('medical', '🚑', 'Medical', 'চিকিৎসা'),
  violence('violence', '⚠️', 'Violence', 'সহিংসতা'),
  fire('fire', '🔥', 'Fire', 'আগুন'),
  flood('flood', '💧', 'Flood', 'বন্যা'),
  missing('missing', '🔎', 'Missing person', 'নিখোঁজ');

  const SosKind(this.wire, this.emoji, this.english, this.bangla);

  final String wire;
  final String emoji;
  final String english;
  final String bangla;

  static SosKind fromWire(String? s) => SosKind.values.firstWhere(
        (k) => k.wire == s,
        orElse: () => SosKind.medical,
      );
}

/// Where a coordinate came from. Shown on the alert, never hidden: a rescuer
/// deciding whether to walk 2 km needs to know if the fix is live or an hour old.
enum FixSource {
  gps('gps'),
  cached('cached'),
  manual('manual'),
  none('none');

  const FixSource(this.wire);
  final String wire;

  static FixSource fromWire(String? s) => FixSource.values.firstWhere(
        (f) => f.wire == s,
        orElse: () => FixSource.none,
      );
}

class SosPayload {
  SosPayload({
    required this.kind,
    this.note,
    this.lat,
    this.lon,
    this.fix = FixSource.none,
    this.fixAge,
    this.battery,
  });

  final SosKind kind;
  final String? note;
  final double? lat;
  final double? lon;
  final FixSource fix;

  /// How old the cached fix was when sent.
  final Duration? fixAge;
  final int? battery;

  bool get hasLocation => lat != null && lon != null;

  Map<String, Object?> toJson() => {
        'kind': kind.wire,
        'note': ?note,
        'lat': ?lat,
        'lon': ?lon,
        'loc': fix.wire,
        'locAge': ?fixAge?.inSeconds,
        'batt': ?battery,
      };

  static SosPayload fromJson(Map<String, Object?> j) => SosPayload(
        kind: SosKind.fromWire(j['kind'] as String?),
        note: j['note'] as String?,
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
        fix: FixSource.fromWire(j['loc'] as String?),
        fixAge: j['locAge'] == null
            ? null
            : Duration(seconds: (j['locAge'] as num).toInt()),
        battery: (j['batt'] as num?)?.toInt(),
      );

  /// Human sentence for the alert screen. Never returns an empty string —
  /// "no location" is information, not a blank.
  String get locationLabel {
    if (!hasLocation) return 'no location';
    final coords =
        '${lat!.toStringAsFixed(5)}, ${lon!.toStringAsFixed(5)}';
    return switch (fix) {
      FixSource.gps => '$coords · live GPS',
      FixSource.cached => '$coords · last known'
          '${fixAge == null ? '' : ' ${_ago(fixAge!)}'}',
      FixSource.manual => '$coords · placed by hand',
      FixSource.none => coords,
    };
  }

  static String _ago(Duration d) {
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    return '${d.inHours}h ago';
  }
}

/// Resolves a position without ever blocking the SOS.
///
/// A cold GNSS fix indoors takes minutes or never arrives, and the demo runs
/// inside a venue in airplane mode. So: prefer a recent cached fix, try a live
/// one only briefly, and otherwise send with no coordinates rather than making
/// someone in trouble wait on a satellite.
///
///   last known (< 30 min)  ──► send immediately
///          │ none/stale
///          ▼
///   live fix, 5s timeout   ──► send
///          │ timed out
///          ▼
///   no location            ──► send anyway, labelled honestly
class LocationResolver {
  static const maxCacheAge = Duration(minutes: 30);
  static const liveTimeout = Duration(seconds: 5);

  Future<({double? lat, double? lon, FixSource fix, Duration? age})>
      resolve() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return (lat: null, lon: null, fix: FixSource.none, age: null);
      }

      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        final age = DateTime.now().difference(last.timestamp);
        if (age <= maxCacheAge) {
          return (
            lat: last.latitude,
            lon: last.longitude,
            fix: FixSource.cached,
            age: age
          );
        }
      }

      final live = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: liveTimeout,
        ),
      );
      return (
        lat: live.latitude,
        lon: live.longitude,
        fix: FixSource.gps,
        age: null
      );
    } catch (_) {
      // Timed out, permission gone, or no hardware. An SOS with no coordinates
      // still beats no SOS at all.
      return (lat: null, lon: null, fix: FixSource.none, age: null);
    }
  }
}

Future<int?> readBatteryLevel() async {
  try {
    return await Battery().batteryLevel;
  } catch (_) {
    return null;
  }
}
