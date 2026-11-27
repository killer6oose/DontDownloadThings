import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop.dart';

/// Runs yt-dlp and opens files, on either the phone or the PC.
///
/// On Android the work happens in android/app/src/main/kotlin/MainActivity.kt,
/// reached through [channel]. On Windows it happens in desktop.dart.
class Native {
  static const channel = MethodChannel('snag/native');
  static const _progress = EventChannel('snag/progress');

  static bool get isPhone => Platform.isAndroid;

  /// Links shared to Snag while it's already open (phone only).
  static final incoming = StreamController<String>.broadcast();

  /// Android refused an update install, with its reason.
  static final installFailed = StreamController<String>.broadcast();

  /// Progress callbacks for running downloads, by download id.
  static final _listeners = <String, void Function(double, String)>{};

  static void listen() {
    if (!isPhone) return;
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'incoming':
          incoming.add(call.arguments as String);
        case 'installFailed':
          installFailed.add(call.arguments as String);
      }
    });
    _progress.receiveBroadcastStream().listen((event) {
      final e = Map<String, dynamic>.from(event as Map);
      final line = e['line'] as String? ?? '';
      final item = RegExp(r'item (\d+) of (\d+)').firstMatch(line);
      _listeners[e['id']]?.call((e['progress'] as num).toDouble(), item == null ? '' : 'Item ${item[1]} of ${item[2]}');
    });
  }

  /// Runs yt-dlp with [args] and returns what it printed.
  static Future<String> run(List<String> args) async {
    await freshYtDlp();
    if (!isPhone) return Desktop.run(args);
    return (await channel.invokeMethod<String>('run', {'args': args})) ?? '';
  }

  /// Downloads [url] into [folder] and returns the saved files. [onProgress]
  /// gets the percentage (or -1 when unknown) and "Item 3 of 14" for playlists.
  static Future<List<Map<String, dynamic>>> download(String id, String url, List<String> args, String folder,
      void Function(double percent, String detail) onProgress) async {
    await freshYtDlp();
    if (!isPhone) return Desktop.download(id, url, args, folder, onProgress);
    _listeners[id] = onProgress;
    try {
      final files =
          await channel.invokeMethod<List>('download', {'id': id, 'url': url, 'args': args, 'folder': folder});
      return (files ?? []).map((f) => Map<String, dynamic>.from(f as Map)).toList();
    } finally {
      _listeners.remove(id);
    }
  }

  static Future<void> cancel(String id) => isPhone ? channel.invokeMethod('cancel', {'id': id}) : Desktop.cancel(id);

  static Future<String> ytDlpVersion() async =>
      isPhone ? (await channel.invokeMethod<String>('ytDlpVersion')) ?? '' : Desktop.version();

  /// Returns 'DONE' or 'ALREADY_UP_TO_DATE'.
  static Future<String> updateYtDlp() async =>
      isPhone ? (await channel.invokeMethod<String>('updateYtDlp')) ?? '' : Desktop.update();

  /// Opens a finished download in the phone's or PC's default player.
  static Future<void> open(Map<String, dynamic> file) => isPhone
      ? channel.invokeMethod('open', {'uri': file['uri'], 'mime': file['mime']})
      : Desktop.open(file['path'] as String);

  static Future<void>? _fresh;

  /// The bundled yt-dlp goes stale as YouTube and other sites change, so it
  /// updates itself once a day before the first search or download. If the
  /// update fails (offline, GitHub down) the current copy is used anyway.
  static Future<void> freshYtDlp() => _fresh ??= () async {
        final prefs = await SharedPreferences.getInstance();
        final last = prefs.getInt('ytDlpUpdated') ?? 0;
        if (DateTime.now().millisecondsSinceEpoch - last < const Duration(days: 1).inMilliseconds) return;
        try {
          await updateYtDlp().timeout(const Duration(minutes: 2));
          await prefs.setInt('ytDlpUpdated', DateTime.now().millisecondsSinceEpoch);
        } catch (_) {
          // Try again next time the app opens.
        }
      }();
}

/// Pulls the first web link out of shared text. YouTube shares just the link,
/// but some apps share "Check this out: https://...".
String? findLink(String text) => RegExp(r'https?://\S+').firstMatch(text)?.group(0);
