# DontDownloadThings (Snag)

Snag is the Hatton family music and video downloader, for Android phones, Windows PCs and a web page on the family Pi (http://snag.adgoose). Paste a link or share one from YouTube, Spotify, SoundCloud, TikTok and so on, pick audio or video and the quality, and it lands in the phone's Music or Movies folder.

Only download things you have the right to keep: your own videos, free music, Creative Commons content and the like.

## Getting It

Open the [latest release](https://github.com/killer6oose/DontDownloadThings/releases/latest):

- Phone: download `snag_latest.apk` on the phone and open it (Android 10 or newer, 64-bit).
- PC: download `snag_latest.zip`, unzip it anywhere (e.g. Documents\Snag) and run `Snag.exe`. yt-dlp and ffmpeg are in the `tools` folder beside it.
- Web page: open http://snag.adgoose on the tailnet. Setting it up on the Pi is in SETUP.md, from `snag_web.zip`.

Every push to `main` builds all three and publishes a release named after the version in `pubspec.yaml`, so bump the version for each change you want to ship.

## How It Works

- Downloads run on the device with yt-dlp and ffmpeg. On the phone they come from the youtubedl-android library (the same one Seal uses); on the PC they're yt-dlp.exe and ffmpeg.exe in the tools folder. No sign-in. The web page can't run programs, so it asks the Pi (`server/snag_server.py`), which keeps a copy in its Music or Videos folder and hands the file to the browser.
- yt-dlp updates itself once a day, because YouTube changes often and an old yt-dlp stops finding or downloading things.
- Spotify music is DRM protected, so Snag never downloads from Spotify. For a Spotify playlist, album or track it reads the track names, finds each song on YouTube, flags any match that looks wrong (different length, live or cover version) and downloads the YouTube copy with Spotify's title, artist and album in the tags.
- Settings hold the defaults (MP3 320, 1080p MP4, save folders, theme). The options sheet can change them for one download.
- yt-dlp can update itself from Settings. Do that when a site stops working.
- The phone and PC apps check https://hub.adgoose/files/snag_version.txt for updates, like the other family apps, and download snag_latest.apk (phone) or snag_latest.zip (PC) from beside it.

## Code Map

- `lib/downloads.dart` - the queue, history and the exact yt-dlp options for each choice
- `lib/spotify.dart` - reading Spotify links and matching tracks to YouTube
- `lib/prefs.dart` - settings
- `lib/screens/` - home, options sheet, Spotify matching, settings
- `lib/theme.dart` - Lagoon, Berry, Fern and Midnight (dark), plus Match phone
- `lib/native.dart` - one place the app calls to run yt-dlp, on any platform
- `lib/desktop.dart` - the Windows side: runs yt-dlp.exe and saves into your Music and Videos folders
- `lib/pi.dart` - the web page side: asks the Pi to download, then saves the file through the browser
- `lib/home_ca.dart` - trusts the ADGoose Home CA, which signs the https certificates on the family sites
- `server/` - the Pi's server, its systemd unit and its Apache site
- `.github/workflows/build.yml` - builds the APK, Windows zip and web zip and publishes the release
- `android/app/src/main/kotlin/MainActivity.kt` - the Android side: runs yt-dlp, saves files into Music or Movies, installs updates
- `android/app/src/main/kotlin/DownloadService.kt` - the "Downloading" notification that keeps downloads alive in the background
