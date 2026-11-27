import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../downloads.dart';
import '../native.dart';
import '../prefs.dart';
import '../theme.dart';

/// The sheet that pops up for a link: audio or video, quality and format,
/// starting from the Settings defaults.
Future<void> showOptionsSheet(BuildContext context, String url, {bool audio = true}) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _OptionsSheet(url: url, audio: audio),
    );

class _OptionsSheet extends StatefulWidget {
  final String url;
  final bool audio;
  const _OptionsSheet({required this.url, required this.audio});

  @override
  State<_OptionsSheet> createState() => _OptionsSheetState();
}

class _OptionsSheetState extends State<_OptionsSheet> {
  late final Options _o = Options.fromPrefs(context.read<Prefs>(), audio: widget.audio);
  bool _loading = true;
  String _title = '';
  String _about = '';
  String _thumb = '';
  String _error = '';
  int _playlistCount = 0; // more than 0 means the link is a playlist
  bool _hasList = false; // a single video that's also part of a playlist

  @override
  void initState() {
    super.initState();
    _hasList = widget.url.contains('list=');
    _readLink();
  }

  /// Asks yt-dlp for the title and length so the sheet can show what's
  /// about to be downloaded. Downloading still works if this fails.
  Future<void> _readLink() async {
    try {
      final out =
          await Native.run(['--dump-single-json', '--flat-playlist', '--no-warnings', '--no-playlist', widget.url]);
      final info = jsonDecode(out) as Map;
      final site = (info['extractor_key'] ?? info['extractor'] ?? '') as String;
      final seconds = (info['duration'] as num?)?.round() ?? 0;
      if (info['_type'] == 'playlist') {
        _playlistCount = (info['entries'] as List?)?.length ?? (info['playlist_count'] as int? ?? 0);
        _o.playlist = true;
      }
      setState(() {
        _title = (info['title'] ?? '') as String;
        _thumb = (info['thumbnail'] ?? '') as String;
        if (_thumb.isEmpty && info['thumbnails'] is List && (info['thumbnails'] as List).isNotEmpty) {
          _thumb = ((info['thumbnails'] as List).last as Map)['url'] as String? ?? '';
        }
        _about = [
          if (site.isNotEmpty) site,
          if (seconds > 0) '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
          if (_playlistCount > 0) '$_playlistCount items',
        ].join(' - ');
        _loading = false;
      });
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message ?? 'Couldn\'t read that link';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Couldn\'t read that link';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final prefs = context.read<Prefs>();

    Widget chips<T>(String heading, List<T> values, T current, String Function(T) label, void Function(T) pick) =>
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(heading, style: const TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final v in values)
                ChoiceChip(
                  label: Text(label(v)),
                  selected: v == current,
                  onSelected: (_) => setState(() => pick(v)),
                ),
            ]),
          ]),
        );

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 96,
                  height: 54,
                  color: c.ring,
                  child: _thumb.isEmpty
                      ? Icon(_o.audio ? Icons.music_note : Icons.movie_outlined, color: c.muted)
                      : Image.network(_thumb,
                          fit: BoxFit.cover,
                          // Lets the web page show thumbnails from sites that don't allow it otherwise.
                          webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
                          errorBuilder: (_, __, ___) => const SizedBox()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_loading ? 'Reading link...' : (_title.isEmpty ? widget.url : _title),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(_loading ? widget.url : (_error.isNotEmpty ? _error : _about),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: _error.isNotEmpty ? c.bad : c.muted)),
                ]),
              ),
            ]),
            if (_loading) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Audio'), icon: Icon(Icons.music_note)),
                ButtonSegment(value: false, label: Text('Video'), icon: Icon(Icons.movie_outlined)),
              ],
              selected: {_o.audio},
              onSelectionChanged: (s) => setState(() => _o.audio = s.first),
            ),
            if (_o.audio) ...[
              chips('Format', Prefs.audioFormats, _o.audioFormat, (f) => f.toUpperCase(), (f) => _o.audioFormat = f),
              if (_o.audioFormat != 'flac')
                chips('Bitrate', Prefs.audioBitrates, _o.audioBitrate, (b) => '$b kbps', (b) => _o.audioBitrate = b),
              if (_o.audioFormat == 'mp3' || _o.audioFormat == 'm4a')
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Add cover art and tags'),
                  value: _o.embedArt,
                  onChanged: (v) => setState(() => _o.embedArt = v),
                ),
            ] else ...[
              chips('Max quality', Prefs.videoQualities, _o.videoQuality, qualityLabel, (q) => _o.videoQuality = q),
              chips('Format', Prefs.videoFormats, _o.videoFormat, (f) => f.toUpperCase(), (f) => _o.videoFormat = f),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Download subtitles'),
                value: _o.subtitles,
                onChanged: (v) => setState(() => _o.subtitles = v),
              ),
            ],
            if (_playlistCount > 0 || _hasList)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_playlistCount > 0 ? 'Whole playlist ($_playlistCount)' : 'Whole playlist'),
                value: _o.playlist,
                onChanged: (v) => setState(() => _o.playlist = v),
              ),
            const SizedBox(height: 8),
            Text(
                Native.isWeb
                    ? 'Saves to the Pi\'s ${_o.audio ? 'Music' : 'Videos'} folder and to this device'
                    : 'Saves to ${_o.audio ? prefs.audioFolder : prefs.videoFolder}',
                style: TextStyle(fontSize: 13, color: c.muted)),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                context.read<Downloads>().add(widget.url, _title, _o);
                Navigator.pop(context);
              },
              child: const Text('Download'),
            ),
          ]),
        ),
      ),
    );
  }
}

String qualityLabel(String q) => q == 'best'
    ? 'Best'
    : q == '2160'
        ? '4K'
        : '${q}p';
