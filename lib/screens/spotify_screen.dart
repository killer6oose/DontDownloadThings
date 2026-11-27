import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../downloads.dart';
import '../prefs.dart';
import '../spotify.dart';
import '../theme.dart';

/// Reads a Spotify playlist, album or track, finds each song on YouTube,
/// and lets you check the matches before downloading.
class SpotifyScreen extends StatefulWidget {
  final String link;
  const SpotifyScreen({super.key, required this.link});

  @override
  State<SpotifyScreen> createState() => _SpotifyScreenState();
}

class _SpotifyScreenState extends State<SpotifyScreen> {
  String _name = 'Spotify';
  String _error = '';
  bool _loading = true;
  List<TrackMatch> _matches = [];
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = context.read<Prefs>();
    try {
      final list = await loadSpotify(widget.link, clientId: prefs.spotifyId, secret: prefs.spotifySecret);
      if (!mounted) return;
      setState(() {
        _name = list.name;
        _matches = list.tracks.map(TrackMatch.new).toList();
        _loading = false;
      });
      // Three searches at a time is quick without hammering YouTube.
      var next = 0;
      Future<void> worker() async {
        while (!_closed && next < _matches.length) {
          await _search(_matches[next++]);
        }
      }

      await Future.wait([worker(), worker(), worker()]);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e is PlatformException ? (e.message ?? 'Something went wrong') : e.toString();
        });
      }
    }
  }

  Future<void> _search(TrackMatch m, {String? query}) async {
    setState(() => m.searching = true);
    try {
      m.candidates = await searchYouTube(query ?? '${m.track.firstArtist} - ${m.track.title}');
      final best = pickBest(m.track, m.candidates);
      m.chosen = best.index;
      m.state = best.state;
      m.why = best.why;
    } catch (e) {
      // Show yt-dlp's own reason so a failure can be tracked down.
      final reason = e is PlatformException ? (e.message ?? e.code) : e.toString();
      m.candidates = [];
      m.chosen = -1;
      m.state = MatchState.none;
      m.why = 'Search failed: $reason';
    }
    m.searching = false;
    // No match means nothing to download, so untick it.
    m.selected = m.state != MatchState.none;
    if (mounted) setState(() {});
  }

  /// Lets you pick another of the YouTube results, or search with your own words.
  Future<void> _change(TrackMatch m) async {
    final query = TextEditingController(text: '${m.track.firstArtist} - ${m.track.title}');
    final picked = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final c = context.c;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${m.track.title} - ${m.track.artist}',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              Text('Spotify length ${mmss(m.track.seconds)}', style: TextStyle(color: c.muted, fontSize: 13)),
              const SizedBox(height: 8),
              for (var i = 0; i < m.candidates.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(i == m.chosen ? Icons.radio_button_checked : Icons.radio_button_off, color: c.accent),
                  title: Text(m.candidates[i].title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${m.candidates[i].channel} - ${mmss(m.candidates[i].seconds)}'),
                  onTap: () => Navigator.pop(context, i),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: query,
                decoration: const InputDecoration(labelText: 'Search YouTube for'),
                onSubmitted: (v) => Navigator.pop(context, v),
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: () => Navigator.pop(context, query.text), child: const Text('Search again')),
            ]),
          ),
        );
      },
    );
    if (picked is int) {
      // Picking one yourself counts as checked.
      setState(() {
        m.chosen = picked;
        m.state = MatchState.good;
        m.why = 'Picked by you - ${mmss(m.candidates[picked].seconds)}';
        m.selected = true;
      });
    } else if (picked is String && picked.trim().isNotEmpty) {
      await _search(m, query: picked.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final prefs = context.watch<Prefs>();
    final options = Options.fromPrefs(prefs, audio: true);
    final searching = _matches.where((m) => m.searching).length;
    final ready = _matches.where((m) => m.selected && m.pick != null).toList();
    final toCheck = _matches.where((m) => !m.searching && m.state == MatchState.check).length;

    return Scaffold(
      appBar: AppBar(title: Text(_name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error, textAlign: TextAlign.center, style: TextStyle(color: c.bad)),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  children: [
                    Text(
                      searching > 0
                          ? '${_matches.length} tracks from Spotify. Finding them on YouTube, $searching to go...'
                          : '${_matches.length} tracks from Spotify, found on YouTube.'
                              '${toCheck > 0 ? ' $toCheck need a quick check.' : ''}',
                      style: TextStyle(fontSize: 13, color: c.muted),
                    ),
                    const SizedBox(height: 12),
                    for (final m in _matches)
                      _MatchTile(m: m, onChanged: () => setState(() {}), onChange: () => _change(m)),
                  ],
                ),
      bottomNavigationBar: _loading || _error.isNotEmpty
          ? null
          : SafeArea(
              child: Container(
                color: c.card,
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child:
                    Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Text('${ready.length} of ${_matches.length} selected'),
                    const Spacer(),
                    Text(options.label, style: TextStyle(color: c.muted)),
                  ]),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: ready.isEmpty
                        ? null
                        : () {
                            final downloads = context.read<Downloads>();
                            for (final m in ready) {
                              downloads.add(
                                m.pick!.url,
                                '${m.track.firstArtist} - ${m.track.title}',
                                Options.fromPrefs(prefs, audio: true),
                                group: _name,
                                tags: TrackTags(title: m.track.title, artist: m.track.artist, album: m.track.album),
                              );
                            }
                            Navigator.pop(context);
                          },
                    child: Text(ready.length == 1 ? 'Download 1 track' : 'Download ${ready.length} tracks'),
                  ),
                ]),
              ),
            ),
    );
  }
}

class _MatchTile extends StatelessWidget {
  final TrackMatch m;
  final VoidCallback onChanged;
  final VoidCallback onChange;
  const _MatchTile({required this.m, required this.onChanged, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final check = !m.searching && m.state == MatchState.check;
    final colour = m.searching
        ? c.muted
        : switch (m.state) {
            MatchState.good => c.good,
            MatchState.check => c.warn,
            MatchState.none => c.bad,
          };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: check ? BorderSide(color: c.warn, width: 2) : BorderSide.none,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(children: [
            Checkbox(
              value: m.selected,
              onChanged: m.pick == null
                  ? null
                  : (v) {
                      m.selected = v ?? false;
                      onChanged();
                    },
            ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${m.track.title} - ${m.track.artist}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(m.searching ? 'Searching YouTube...' : m.why,
                    maxLines: 4, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: colour)),
              ]),
            ),
            if (!m.searching) TextButton(onPressed: onChange, child: Text(m.candidates.isEmpty ? 'Search' : 'Change')),
          ]),
        ),
      ),
    );
  }
}
