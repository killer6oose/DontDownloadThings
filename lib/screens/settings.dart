import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../native.dart';
import '../prefs.dart';
import '../theme.dart';
import '../widgets/update_dialog.dart';
import 'options_sheet.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _ytDlp = '';
  String _ytDlpStatus = '';
  bool _updatingYtDlp = false;
  String _appVersion = '';
  String _updateStatus = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((i) {
      if (mounted) setState(() => _appVersion = i.version);
    });
    Native.ytDlpVersion().then((v) {
      if (mounted) setState(() => _ytDlp = v);
    }).catchError((_) {});
  }

  Future<void> _updateYtDlp() async {
    final prefs = context.read<Prefs>();
    setState(() {
      _updatingYtDlp = true;
      _ytDlpStatus = 'Updating...';
    });
    try {
      final status = await Native.updateYtDlp();
      await prefs.raw.setInt('ytDlpUpdated', DateTime.now().millisecondsSinceEpoch);
      final version = await Native.ytDlpVersion();
      setState(() {
        _ytDlp = version;
        _ytDlpStatus = status == 'DONE' ? 'Updated' : 'Already up to date';
      });
    } on PlatformException catch (e) {
      setState(() => _ytDlpStatus = 'Update failed: ${e.message}');
    }
    setState(() => _updatingYtDlp = false);
  }

  /// A small text box dialog for the folder and Spotify settings.
  Future<void> _editText(String title, String key, String current,
      {String help = '', bool secret = false, String? Function(String)? check}) async {
    final box = TextEditingController(text: current);
    String error = '';
    final saved = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: box,
              autofocus: true,
              obscureText: secret,
              decoration: InputDecoration(errorText: error.isEmpty ? null : error),
            ),
            if (help.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(help, style: TextStyle(fontSize: 13, color: context.c.muted)),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (check == null) return Navigator.pop(context, box.text);
                final cleaned = check(box.text);
                if (cleaned == null) {
                  setDialog(() => error = 'That folder won\'t work. See below.');
                } else {
                  Navigator.pop(context, cleaned);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != null && mounted) await context.read<Prefs>().set(key, saved);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final p = context.watch<Prefs>();

    Widget section(String title, List<Widget> rows) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(title.toUpperCase(),
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.muted, letterSpacing: 0.5)),
              ),
              ...rows,
            ]),
          ),
        );

    Widget pick<T>(String label, List<T> values, T current, String Function(T) name, void Function(T) save) => ListTile(
          title: Text(label),
          trailing: DropdownButton<T>(
            value: values.contains(current) ? current : values.first,
            underline: const SizedBox(),
            style: TextStyle(color: c.accent, fontWeight: FontWeight.w500, fontFamily: 'Fredoka', fontSize: 15),
            items: [for (final v in values) DropdownMenuItem(value: v, child: Text(name(v)))],
            onChanged: (v) {
              if (v != null) save(v);
            },
          ),
        );

    Widget value(String text) => Text(text, style: TextStyle(color: c.accent, fontWeight: FontWeight.w500));

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          section('Audio defaults', [
            pick('Format', Prefs.audioFormats, p.audioFormat, (f) => f.toUpperCase(), (f) => p.set('audioFormat', f)),
            if (p.audioFormat != 'flac')
              pick('Bitrate', Prefs.audioBitrates, p.audioBitrate, (b) => '$b kbps', (b) => p.set('audioBitrate', b)),
            SwitchListTile(
              title: const Text('Add cover art and tags'),
              subtitle: const Text('MP3 and M4A only'),
              value: p.embedArt,
              onChanged: (v) => p.set('embedArt', v),
            ),
          ]),
          section('Video defaults', [
            pick('Max quality', Prefs.videoQualities, p.videoQuality, qualityLabel, (q) => p.set('videoQuality', q)),
            pick('Format', Prefs.videoFormats, p.videoFormat, (f) => f.toUpperCase(), (f) => p.set('videoFormat', f)),
            SwitchListTile(
              title: const Text('Subtitles'),
              value: p.subtitles,
              onChanged: (v) => p.set('subtitles', v),
            ),
            if (p.subtitles)
              ListTile(
                title: const Text('Subtitle languages'),
                trailing: value(p.subtitleLangs),
                onTap: () => _editText('Subtitle languages', 'subtitleLangs', p.subtitleLangs,
                    help: 'Language codes separated by commas. en.* means any English, '
                        'e.g. en.*,mi for English and te reo Māori.'),
              ),
          ]),
          section('Saving', [
            if (!Native.isPhone) ...[
              ListTile(
                title: const Text('Music folder'),
                subtitle: Text(p.audioFolder),
                trailing: const Icon(Icons.folder_open),
                onTap: () async {
                  final folder = await getDirectoryPath(initialDirectory: p.audioFolder);
                  if (folder != null) p.set('audioFolder', folder);
                },
              ),
              ListTile(
                title: const Text('Video folder'),
                subtitle: Text(p.videoFolder),
                trailing: const Icon(Icons.folder_open),
                onTap: () async {
                  final folder = await getDirectoryPath(initialDirectory: p.videoFolder);
                  if (folder != null) p.set('videoFolder', folder);
                },
              ),
            ] else ...[
              ListTile(
                title: const Text('Music folder'),
                trailing: value(p.audioFolder),
                onTap: () => _editText('Music folder', 'audioFolder', p.audioFolder,
                    help: 'Has to start with ${Prefs.audioRoots.join(', ')}. For example Music/Snag.',
                    check: (s) => cleanFolder(s, Prefs.audioRoots)),
              ),
              ListTile(
                title: const Text('Video folder'),
                trailing: value(p.videoFolder),
                onTap: () => _editText('Video folder', 'videoFolder', p.videoFolder,
                    help: 'Has to start with ${Prefs.videoRoots.join(', ')}. For example Movies/Snag.',
                    check: (s) => cleanFolder(s, Prefs.videoRoots)),
              ),
            ],
          ]),
          section('Spotify', [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Optional. Public playlists work without these, but Spotify\'s embed page can stop at 100 tracks. '
                'For bigger playlists, make a free app at developer.spotify.com and paste its client ID and secret here.',
                style: TextStyle(fontSize: 13, color: c.muted),
              ),
            ),
            ListTile(
              title: const Text('Client ID'),
              trailing: value(p.spotifyId.isEmpty ? 'Not set' : 'Set'),
              onTap: () => _editText('Spotify client ID', 'spotifyId', p.spotifyId),
            ),
            ListTile(
              title: const Text('Client secret'),
              trailing: value(p.spotifySecret.isEmpty ? 'Not set' : 'Set'),
              onTap: () => _editText('Spotify client secret', 'spotifySecret', p.spotifySecret, secret: true),
            ),
          ]),
          section('Look and updates', [
            pick(
              'Theme',
              ['system', ...snagThemes.map((t) => t.id)],
              p.theme,
              (id) => id == 'system' ? 'Match phone' : themeFor(id).name,
              (id) => p.set('theme', id),
            ),
            ListTile(
              title: Text(_ytDlp.isEmpty ? 'yt-dlp' : 'yt-dlp $_ytDlp'),
              subtitle: Text(_ytDlpStatus.isEmpty ? 'Update this if downloads from a site stop working' : _ytDlpStatus),
              trailing: _updatingYtDlp
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3))
                  : TextButton(onPressed: _updateYtDlp, child: const Text('Update')),
            ),
            if (!Native.isPhone)
              ListTile(
                title: Text('Snag $_appVersion'),
                subtitle: const Text('New versions are on GitHub, under DontDownloadThings releases'),
              )
            else
              ListTile(
                title: Text('Snag $_appVersion'),
                subtitle: _updateStatus.isEmpty ? null : Text(_updateStatus),
                trailing: TextButton(
                  onPressed: () async {
                    final status = await checkForUpdate(context, force: true);
                    if (mounted) setState(() => _updateStatus = status);
                  },
                  child: const Text('Check for update'),
                ),
              ),
          ]),
          Text(
            'Only download things you have the right to keep, like your own videos, free music, or Creative Commons content.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: c.muted),
          ),
        ],
      ),
    );
  }
}
