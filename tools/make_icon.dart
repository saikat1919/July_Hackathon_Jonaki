// Turns the Jonaki logo into app icon sources.
//
//   dart run tools/make_icon.dart <path-to-logo.png>
//
// The logo is a landscape image: a circular emblem with the wordmark beneath.
// An app icon is square and gets masked to a circle or squircle by the
// launcher, so the wordmark has to go — it would be cropped to unreadable
// fragments — and the emblem has to be centred in a square.
//
// Produces two files:
//   assets/icon/icon.png        emblem filling the square (legacy icons)
//   assets/icon/foreground.png  emblem at 60% on transparent (adaptive icons)
//
// Adaptive icons are masked AND parallax-shifted, so anything outside the
// centre ~66% can be clipped. The foreground is scaled down accordingly;
// skipping that is why so many Android icons look cropped.

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart';

const out = 1024;

void main(List<String> args) {
  final path = args.isEmpty
      ? r'C:\Users\Saikat\Downloads\Gemini_Generated_Image_hzh2p3hzh2p3hzh2.png'
      : args.first;

  final src = decodeImage(File(path).readAsBytesSync());
  if (src == null) {
    stderr.writeln('Could not read $path');
    exit(2);
  }
  stdout.writeln('source: ${src.width}x${src.height}');

  // The emblem sits centred horizontally, in the upper portion above the
  // wordmark. Find it by brightness: the glowing circle is far lighter than
  // the dark navy background, so its bounding box is measurable rather than
  // guessed at with magic numbers.
  final box = _brightBounds(src);
  stdout.writeln('emblem bounds: $box');

  // Square it around the emblem's centre, with a little breathing room.
  final cx = (box.left + box.right) ~/ 2;
  final cy = (box.top + box.bottom) ~/ 2;
  final int side = ((math.max(box.right - box.left, box.bottom - box.top) *
              1.06)
          .round())
      .clamp(16, math.min(src.width, src.height))
      .toInt();

  final crop = copyCrop(
    src,
    x: (cx - side ~/ 2).clamp(0, src.width - side).toInt(),
    y: (cy - side ~/ 2).clamp(0, src.height - side).toInt(),
    width: side,
    height: side,
  );

  final full = copyResize(crop, width: out, height: out,
      interpolation: Interpolation.cubic);
  File('assets/icon/icon.png').writeAsBytesSync(encodePng(full));

  // Adaptive foreground: same emblem at 60% on a transparent canvas, so the
  // launcher's mask and parallax never bite into it.
  final inner = (out * 0.60).round();
  final small = copyResize(crop, width: inner, height: inner,
      interpolation: Interpolation.cubic);
  final fg = Image(width: out, height: out, numChannels: 4);
  fill(fg, color: ColorRgba8(0, 0, 0, 0));
  compositeImage(fg, small,
      dstX: (out - inner) ~/ 2, dstY: (out - inner) ~/ 2);
  File('assets/icon/foreground.png').writeAsBytesSync(encodePng(fg));

  // Background colour for the adaptive icon, sampled from a corner of the
  // original so it matches the artwork rather than being eyeballed.
  final c = src.getPixel(8, 8);
  final hex = '#${_hex(c.r.toInt())}${_hex(c.g.toInt())}${_hex(c.b.toInt())}';

  stdout
    ..writeln('wrote assets/icon/icon.png        (${out}x$out)')
    ..writeln('wrote assets/icon/foreground.png  (emblem at 60%)')
    ..writeln('background colour sampled: $hex');
}

String _hex(int v) => v.toRadixString(16).padLeft(2, '0');

/// Bounding box of pixels clearly brighter than the background.
_Box _brightBounds(Image im) {
  var minX = im.width, minY = im.height, maxX = 0, maxY = 0;
  // Only scan the top 70%: the wordmark below is bright white and would drag
  // the box down over the text we are trying to exclude.
  final limit = (im.height * 0.70).round();
  for (var y = 0; y < limit; y++) {
    for (var x = 0; x < im.width; x++) {
      final p = im.getPixel(x, y);
      final lum = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b);
      if (lum < 110) continue; // background navy is far below this
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
  }
  return _Box(minX, minY, maxX, maxY);
}

class _Box {
  const _Box(this.left, this.top, this.right, this.bottom);
  final int left, top, right, bottom;
  @override
  String toString() => '($left,$top)-($right,$bottom)';
}
