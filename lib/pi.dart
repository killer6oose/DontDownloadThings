import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'browser_save.dart' if (dart.library.io) 'browser_save_stub.dart';

/// The web page side of Snag. The page itself can't run yt-dlp, so it asks
/// server/snag_server.py on the Pi, which keeps the finished files in its own
/// Music and Videos folders. Each finished file is then downloaded to the
/// device the page is open on.
///
/// Failures are thrown as PlatformException with the same codes the phone
/// uses ('failed', 'cancelled') so the rest of the app handles them alike.
class Pi {
  /// The page is served by the Pi, so the server is wherever the page came
  /// from. For running the page from source, pass
  /// --dart-define=SNAG_SERVER=http://localhost:8790
  static const _server = String.fromEnvironment('SNAG_SERVER');
  static Uri _url(String path) => _server.isEmpty ? Uri.base.resolve(path) : Uri.parse('$_server$path');

  static Future<Map<String, dynamic>> _call(String path, [Map<String, dynamic>? body]) async {
    final res = body == null
        ? await http.get(_url(path))
        : await http.post(_url(path), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
    final Map<String, dynamic> data;
    try {
      data = Map<String, dynamic>.from(jsonDecode(res.body) as Map);
    } catch (_) {
      throw PlatformException(code: 'failed', message: 'The Pi didn\'t answer properly (error ${res.statusCode})');
    }
    if (res.statusCode != 200) throw PlatformException(code: 'failed', message: data['error'] as String? ?? 'Error');
    return data;
  }

  static Future<String> run(List<String> args) async => (await _call('/api/run', {'args': args}))['out'] as String;

  /// Starts the download on the Pi (or picks it up again after the page was
  /// reloaded, since the id stays the same) and checks on it every second.
  static Future<List<Map<String, dynamic>>> download(
      String id, String url, List<String> args, void Function(double percent, String detail) onProgress) async {
    var job = await _call(
        '/api/download', {'id': id, 'url': url, 'args': args, 'kind': args.contains('-x') ? 'audio' : 'video'});
    while (job['state'] == 'queued' || job['state'] == 'running') {
      onProgress((job['progress'] as num).toDouble(), job['detail'] as String);
      await Future<void>.delayed(const Duration(seconds: 1));
      job = await _call('/api/job/$id');
    }
    if (job['state'] == 'cancelled') throw PlatformException(code: 'cancelled', message: 'Cancelled');
    if (job['state'] != 'done') throw PlatformException(code: 'failed', message: job['error'] as String);
    final files = (job['files'] as List).map((f) => Map<String, dynamic>.from(f as Map)).toList();
    for (final f in files) {
      open(f);
    }
    return files;
  }

  static Future<void> cancel(String id) => _call('/api/cancel/$id', {});

  static Future<String> version() async => (await _call('/api/version'))['version'] as String;

  static Future<String> update() async => (await _call('/api/update', {}))['status'] as String;

  /// Downloads the file from the Pi to this device.
  static void open(Map<String, dynamic> file) =>
      saveFromUrl(_url(file['url'] as String).toString(), file['name'] as String);

  /// Browsers won't let a page read Spotify directly, so the Pi fetches it.
  static Future<http.Response> fetch(String method, Uri url, Map<String, String> headers, String? body) async {
    final data = await _call('/api/proxy', {'method': method, 'url': url.toString(), 'headers': headers, 'body': body});
    return http.Response.bytes(utf8.encode(data['body'] as String), data['status'] as int);
  }
}
