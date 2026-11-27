import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// The Windows side of Snag. Where the phone uses the yt-dlp library built
/// into the app, the PC runs yt-dlp.exe and ffmpeg.exe from the tools folder
/// next to Snag.exe, and saves straight into the chosen folders.
///
/// Failures are thrown as PlatformException with the same codes the Android
/// side uses ('failed', 'cancelled') so the rest of the app handles both alike.
class Desktop {
  static final _running = <String, Process>{};
  static final _cancelled = <String>{};

  /// tools\yt-dlp.exe beside Snag.exe. Falls back to a yt-dlp on the PATH,
  /// which is handy when running from source.
  static String get toolsDir => '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}tools';

  static String get ytDlp {
    final bundled = File('$toolsDir${Platform.pathSeparator}yt-dlp.exe');
    return bundled.existsSync() ? bundled.path : 'yt-dlp';
  }

  /// Options added to every run: use our ffmpeg and ignore any yt-dlp
  /// config file someone has on the PC.
  static List<String> get _common => [
        '--ignore-config',
        if (Directory(toolsDir).existsSync()) ...['--ffmpeg-location', toolsDir],
      ];

  static Future<String> run(List<String> args) async {
    final result = await Process.run(ytDlp, [..._common, ...args], stdoutEncoding: utf8, stderrEncoding: utf8);
    if (result.exitCode != 0) throw PlatformException(code: 'failed', message: _lastError(result.stderr as String));
    return result.stdout as String;
  }

  /// Downloads into [folder]. yt-dlp prints a progress line for us (starting
  /// SNAG) and the full path of each finished file.
  static Future<List<Map<String, dynamic>>> download(String id, String url, List<String> args, String folder,
      void Function(double percent, String detail) onProgress) async {
    final temp = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}snag$id');
    final process = await Process.start(ytDlp, [
      ..._common,
      ...args,
      '-P', folder,
      // Half-finished pieces go to the temp folder, not into Music.
      '-P', 'temp:${temp.path}',
      '--print', 'after_move:filepath',
      '--progress', '--newline',
      '--progress-template', 'download:SNAG %(progress._percent_str)s|%(info.playlist_index)s|%(info.n_entries)s',
      url,
    ]);
    _running[id] = process;

    final paths = <String>[];
    final errors = StringBuffer();
    // Read both outputs to the end as yt-dlp writes them, then wait for it to exit.
    final out = process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.startsWith('SNAG ')) {
        final parts = line.substring(5).split('|');
        final percent = double.tryParse(parts[0].replaceAll('%', '').trim()) ?? -1;
        final item = parts.length == 3 && parts[2] != 'NA' ? 'Item ${parts[1]} of ${parts[2]}' : '';
        onProgress(percent, item);
      } else if (line.trim().isNotEmpty) {
        paths.add(line.trim());
      }
    }).asFuture<void>();
    final err = process.stderr.transform(utf8.decoder).listen(errors.write).asFuture<void>();
    final code = await process.exitCode;
    await Future.wait([out, err]);
    _running.remove(id);
    if (temp.existsSync()) temp.deleteSync(recursive: true);

    if (_cancelled.remove(id)) throw PlatformException(code: 'cancelled', message: 'Cancelled');
    if (code != 0) throw PlatformException(code: 'failed', message: _lastError(errors.toString()));
    final files = paths.where((p) => File(p).existsSync()).map((p) {
      final file = File(p);
      final ext = p.split('.').last.toLowerCase();
      return <String, dynamic>{
        'name': file.uri.pathSegments.last,
        'path': p,
        'mime': const ['mp3', 'm4a', 'opus', 'ogg', 'flac'].contains(ext) ? 'audio/$ext' : 'video/$ext',
        'size': file.lengthSync(),
        'folder': file.parent.path,
      };
    }).toList();
    if (files.isEmpty) throw PlatformException(code: 'failed', message: 'yt-dlp finished but no file came out');
    return files;
  }

  /// Stops yt-dlp and the ffmpeg it started.
  static Future<void> cancel(String id) async {
    final process = _running[id];
    if (process == null) return;
    _cancelled.add(id);
    await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
  }

  static Future<String> version() async => (await run(['--version'])).trim();

  /// yt-dlp.exe updates itself in place. Returns the same words the Android
  /// library does so Settings can show the result.
  static Future<String> update() async {
    final result = await Process.run(ytDlp, ['-U'], stdoutEncoding: utf8, stderrEncoding: utf8);
    final text = '${result.stdout}\n${result.stderr}';
    if (result.exitCode != 0) throw PlatformException(code: 'failed', message: _lastError(text));
    return text.contains('Updated yt-dlp') ? 'DONE' : 'ALREADY_UP_TO_DATE';
  }

  /// Opens a finished file in its default app.
  static Future<void> open(String path) => Process.run('explorer.exe', [path]);

  /// yt-dlp can print several lines; the ERROR one is the useful one.
  static String _lastError(String text) {
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    return lines.lastWhere((l) => l.contains('ERROR'), orElse: () => lines.isEmpty ? 'yt-dlp failed' : lines.last);
  }
}
