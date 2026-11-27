import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../downloads.dart';
import '../native.dart';
import '../spotify.dart';
import '../theme.dart';
import '../widgets/update_dialog.dart';
import 'options_sheet.dart';
import 'settings.dart';
import 'spotify_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _link = TextEditingController();
  StreamSubscription<String>? _incoming;

  @override
  void initState() {
    super.initState();
    _incoming = Native.incoming.stream.listen(_open);
    // Start the daily yt-dlp update now so it's done before the first download.
    Native.freshYtDlp();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!Native.isPhone) return;
      // A link shared to Snag before it was running.
      final first = await Native.channel.invokeMethod<String>('initialIntent');
      if (first != null && mounted) _open(first);
      if (mounted) checkForUpdate(context);
    });
  }

  @override
  void dispose() {
    _incoming?.cancel();
    _link.dispose();
    super.dispose();
  }

  /// Opens a link from the box or from "Share to Snag". Spotify links go to
  /// the matching screen, everything else to the options sheet.
  void _open(String text, {bool audio = true}) {
    final link = findLink(text);
    if (link == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That doesn\'t have a link in it.')));
      return;
    }
    _link.text = link;
    if (isSpotify(link)) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => SpotifyScreen(link: link)));
    } else {
      showOptionsSheet(context, link, audio: audio);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final downloads = context.watch<Downloads>();

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Row(children: [
              Text('Snag', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: c.accent)),
              const Spacer(),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
              ),
            ]),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  TextField(
                    controller: _link,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: 'Paste a link',
                      suffixIcon: IconButton(
                        tooltip: 'Paste',
                        icon: const Icon(Icons.content_paste),
                        onPressed: () async {
                          final clip = await Clipboard.getData(Clipboard.kTextPlain);
                          if (clip?.text != null) setState(() => _link.text = clip!.text!.trim());
                        },
                      ),
                    ),
                    onSubmitted: (v) => _open(v),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.music_note),
                        label: const Text('Audio'),
                        onPressed: () => _open(_link.text),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.movie_outlined),
                        label: const Text('Video'),
                        onPressed: () => _open(_link.text, audio: false),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text('Works with YouTube, Spotify playlists, SoundCloud, TikTok and most other sites.',
                      style: TextStyle(fontSize: 13, color: c.muted)),
                ]),
              ),
            ),
            if (downloads.active.isNotEmpty) ...[
              const _Heading('Downloading'),
              for (final job in downloads.active) _ActiveTile(job: job),
            ],
            if (downloads.history.isNotEmpty) ...[
              _Heading('History',
                  action: TextButton(
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Clear history?'),
                          content: const Text('The list is cleared. Files you downloaded stay on the phone.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
                          ],
                        ),
                      );
                      if (ok == true) downloads.clearHistory();
                    },
                    child: const Text('Clear'),
                  )),
              for (final job in downloads.history) _HistoryTile(job: job),
            ],
            if (downloads.active.isEmpty && downloads.history.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 48),
                child: Column(children: [
                  Icon(Icons.download_rounded, size: 56, color: c.ring),
                  const SizedBox(height: 8),
                  Text('Share a video or song to Snag, or paste a link above.',
                      textAlign: TextAlign.center, style: TextStyle(color: c.muted)),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  final Widget? action;
  const _Heading(this.text, {this.action});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Row(children: [
          Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (action != null) action!,
        ]),
      );
}

String _mb(int bytes) => bytes >= 1024 * 1024 * 1024
    ? '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

class _ActiveTile extends StatelessWidget {
  final Job job;
  const _ActiveTile({required this.job});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final waiting = job.state == JobState.queued;
    final status = [
      job.options.label,
      if (job.group != null) job.group!,
      if (waiting) 'Waiting' else '${job.progress.toStringAsFixed(0)}%',
      if (job.detail.isNotEmpty) job.detail,
    ].join(' - ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          child: Row(children: [
            Icon(job.options.audio ? Icons.music_note : Icons.movie_outlined, color: c.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(job.title.isEmpty ? job.url : job.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: waiting || job.progress <= 0 ? null : job.progress / 100,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(4),
                ),
                const SizedBox(height: 4),
                Text(status, style: TextStyle(fontSize: 12, color: c.muted)),
              ]),
            ),
            IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.close),
              onPressed: () => context.read<Downloads>().cancel(job),
            ),
          ]),
        ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final Job job;
  const _HistoryTile({required this.job});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final downloads = context.read<Downloads>();
    final done = job.state == JobState.done;
    final folder = job.files.isNotEmpty ? job.files.first['folder'] as String? ?? '' : '';
    final subtitle = done
        ? [
            job.options.label,
            if (job.files.length > 1) '${job.files.length} files',
            _mb(job.bytes),
            folder,
          ].join(' - ')
        : job.state == JobState.cancelled
            ? 'Cancelled'
            : job.error;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Dismissible(
        key: ValueKey(job.id),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          child: Icon(Icons.delete_outline, color: c.muted),
        ),
        onDismissed: (_) => downloads.removeFromHistory(job),
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: Icon(job.options.audio ? Icons.music_note : Icons.movie_outlined, color: c.accent),
            title: Text(job.title.isEmpty ? job.url : job.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(subtitle,
                maxLines: done ? 1 : 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: done ? c.muted : c.bad)),
            trailing: done
                ? Text('Done', style: TextStyle(color: c.good, fontWeight: FontWeight.w600))
                : TextButton(onPressed: () => downloads.retry(job), child: const Text('Retry')),
            onTap: done && job.files.length == 1
                ? () async {
                    try {
                      await Native.open(job.files.first);
                    } on PlatformException catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text(e.message ?? 'Couldn\'t open it')));
                      }
                    }
                  }
                : null,
          ),
        ),
      ),
    );
  }
}
