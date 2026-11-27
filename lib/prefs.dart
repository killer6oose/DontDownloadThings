import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Everything on the Settings screen, saved on this phone only.
class Prefs extends ChangeNotifier {
  static const audioFormats = ['mp3', 'm4a', 'opus', 'flac'];
  static const audioBitrates = [128, 192, 256, 320];
  static const videoQualities = ['360', '480', '720', '1080', '1440', '2160', 'best'];
  static const videoFormats = ['mp4', 'mkv'];

  // Android only lets apps save music and video into certain top-level
  // folders, so the folder settings have to start with one of these.
  static const audioRoots = ['Music', 'Podcasts', 'Audiobooks', 'Download'];
  static const videoRoots = ['Movies', 'DCIM', 'Download'];

  final SharedPreferences _p;
  Prefs(this._p);

  static Future<Prefs> load() async => Prefs(await SharedPreferences.getInstance());

  String get audioFormat => _p.getString('audioFormat') ?? 'mp3';
  int get audioBitrate => _p.getInt('audioBitrate') ?? 320;
  bool get embedArt => _p.getBool('embedArt') ?? true;
  String get videoQuality => _p.getString('videoQuality') ?? '1080';
  String get videoFormat => _p.getString('videoFormat') ?? 'mp4';
  bool get subtitles => _p.getBool('subtitles') ?? false;
  String get subtitleLangs => _p.getString('subtitleLangs') ?? 'en.*';
  // The phone saves through Android's media store, so its folders are
  // relative (Music/Snag). The PC saves to a full path in your user folder.
  String get audioFolder => _p.getString('audioFolder') ?? (Platform.isAndroid ? 'Music/Snag' : _home('Music'));
  String get videoFolder => _p.getString('videoFolder') ?? (Platform.isAndroid ? 'Movies/Snag' : _home('Videos'));

  static String _home(String folder) =>
      '${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.'}${Platform.pathSeparator}$folder${Platform.pathSeparator}Snag';
  String get spotifyId => _p.getString('spotifyId') ?? '';
  String get spotifySecret => _p.getString('spotifySecret') ?? '';
  String get theme => _p.getString('theme') ?? 'lagoon';

  Future<void> set(String key, Object value) async {
    switch (value) {
      case String v:
        await _p.setString(key, v.trim());
      case int v:
        await _p.setInt(key, v);
      case bool v:
        await _p.setBool(key, v);
    }
    notifyListeners();
  }

  /// Raw access for the download history, which lives beside the settings.
  SharedPreferences get raw => _p;
}

/// Cleans up a folder typed into Settings and checks Android will accept it.
/// Returns the tidy folder, or null if it doesn't start with an allowed root.
String? cleanFolder(String typed, List<String> roots) {
  final parts = typed.replaceAll('\\', '/').split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return null;
  final root = roots.where((r) => r.toLowerCase() == parts.first.toLowerCase()).firstOrNull;
  if (root == null) return null;
  // Characters Android won't allow in a folder name.
  if (parts.any((p) => RegExp(r'[<>:"|?*]').hasMatch(p) || p == '..' || p == '.')) return null;
  return [root, ...parts.skip(1)].join('/');
}
