// Builds the offline basemap: downloads raster tiles for a bounding box and
// writes them into assets/tiles/district.mbtiles.
//
//   dart run tools/fetch_tiles.dart --key=YOUR_KEY
//   dart run tools/fetch_tiles.dart --key=YOUR_KEY --bbox=90.33,23.70,90.50,23.90
//
// Use a provider with a real free tier (Stadia, Thunderforest, MapTiler).
// Do NOT point this at tile.openstreetmap.org: bulk downloading violates their
// tile usage policy and earns a rate-limit or IP ban partway through, which you
// would discover with no basemap and no time.
//
// Attribution is not optional. Whatever provider you use, their notice plus
// "© OpenStreetMap contributors" belongs on the map screen and in the README.

import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

/// Dhaka core. Roughly 18 km across, which at z12-16 lands in the tens of MB.
const defaultBbox = '90.33,23.70,90.50,23.90';
const defaultMinZoom = 12;
const defaultMaxZoom = 16;

/// {z}/{x}/{y} plus the provider's key parameter.
const urlTemplate =
    'https://tiles.stadiamaps.com/tiles/alidade_smooth_dark/{z}/{x}/{y}.png?api_key={key}';

Future<void> main(List<String> args) async {
  final opts = <String, String>{};
  for (final a in args) {
    final m = RegExp(r'^--([^=]+)=(.*)$').firstMatch(a);
    if (m != null) opts[m.group(1)!] = m.group(2)!;
  }

  final key = opts['key'];
  if (key == null || key.isEmpty) {
    stderr.writeln('Missing --key=YOUR_PROVIDER_API_KEY');
    stderr.writeln('Sign up for a free tier first; see docs/TILES.md.');
    exit(2);
  }

  final bbox = (opts['bbox'] ?? defaultBbox).split(',').map(double.parse).toList();
  final minZoom = int.parse(opts['minzoom'] ?? '$defaultMinZoom');
  final maxZoom = int.parse(opts['maxzoom'] ?? '$defaultMaxZoom');
  final out = opts['out'] ?? 'assets/tiles/district.mbtiles';

  final (west, south, east, north) = (bbox[0], bbox[1], bbox[2], bbox[3]);

  // Count first so the size is a decision, not a surprise. A 150 MB APK breaks
  // the "judge installs in under two minutes" criterion.
  var planned = 0;
  for (var z = minZoom; z <= maxZoom; z++) {
    final (x0, y0) = _tileOf(west, north, z);
    final (x1, y1) = _tileOf(east, south, z);
    planned += (x1 - x0 + 1) * (y1 - y0 + 1);
  }
  stdout.writeln('Planning $planned tiles for z$minZoom-$maxZoom.');
  stdout.writeln('At roughly 15 KB each that is about '
      '${(planned * 15 / 1024).round()} MB. Aim for 30-50 MB total.');
  if (planned > 8000) {
    stdout.writeln('That is a lot. Consider a tighter --bbox or a lower '
        '--maxzoom before continuing.');
  }

  await Directory(File(out).parent.path).create(recursive: true);
  final f = File(out);
  if (await f.exists()) await f.delete();

  final db = sqlite3.open(out);
  db
    ..execute('CREATE TABLE metadata (name TEXT, value TEXT)')
    ..execute('CREATE TABLE tiles ('
        'zoom_level INTEGER, tile_column INTEGER, '
        'tile_row INTEGER, tile_data BLOB)')
    ..execute('CREATE UNIQUE INDEX tile_index ON tiles '
        '(zoom_level, tile_column, tile_row)');

  for (final e in {
    'name': 'Crisis Mesh district',
    'format': 'png',
    'type': 'baselayer',
    'version': '1',
    'minzoom': '$minZoom',
    'maxzoom': '$maxZoom',
    'bounds': '$west,$south,$east,$north',
    'attribution': '© OpenStreetMap contributors',
  }.entries) {
    db.execute('INSERT INTO metadata (name, value) VALUES (?, ?)',
        [e.key, e.value]);
  }

  final client = http.Client();
  final insert = db.prepare('INSERT OR REPLACE INTO tiles '
      '(zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?)');

  var done = 0;
  var failed = 0;
  for (var z = minZoom; z <= maxZoom; z++) {
    final (x0, y0) = _tileOf(west, north, z);
    final (x1, y1) = _tileOf(east, south, z);
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        final url = urlTemplate
            .replaceAll('{z}', '$z')
            .replaceAll('{x}', '$x')
            .replaceAll('{y}', '$y')
            .replaceAll('{key}', key);
        try {
          final res = await client.get(Uri.parse(url));
          if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
            // MBTiles stores rows TMS-style, so y is flipped on the way in.
            insert.execute([z, x, (1 << z) - 1 - y, res.bodyBytes]);
            done++;
          } else {
            failed++;
            if (res.statusCode == 429) {
              stdout.writeln('\nRate limited. Pausing 10s.');
              await Future<void>.delayed(const Duration(seconds: 10));
            }
          }
        } catch (_) {
          failed++;
        }
        if ((done + failed) % 50 == 0) {
          stdout.write('\r${done + failed}/$planned  (ok $done, failed $failed)');
        }
        // Be a decent citizen even on a paid tier.
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
  }

  insert.close();
  db.close();
  client.close();

  final mb = (await f.length()) / 1024 / 1024;
  stdout.writeln('\nWrote $out — $done tiles, ${mb.toStringAsFixed(1)} MB '
      '($failed failed).');
  if (mb > 60) {
    stdout.writeln('Over 60 MB. Trim --maxzoom or the bbox: APK size is a '
        'demo-day risk, not a detail.');
  }
  stdout.writeln('Now add this to pubspec.yaml under flutter: assets:');
  stdout.writeln('    - assets/tiles/district.mbtiles');
}

/// Slippy-map tile containing a coordinate at a given zoom.
(int, int) _tileOf(double lon, double lat, int z) {
  final n = 1 << z;
  final x = ((lon + 180) / 360 * n).floor();
  final latRad = lat * math.pi / 180;
  final y = ((1 -
              math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
          2 *
          n)
      .floor();
  return (x.clamp(0, n - 1), y.clamp(0, n - 1));
}
