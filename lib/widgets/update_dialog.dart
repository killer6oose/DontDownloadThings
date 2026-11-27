import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../native.dart';

/// Self-updates from the family apps folder on the Pi instead of an app store,
/// like the other family apps.
///
/// snag_version.txt holds the latest version on line 1, matching pubspec.yaml
/// (e.g. `1.0.1+2`). Beside it are snag_latest.apk for phones and
/// snag_latest.zip (the Windows release zip) for PCs.
const _base = 'https://hub.adgoose/apps';
const _versionUrl = '$_base/snag_version.txt';
const _apkUrl = '$_base/snag_latest.apk';
const _zipUrl = '$_base/snag_latest.zip';
const _channel = Native.channel;

/// Version and install details. The phone asks Android; the PC reads the
/// version built into Snag.exe and can always replace its own files.
Future<Map<String, dynamic>> _info() async {
  if (Platform.isAndroid) return Map<String, dynamic>.from(await _channel.invokeMethod('info'));
  final p = await PackageInfo.fromPlatform();
  return {
    'versionName': p.version,
    'versionCode': p.buildNumber,
    'cacheDir': Directory.systemTemp.path,
    'canInstall': true
  };
}

const _lastVersionKey = 'last_run_version';

bool _checked = false;

/// Checks once per launch (or whenever [force] is set, from Settings) and
/// offers the update if the server has a newer one. Returns a short status
/// for the Settings screen.
Future<String> checkForUpdate(BuildContext context, {bool force = false}) async {
  if (!Platform.isAndroid && !Platform.isWindows) return '';
  if (_checked && !force) return '';
  _checked = true;
  try {
    final info = await _info();
    final name = info['versionName'] as String;
    final current = '$name+${info['versionCode']}';

    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString(_lastVersionKey);
    await prefs.setString(_lastVersionKey, current);
    if (!force && last != null && last != current && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Updated to version $name')));
    }

    final res = await http
        .get(Uri.parse('$_versionUrl?t=${DateTime.now().millisecondsSinceEpoch}'))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return 'Couldn\'t check for updates (error ${res.statusCode}).';
    final lines = res.body.split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return 'Couldn\'t check for updates.';
    final latest = lines.first;
    if (!isNewerVersion(latest, current)) return 'You\'re on the latest version.';
    if (!context.mounted) return '';

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UpdateDialog(
        current: name,
        latest: latest.split('+').first,
        apkUrl: Platform.isAndroid ? _apkUrl : _zipUrl,
        cacheDir: info['cacheDir'] as String,
      ),
    );
    return '';
  } catch (_) {
    // Offline or server unavailable: try again next launch.
    return 'Couldn\'t reach the update server.';
  }
}

/// True if [remote] is newer than [current]. Both are `x.y.z` with an
/// optional `+build`; the build number only counts if both have one.
bool isNewerVersion(String remote, String current) {
  List<int> parse(String v) {
    final parts = v.trim().replaceFirst(RegExp('^v'), '').split('+');
    final nums = parts[0].split('.').map((s) => int.tryParse(s) ?? 0).toList();
    while (nums.length < 3) {
      nums.add(0);
    }
    return [...nums.take(3), if (parts.length > 1) int.tryParse(parts[1]) ?? 0];
  }

  final r = parse(remote), c = parse(current);
  for (var i = 0; i < 3; i++) {
    if (r[i] != c[i]) return r[i] > c[i];
  }
  return r.length > 3 && c.length > 3 && r[3] > c[3];
}

enum _Stage { prompt, permission, downloading, ready, installing, failed }

class _UpdateDialog extends StatefulWidget {
  final String current;
  final String latest;
  final String apkUrl;
  final String cacheDir;
  const _UpdateDialog({required this.current, required this.latest, required this.apkUrl, required this.cacheDir});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const _restartSeconds = 20;

