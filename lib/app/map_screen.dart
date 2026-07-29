import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'contacts.dart';
import 'mbtiles.dart';
import 'mesh_service.dart';
import 'report.dart';

/// Path of the bundled basemap, if one has been added to assets. Absent during
/// early development; the map works without it, just without imagery.
const String kTilesAsset = 'assets/tiles/district.mbtiles';

/// Dhaka. Only used as an opening view when there is nothing else to centre on.
const LatLng kFallbackCentre = LatLng(23.8103, 90.4125);

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.mesh, required this.contacts});

  final MeshService mesh;
  final Contacts contacts;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  MbTilesSource? _tiles;
  bool _tilesChecked = false;
  List<MapReport> _reports = const [];

  @override
  void initState() {
    super.initState();
    _loadTiles();
    _refreshReports();
    widget.mesh.addListener(_refreshReports);
  }

  @override
  void dispose() {
    widget.mesh.removeListener(_refreshReports);
    _tiles?.close();
    super.dispose();
  }

  Future<void> _loadTiles() async {
    final t = await MbTilesSource.openBundled(kTilesAsset);
    if (mounted) {
      setState(() {
        _tiles = t;
        _tilesChecked = true;
      });
    }
  }

  Future<void> _refreshReports() async {
    final r = await widget.mesh.reports();
    if (mounted) setState(() => _reports = r);
  }

  @override
  Widget build(BuildContext context) {
    final tiles = _tiles;
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: _reports.isEmpty
                ? kFallbackCentre
                : LatLng(_reports.first.lat, _reports.first.lon),
            initialZoom: 14,
            minZoom: tiles?.minZoom.toDouble() ?? 3,
            maxZoom: tiles?.maxZoom.toDouble() ?? 18,
            onLongPress: (_, point) => _addReport(point),
          ),
          children: [
            if (tiles != null)
              // urlTemplate stays null on purpose. This app claims to work
              // during an internet shutdown, and a silent online fallback would
              // make that claim false in exactly the demo that matters.
              TileLayer(tileProvider: MbTilesProvider(tiles)),
            MarkerLayer(
              markers: [
                for (final r in _reports)
                  Marker(
                    point: LatLng(r.lat, r.lon),
                    width: 44,
                    height: 44,
                    child: GestureDetector(
                      onTap: () => _openReport(r),
                      child: _Pin(report: r),
                    ),
                  ),
              ],
            ),
          ],
        ),
        if (_tilesChecked && tiles == null) const _NoBasemapNotice(),
        Positioned(
          left: 12,
          bottom: 12,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text('${_reports.length} report'
                  '${_reports.length == 1 ? '' : 's'} · long-press to add'),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _addReport(LatLng at) async {
    final kind = await showModalBottomSheet<ReportKind>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('What is here?', style: TextStyle(fontSize: 18)),
            ),
            for (final k in ReportKind.values)
              ListTile(
                leading: Text(k.emoji, style: const TextStyle(fontSize: 24)),
                title: Text(k.english),
                subtitle: Text(k.bangla),
                onTap: () => Navigator.pop(context, k),
              ),
          ],
        ),
      ),
    );
    if (kind == null) return;
    await widget.mesh
        .publishReport(kind: kind, lat: at.latitude, lon: at.longitude);
    await _refreshReports();
  }

  Future<void> _openReport(MapReport r) async {
    final canConfirm = !widget.mesh.alreadyConfirmed(r);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(r.kind.emoji, style: const TextStyle(fontSize: 32)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.kind.english,
                            style: const TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold)),
                        Text(r.kind.bangla),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('Reported by ${widget.contacts.nameFor(r.reporter)}'),
              Text(
                r.confirms == 0
                    ? 'No one else has confirmed this yet'
                    : 'Confirmed by ${r.confirms} '
                        'other${r.confirms == 1 ? '' : 's'} nearby',
              ),
              const SizedBox(height: 4),
              Chip(label: Text('Confidence: ${r.confidence}')),
              if (r.note != null && r.note!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(r.note!),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: canConfirm
                    ? () async {
                        await widget.mesh.confirmReport(r);
                        if (ctx.mounted) Navigator.pop(ctx);
                        await _refreshReports();
                      }
                    : null,
                icon: const Icon(Icons.check),
                label: Text(
                  r.reporter == widget.mesh.fingerprint
                      // Self-confirming would let one phone manufacture
                      // confidence, which is the whole thing the count exists
                      // to prevent.
                      ? 'You reported this'
                      : canConfirm
                          ? "I can see this too"
                          : 'You already confirmed',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({required this.report});

  final MapReport report;

  @override
  Widget build(BuildContext context) {
    // Confidence is legible at a glance from the ring, so a scanning eye can
    // tell a single unverified sighting from something several people saw.
    final ring = switch (report.confidence) {
      'HIGH' => Colors.greenAccent,
      'MEDIUM' => Colors.amberAccent,
      'LOW' => Colors.orangeAccent,
      _ => Colors.white24,
    };
    return Container(
      decoration: BoxDecoration(
        color: Colors.black87,
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: 3),
      ),
      alignment: Alignment.center,
      child: Text(report.kind.emoji, style: const TextStyle(fontSize: 20)),
    );
  }
}

class _NoBasemapNotice extends StatelessWidget {
  const _NoBasemapNotice();

  @override
  Widget build(BuildContext context) => Positioned(
        top: 12,
        left: 12,
        right: 12,
        child: Card(
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'No offline basemap bundled yet. Pins, sharing and confirmation '
              'all work; there is just no imagery behind them. Add '
              'assets/tiles/district.mbtiles to fix.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
      );
}
