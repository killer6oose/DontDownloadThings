# Snag Setup

GitHub builds everything (see `.github/workflows/build.yml`), so you only need the steps below to build on your own PC.

## Release Signing On GitHub

The APK is signed with the Snag key when these 2 repository secrets exist (Settings > Secrets and variables > Actions):

- `SNAG_KEYSTORE_BASE64` - the contents of `snag.jks.base64.txt`
- `SNAG_KEYSTORE_PASSWORD` - the password

Keep the key safe. If it's lost, the next update won't install over the old app and everyone has to uninstall first.

## Build The Windows App

Needs Windows with Flutter and Visual Studio 2022 (the "Desktop development with C++" workload).

```
flutter build windows --release
```

Then put `yt-dlp.exe`, `ffmpeg.exe` and `ffprobe.exe` in a `tools` folder inside `build\windows\x64\runner\Release`.

## Build the APK

From this folder:

```
flutter pub get
flutter build apk --release --target-platform android-arm64
```

The APK is `build/app/outputs/flutter-apk/app-release.apk`. It's arm64 only (every phone from the last several years) and about 60 MB because yt-dlp's Python and ffmpeg are inside it.

The first build downloads the youtubedl-android library from Maven Central, which is about 200 MB.

## Signing

Without `android/key.properties` the release APK is signed with your PC's debug key. That's fine for testing, but every update has to be signed with the same key or Android refuses to install it over the old one. To use a fixed key, copy `key.properties` and the keystore from NomBook or 1,000 Hours into `android/` (both are git-ignored), or make a new one:

```
keytool -genkey -v -keystore android/snag.jks -keyalg RSA -keysize 2048 -validity 10000 -alias snag
```

and create `android/key.properties`:

```
storeFile=snag.jks
storePassword=...
keyAlias=snag
keyPassword=...
```

## Publishing An Update

1. Bump `version:` in pubspec.yaml (e.g. `1.0.1+2`).
2. `flutter build apk --release`
3. Upload the APK to https://cronotech.org/hattons/snag/ as `Snag_Latest.apk`.
4. Put the same version on line 1 of `version.txt` in that folder.

Phones check on launch and from Settings > Check for update.

## Tests

```
flutter test
```
