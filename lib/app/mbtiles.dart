import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Reads raster tiles straight out of an .mbtiles file.
///
/// Hand-rolled rather than pulled in: flutter_map_mbtiles pins an older
/// latlong2 than flutter_map 8.x needs, and MBTiles is a SQLite file with one
/// table worth caring about:
///
///   tiles(zoom_level, tile_column, tile_row, tile_data BLOB)
///
/// The only real subtlety is that MBTiles stores rows TMS-style (origin at the
/// bottom) while slippy-map tiles count from the top, so y has to be flipped.
class MbTilesSource {
  MbTilesSource._(this._db, this.minZoom, this.maxZoom);

  final Database _db;
  final int minZoom;
  final int maxZoom;

  /// SQLite cannot read out of the Flutter asset bundle, so the file is copied
  /// to app documents on first launch. Costs a few seconds and 2x storage once.
  static Future<MbTilesSource?> openBundled(String assetPath) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/${assetPath.split('/').last}');

      if (!await file.exists()) {
        final data = await rootBundle.load(assetPath);
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      return open(file.path);
    } catch (_) {
      return null; // no tiles bundled: the map still works, just bare
    }
  }

  static Future<MbTilesSource?> open(String path) async {
    try {
      if (!await File(path).exists()) return null;
      final db = await openDatabase(path, readOnly: true);

      var min = 0;
      var max = 19;
      final rows = await db.query('metadata');
      for (final r in rows) {
        final name = r['name'];
        final value = int.tryParse('${r['value']}');
        if (value == null) continue;
        if (name == 'minzoom') min = value;
        if (name == 'maxzoom') max = value;
      }
      return MbTilesSource._(db, min, max);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> tile(int z, int x, int y) async {
    // MBTiles rows are TMS: flip y.
    final flipped = (1 << z) - 1 - y;
    final rows = await _db.query(
      'tiles',
      columns: ['tile_data'],
      where: 'zoom_level = ? AND tile_column = ? AND tile_row = ?',
      whereArgs: [z, x, flipped],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['tile_data'] as Uint8List?;
  }

  Future<void> close() => _db.close();
}

class MbTilesProvider extends TileProvider {
  MbTilesProvider(this.source);

  final MbTilesSource source;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _MbTilesImage(source, coordinates);
}

class _MbTilesImage extends ImageProvider<_MbTilesImage> {
  _MbTilesImage(this.source, this.coords);

  final MbTilesSource source;
  final TileCoordinates coords;

  @override
  Future<_MbTilesImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _MbTilesImage key,
    ImageDecoderCallback decode,
  ) =>
      MultiFrameImageStreamCompleter(
        codec: _load(decode),
        scale: 1,
      );

  Future<Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await source.tile(coords.z, coords.x, coords.y);
    if (bytes == null || bytes.isEmpty) {
      // Missing tile: a transparent 1x1 keeps the map usable instead of
      // throwing a broken-image box over the pins.
      return decode(await ImmutableBuffer.fromUint8List(_transparentPixel));
    }
    return decode(await ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is _MbTilesImage &&
      other.coords == coords &&
      other.source == source;

  @override
  int get hashCode => Object.hash(source, coords);
}

/// Smallest valid PNG: 1x1 fully transparent.
final Uint8List _transparentPixel = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);
