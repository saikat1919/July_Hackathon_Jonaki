# Release loop

Verified working on day 1 against a harness app, so day 5 is a rebuild and not a
discovery. Release builds are where R8 breaks plugin-heavy apps; finding that out
on the last afternoon is how demos die.

## Toolchain (one-time, already done on this machine)

- Flutter 3.44.8 at `C:\src\flutter` (`git clone --depth 1 -b stable`)
- Microsoft OpenJDK 21 at `C:\Program Files\Microsoft\jdk-21.0.11.10-hotspot`
- Android cmdline-tools in `%LOCALAPPDATA%\Android\sdk\cmdline-tools\latest`
- `flutter config --jdk-dir=...` and `flutter doctor --android-licenses`

Neither the JDK nor cmdline-tools were present before day 1. Verify this on any
second machine before you rely on it.

## Keystore

Gitignored, so it never reaches the public repo. Regenerate with:

```bash
keytool -genkey -v -keystore android/app/upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias crisismesh \
  -storepass <pw> -keypass <pw> \
  -dname "CN=Crisis Mesh, OU=July Hackathon, O=Crisis Mesh, L=Dhaka, C=BD"
```

Then write `android/key.properties` with `storePassword`, `keyPassword`,
`keyAlias=crisismesh`, `storeFile=upload-keystore.jks`.

**Keep this keystore for the whole hackathon.** Rebuild with a different key and
every judge who already installed has to uninstall first — Android refuses an
update signed by a different key.

## Two builds, and they must not see each other

Judges install the APK **during** judging. Their phones then start advertising,
and your demo suddenly runs inside a cluster of six or eight advertisers, which
is the top known Nearby failure mode arriving at the worst possible moment.

So the demo phones and the distributed APK use different `serviceId`s and are
invisible to each other at the discovery layer.

```bash
# PUBLIC — what judges install. This is the default.
flutter build apk --release --split-per-abi

# DEMO — your phones only.
flutter build apk --release --split-per-abi --dart-define=DEMO_BUILD=true
```

Public is the default deliberately: forgetting the flag gives judges a correct
APK, whereas the reverse would drop them straight into your cluster.

The Mesh tab states which variant is installed, so it is checkable at a glance
rather than something you have to remember. Verify a built APK directly with:

```bash
unzip -p app-arm64-v8a-release.apk lib/arm64-v8a/libapp.so | grep -c crisis_mesh.demo
# 1 = demo build, 0 = public build
```

## Build

Always `--split-per-abi`. Measured on the day-1 harness:

| Artifact | Size |
|---|---|
| fat APK (all ABIs) | 42.7 MB |
| arm64-v8a | 15.0 MB |
| armeabi-v7a | 12.4 MB |

The map tiles will add 30-50 MB on top. A fat APK plus tiles is 70-90 MB, which
breaks the "judge installs in under two minutes" criterion on venue Wi-Fi. Ship
**arm64-v8a** (every phone from roughly 2017 on) and keep armeabi-v7a as a
fallback link for an older device.

## Verify before every distribution

```bash
apksigner verify --print-certs build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Must print `CN=Crisis Mesh`. If it prints `CN=Android Debug`, `key.properties` was
not found and gradle silently fell back to the debug key.

## Distribute

1. Upload the arm64-v8a APK to a GitHub Release.
2. QR code points at the release asset URL.
3. Poster and README carry two lines, both required or the app looks broken:
   - allow install from unknown sources
   - grant all permissions on first launch
4. Backup path for hostile venue Wi-Fi: laptop hotspot or direct file share.
