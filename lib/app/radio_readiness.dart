import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../transport/nearby_transport.dart';

/// Everything that has to be true before the mesh can find anyone.
///
/// These fail independently and each one produces the same useless symptom —
/// zero peers — so the app has to name which is missing. "It doesn't work" is
/// what a user reports; "your Bluetooth is off" is what they can act on.
enum Blocker {
  permissions('Permissions needed',
      'Bluetooth, nearby devices and location. The app cannot find other '
          'phones without them.'),
  bluetooth('Bluetooth is off',
      'Phones talk to each other over Bluetooth. Nothing works until it is on.'),
  location('Location is off',
      'Android requires location to be on before it will let apps discover '
          'nearby devices. Your location is never sent anywhere.');

  const Blocker(this.title, this.detail);
  final String title;
  final String detail;
}

class RadioReadiness {
  static const _channel = MethodChannel('crisis_mesh/radio');

  /// Returns the blockers in the order they should be fixed. Empty means ready.
  static Future<List<Blocker>> check() async {
    final out = <Blocker>[];

    final missing = await NearbyTransport.ensurePermissions();
    if (missing.isNotEmpty) out.add(Blocker.permissions);

    if (!await isBluetoothOn()) out.add(Blocker.bluetooth);

    // The permission being granted is NOT the same as the service being on,
    // and Nearby thrashes silently when the service is off.
    if (!await Geolocator.isLocationServiceEnabled()) out.add(Blocker.location);

    return out;
  }

  static Future<bool> isBluetoothOn() async {
    try {
      return await _channel.invokeMethod<bool>('isBluetoothOn') ?? false;
    } on PlatformException {
      // Channel missing (e.g. a test host). Assume on and let the transport
      // report the real error rather than blocking startup on a guess.
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  /// Asks Android to turn Bluetooth on via the system dialog, so the user
  /// never has to leave the app.
  static Future<void> requestBluetooth() async {
    try {
      await _channel.invokeMethod<bool>('requestBluetoothOn');
    } catch (_) {
      // Fall back to nothing: the readiness card stays up and the user can
      // use the notification shade toggle.
    }
  }

  /// No system dialog exists for location services, so this opens Settings.
  static Future<void> openLocationSettings() async {
    try {
      await Geolocator.openLocationSettings();
    } catch (_) {}
  }

  static Future<void> requestPermissions() =>
      NearbyTransport.ensurePermissions();
}
