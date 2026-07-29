# Offline basemap

The map works without this file — pins drop, gossip, and get confirmed exactly
the same. You just see them on a blank background instead of over streets. This
document is how to put streets behind them.

## 1. Get an API key

Use a provider with a genuine free tier:

- **Stadia Maps** — free tier covers this comfortably, no card required
- **MapTiler** — free tier available
- **Thunderforest** — free tier available

**Do not point the fetcher at `tile.openstreetmap.org`.** Bulk downloading
violates the OSM tile usage policy, and you would find out via a rate-limit or
an IP ban partway through the download, with no basemap and no time left.

If you pick a provider other than Stadia, update `urlTemplate` at the top of
`tools/fetch_tiles.dart`.

## 2. Pick the district

The default bounding box is central Dhaka:

```
--bbox=90.33,23.70,90.50,23.90     # west,south,east,north
```

Choose the area your demo story is set in. Smaller is better: every extra
square kilometre is APK size, and APK size is what breaks the "judge installs
in under two minutes" criterion.

## 3. Set the key

The key is only used to BUILD the basemap. The finished tiles are bundled into
the APK, so the app never carries the key and neither does the repo.

Best option, keeps it out of your shell history:

```bash
echo "YOUR_KEY" > tools/.tile-key      # gitignored
```

Or an environment variable:

```bash
export TILE_API_KEY=YOUR_KEY
```

Or pass it directly (it will land in your shell history):

```bash
dart run tools/fetch_tiles.dart --key=YOUR_KEY
```

## 4. Fetch

```bash
dart run tools/fetch_tiles.dart
dart run tools/fetch_tiles.dart --bbox=90.33,23.70,90.50,23.90 --maxzoom=15
```

It prints the tile count and estimated size *before* downloading, so an
oversized area is a decision rather than a surprise. Target **30-50 MB**.
Above 60 MB, trim `--maxzoom` or tighten the bbox.

Zoom guidance: z12 is city-wide context, z16 is individual streets. z12-16 is
the useful range; z17+ multiplies size for detail nobody needs in this demo.

## 5. Register the asset

Add to `pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/tiles/district.mbtiles
```

Then rebuild. The map picks it up automatically on next launch and the
"no offline basemap" notice disappears.

First launch after installing copies the file out of the asset bundle into app
documents, because SQLite cannot read from inside the bundle. That costs a few
seconds once and roughly double the storage.

## 6. Attribution (not optional)

Whatever provider you use, their attribution plus
`© OpenStreetMap contributors` belongs on the map screen and in the README. You
are shipping their tiles inside a public-repo APK under an open-source tribute
framing; being asked about it by a judge is a realistic scenario, and having
the answer ready is better than improvising.

## Verifying without a phone

An `.mbtiles` file is just SQLite:

```bash
sqlite3 assets/tiles/district.mbtiles "SELECT COUNT(*) FROM tiles;"
sqlite3 assets/tiles/district.mbtiles "SELECT name, value FROM metadata;"
```

If the count is zero, every request failed — almost always a bad key or a
provider URL template that does not match what the fetcher builds.
