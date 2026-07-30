// Generates the install QR code as an SVG poster.
//
//   dart run tools/make_qr.dart
//
// Points at the /releases/latest/download/ alias rather than a version-pinned
// URL, so cutting v1.0.1 the night before judging does not invalidate a poster
// that is already printed.
//
// SVG on purpose: it prints at any size without going fuzzy, which a PNG sized
// for a screen will not.

import 'dart:io';

import 'package:qr/qr.dart';

const repo = 'https://github.com/saikat1919/July_Hackathon_Jonaki';
const url = '$repo/releases/latest/download/Jonaki-PUBLIC-arm64.apk';

void main(List<String> args) {
  final target = args.isNotEmpty ? args.first : url;

  // Quartile correction (~25%): a printed poster picks up scuffs, glare and
  // creases, and the redundancy costs only a slightly denser code.
  final qr = QrCode(
    payload: QrPayload.fromString(target),
    errorCorrectLevel: QrErrorCorrectLevel.quartile,
  );
  final image = QrImage(qr);
  final n = qr.moduleCount;

  const module = 8.0; // svg units per QR module
  const quiet = 4; // required silent margin, in modules
  final size = (n + quiet * 2) * module;

  final b = StringBuffer()
    ..writeln('<svg xmlns="http://www.w3.org/2000/svg" '
        'width="${size.toStringAsFixed(0)}" '
        'height="${(size + 130).toStringAsFixed(0)}" '
        'viewBox="0 0 ${size.toStringAsFixed(0)} '
        '${(size + 130).toStringAsFixed(0)}">')
    ..writeln('<rect width="100%" height="100%" fill="#ffffff"/>');

  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      if (!image.isDark(y, x)) continue;
      final px = (x + quiet) * module;
      final py = (y + quiet) * module;
      b.writeln('<rect x="${px.toStringAsFixed(1)}" '
          'y="${py.toStringAsFixed(1)}" '
          'width="$module" height="$module" fill="#000000"/>');
    }
  }

  final cx = size / 2;
  b
    ..writeln('<text x="$cx" y="${size + 34}" text-anchor="middle" '
        'font-family="sans-serif" font-size="30" font-weight="bold">'
        'Jonaki · জোনাকি</text>')
    ..writeln('<text x="$cx" y="${size + 62}" text-anchor="middle" '
        'font-family="sans-serif" font-size="17">'
        'Scan to install. Android only.</text>')
    ..writeln('<text x="$cx" y="${size + 90}" text-anchor="middle" '
        'font-family="sans-serif" font-size="15">'
        '1. Allow install from unknown sources</text>')
    ..writeln('<text x="$cx" y="${size + 112}" text-anchor="middle" '
        'font-family="sans-serif" font-size="15">'
        '2. Grant every permission on first launch</text>')
    ..writeln('</svg>');

  final out = File('docs/install-qr.svg')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(b.toString());

  stdout
    ..writeln('URL:  $target')
    ..writeln('QR:   ${out.path}  (${n}x$n modules)')
    ..writeln('Open it in a browser and print, or screenshot for a slide.');
}
