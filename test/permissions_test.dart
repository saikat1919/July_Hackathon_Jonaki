import 'package:crisis_mesh/transport/nearby_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

/// Regression guard for a real bug: an Android 11 phone reported
/// nearbyWifiDevices missing with every permission already granted, because
/// that permission does not exist before Android 13 and therefore can never be
/// granted. The app waited forever for something impossible.
void main() {
  group('permissions match the OS version', () {
    test('Android 11 asks only for location', () {
      // API 30. Bluetooth is install-time here (BLUETOOTH / BLUETOOTH_ADMIN in
      // the manifest), so there is nothing to request at runtime.
      final perms = NearbyTransport.permissionsFor(30);
      expect(perms, [Permission.locationWhenInUse]);
      expect(perms, isNot(contains(Permission.nearbyWifiDevices)));
      expect(perms, isNot(contains(Permission.bluetoothScan)));
      expect(perms, isNot(contains(Permission.notification)));
    });

    test('Android 12 adds the Bluetooth runtime permissions', () {
      final perms = NearbyTransport.permissionsFor(31);
      expect(perms, contains(Permission.bluetoothScan));
      expect(perms, contains(Permission.bluetoothAdvertise));
      expect(perms, contains(Permission.bluetoothConnect));
      expect(perms, isNot(contains(Permission.nearbyWifiDevices)),
          reason: 'nearbyWifiDevices is Android 13+');
      expect(perms, isNot(contains(Permission.notification)));
    });

    test('Android 13 adds nearby wifi and notifications', () {
      final perms = NearbyTransport.permissionsFor(33);
      expect(perms, contains(Permission.nearbyWifiDevices));
      expect(perms, contains(Permission.notification));
      expect(perms, contains(Permission.bluetoothScan));
    });

    test('Android 14 and 15 behave like 13', () {
      expect(NearbyTransport.permissionsFor(34),
          equals(NearbyTransport.permissionsFor(33)));
      expect(NearbyTransport.permissionsFor(35),
          equals(NearbyTransport.permissionsFor(33)));
    });

    test('location is required on every version', () {
      // Nearby needs it even though this app never asks where you are, and
      // without it discovery fails or thrashes.
      for (final sdk in [21, 26, 29, 30, 31, 33, 34, 36]) {
        expect(NearbyTransport.permissionsFor(sdk),
            contains(Permission.locationWhenInUse),
            reason: 'missing on API $sdk');
      }
    });

    test('no version is ever asked for a permission it cannot grant', () {
      // The exact shape of the original bug.
      for (var sdk = 21; sdk < 31; sdk++) {
        final perms = NearbyTransport.permissionsFor(sdk);
        expect(perms, isNot(contains(Permission.bluetoothScan)));
        expect(perms, isNot(contains(Permission.nearbyWifiDevices)));
        expect(perms, isNot(contains(Permission.notification)));
      }
      for (var sdk = 31; sdk < 33; sdk++) {
        expect(NearbyTransport.permissionsFor(sdk),
            isNot(contains(Permission.nearbyWifiDevices)));
      }
    });

    test('the list never contains duplicates', () {
      for (final sdk in [30, 31, 33, 34]) {
        final perms = NearbyTransport.permissionsFor(sdk);
        expect(perms.toSet().length, perms.length, reason: 'API $sdk');
      }
    });
  });
}
