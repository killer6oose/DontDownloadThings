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

1. Bump `version:` in pubspec.yaml (e.g. `1.0.1+2`) and push to main.
2. GitHub builds the release with 3 files: `snag_latest.apk`, `snag_latest.zip` and `snag_version.txt`.
3. Copy all 3 into the apps folder served at https://hub.adgoose/files/ on the Pi.

hub.adgoose uses a certificate from the ADGoose Home CA. Snag has that CA built in (`assets/certs/adgoose-home-ca.crt`, and a copy for Android in `android/app/src/main/res/raw/`), so if the CA is ever replaced, swap both files and release an update while the old certificate still works.

The phone and PC apps check on launch and from Settings > Check for update.

## Tests

```
flutter test
```

## The Web Page On The Pi

http://snag.adgoose is the same app as a web page, for anyone on the tailnet. The Pi does the downloading: each finished file is kept in `/srv/snag/Music` or `/srv/snag/Videos` and is also saved to whatever device the page is open on. History is kept per browser.

Each release has `snag_web.zip`, which holds the page (`web/`) and the server files. On the Pi (64-bit Pi OS):

1. Install what yt-dlp needs. Deno is how yt-dlp gets past YouTube's JavaScript checks:

   ```
   sudo apt install python3-venv ffmpeg unzip
   curl -fsSL https://deno.land/install.sh | sudo DENO_INSTALL=/usr/local sh
   ```

2. Make a user for the server, its folders, and yt-dlp:

   ```
   sudo useradd --system --home /srv/snag --shell /usr/sbin/nologin snag
   sudo mkdir -p /opt/snag /srv/snag
   sudo chown snag:snag /opt/snag /srv/snag
   sudo -u snag python3 -m venv /opt/snag/venv
   sudo -u snag /opt/snag/venv/bin/pip install "yt-dlp[default]"
   ```

3. Unzip the release and put the files in place:

   ```
   unzip snag_web.zip -d snag_web
   sudo cp snag_web/snag_server.py /opt/snag/
   sudo rm -rf /var/www/snag && sudo cp -r snag_web/web /var/www/snag
   sudo cp snag_web/snag.service /etc/systemd/system/
   sudo cp snag_web/apache-snag.conf /etc/apache2/sites-available/snag.conf
   ```

4. Start it:

   ```
   sudo systemctl daemon-reload
   sudo systemctl enable --now snag
   sudo a2enmod proxy proxy_http rewrite headers
   sudo a2ensite snag
   sudo systemctl reload apache2
   ```

5. Add `snag.adgoose` to the Samba DNS, pointing at the Pi, the same way as recipe.adgoose.

To update the page later, repeat step 3 and run `sudo systemctl restart snag`. yt-dlp updates from the page's Settings > Update yt-dlp, and the page does that by itself once a day.

The server's settings are in `snag.service`: `SNAG_MEDIA` (where files go, default `/srv/snag`) and `SNAG_PORT` (default 8790, which must match `apache-snag.conf`). If something fails, `journalctl -u snag` shows why.