  _Stage _stage = _Stage.prompt;
  int _received = 0;
  int _total = 0;
  String _error = '';
  int _secondsLeft = _restartSeconds;
  Timer? _countdown;
  http.Client? _client;
  StreamSubscription<String>? _installFailed;
  late final File _file = File('${widget.cacheDir}/snag_update.${Platform.isAndroid ? 'apk' : 'zip'}');
  late final AnimationController _bounce = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))
    ..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _installFailed = Native.installFailed.stream.listen((message) {
      if (mounted) _fail(message);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _installFailed?.cancel();
    _countdown?.cancel();
    _client?.close();
    _bounce.dispose();
    super.dispose();
  }

  /// Back from Android's "Install unknown apps" settings.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed && _stage == _Stage.permission) _begin();
  }

  void _fail(String message) {
    _countdown?.cancel();
    setState(() {
      _stage = _Stage.failed;
      _error = message;
    });
  }

  Future<void> _begin() async {
    final info = await _info();
    if (!mounted) return;
    if (info['canInstall'] != true) {
      setState(() => _stage = _Stage.permission);
      return;
    }
    await _download();
  }

  Future<void> _download() async {
    setState(() {
      _stage = _Stage.downloading;
      _received = 0;
      _total = 0;
    });
    IOSink? sink;
    try {
      _client = http.Client();
      final res = await _client!.send(http.Request('GET', Uri.parse(widget.apkUrl)));
      if (res.statusCode != 200) throw 'the server returned ${res.statusCode}';
      _total = res.contentLength ?? 0;
      sink = _file.openWrite();
      await for (final chunk in res.stream) {
        sink.add(chunk);
        _received += chunk.length;
        if (mounted) setState(() {});
      }
      await sink.close();
      sink = null;
      if (_total > 0 && _received != _total) throw 'the download was incomplete';
      if (!mounted) return;
      setState(() {
        _stage = _Stage.ready;
        _secondsLeft = _restartSeconds;
      });
      _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
        if (_secondsLeft <= 1) {
          _install();
        } else {
          setState(() => _secondsLeft--);
        }
      });
    } catch (e) {
      await sink?.close();
      if (mounted && _stage == _Stage.downloading) _fail('Download failed: $e');
    } finally {
      _client?.close();
      _client = null;
    }
  }

  Future<void> _install() async {
    _countdown?.cancel();
    setState(() => _stage = _Stage.installing);
    try {
      if (Platform.isWindows) {
        // Snag.exe can't overwrite itself while running, so a small batch
        // file waits for it to close, unzips the update over the install
        // folder and starts it again.
        final dir = File(Platform.resolvedExecutable).parent.path;
        final script = File('${widget.cacheDir}\\snag_update.bat');
        await script.writeAsString('@echo off\r\n'
            'timeout /t 2 /nobreak >nul\r\n'
            'powershell -NoProfile -Command "Expand-Archive -Force -LiteralPath \'${_file.path}\' -DestinationPath \'$dir\'"\r\n'
            'start "" "$dir\\Snag.exe"\r\n');
        await Process.start('cmd', ['/c', script.path], mode: ProcessStartMode.detached);
        exit(0);
      }
      await _channel.invokeMethod('install', {'path': _file.path});
      // Android now asks to confirm (first time only) and replaces the app.
    } on PlatformException catch (e) {
      if (mounted) _fail('Install failed: ${e.message}');
    }
  }

  String _mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    Widget icon(IconData i, {Color? colour}) => Icon(i, size: 56, color: colour ?? scheme.primary);

    final (String title, Widget body, List<Widget> actions) = switch (_stage) {
      _Stage.prompt => (
          'Update available',
          Column(mainAxisSize: MainAxisSize.min, children: [
            icon(Icons.system_update),
            const SizedBox(height: 12),
            Text('Version ${widget.latest} is ready. You have ${widget.current}.', textAlign: TextAlign.center),
          ]),
          [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
            FilledButton(onPressed: _begin, child: const Text('Update')),
          ],
        ),
      _Stage.permission => (
          'Allow updates',
          const Text('Android needs your OK for Snag to install its own updates. '
              'Turn on "Allow from this source", then come back here.'),
          [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => _channel.invokeMethod('openInstallSettings'), child: const Text('Open settings')),
          ],
        ),
      _Stage.downloading => (
          'Downloading update',
          Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedBuilder(
              animation: _bounce,
              builder: (_, child) => Transform.translate(
                offset: Offset(0, -8 * Curves.easeInOut.transform(_bounce.value)),
                child: child,
              ),
              child: icon(Icons.download_rounded),
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: _total > 0 ? _received / _total : null,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 8),
            Text(_total > 0 ? '${_mb(_received)} of ${_mb(_total)} MB' : '${_mb(_received)} MB', style: text.bodySmall),
          ]),
          [
            TextButton(
              onPressed: () {
                _client?.close();
                Navigator.pop(context);
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      _Stage.ready => (
          'Restart the app!',
          Column(mainAxisSize: MainAxisSize.min, children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 600),
              curve: Curves.elasticOut,
              builder: (_, v, child) => Transform.scale(scale: v, child: child),
              child: icon(Icons.check_circle_rounded, colour: Colors.green),
            ),
            const SizedBox(height: 12),
            const Text('The update is downloaded. The app restarts to install it.', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('Restarting in $_secondsLeft s', style: text.bodySmall),
          ]),
          [FilledButton(onPressed: _install, child: const Text('Restart now'))],
        ),
      _Stage.installing => (
          'Installing update',
          const Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 48, height: 48, child: CircularProgressIndicator(strokeWidth: 5)),
            SizedBox(height: 16),
            Text(
              'If Android asks, tap Update. The app closes while it installs, then open it again.',
              textAlign: TextAlign.center,
            ),
          ]),
          const <Widget>[],
        ),
      _Stage.failed => (
          'Update didn\'t finish',
          Text(_error),
          [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
            FilledButton(onPressed: _begin, child: const Text('Try again')),
          ],
        ),
    };

    return PopScope(
      canPop: _stage == _Stage.prompt || _stage == _Stage.failed,
      child: AlertDialog(
        title: Text(title, textAlign: TextAlign.center),
        content: SizedBox(
          width: 360,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: KeyedSubtree(key: ValueKey(_stage), child: body),
          ),
        ),
        actions: actions,
      ),
    );
  }
}
