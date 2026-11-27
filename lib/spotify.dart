import 'dart:convert';

import 'native.dart';

/// Spotify music is DRM protected, so Snag never downloads from Spotify.
/// It only reads the track names from a Spotify link, then finds the same
/// song on YouTube and downloads that instead.

class SpotifyLink {
  final String type; // playlist, album or track
  final String id;
  const SpotifyLink(this.type, this.id);
}

/// Reads open.spotify.com links (with or without the /intl-xx/ bit) and
/// spotify:playlist:... style links. Short spotify.link links are handled
/// in [loadSpotify] because they have to be looked up first.
SpotifyLink? parseSpotifyLink(String text) {
  final m = RegExp(r'(?:open\.spotify\.com/(?:intl-[a-z-]+/)?|spotify:)(playlist|album|track)[/:]([A-Za-z0-9]{10,})')
      .firstMatch(text);
  return m == null ? null : SpotifyLink(m[1]!, m[2]!);
}

bool isSpotify(String text) =>
    text.contains('spotify.com/') || text.contains('spotify.link/') || text.startsWith('spotify:');

class SpotifyTrack {
  final String title;
  final String artist; // all artists, comma separated
  final String album;
  final int seconds;
  const SpotifyTrack({required this.title, required this.artist, this.album = '', required this.seconds});

  /// The main artist only, which searches better than "A, B, C".
  String get firstArtist => artist.split(',').first.trim();
}

class SpotifyList {
  final String name;
  final List<SpotifyTrack> tracks;
  const SpotifyList(this.name, this.tracks);
}

/// Gets the name and tracks for a Spotify link. With a client ID and secret
/// set in Settings it uses Spotify's API, which handles playlists of any
/// size. Without them, or if the API refuses, it reads Spotify's public embed
/// page instead, which needs no account but may stop at 100 tracks.
Future<SpotifyList> loadSpotify(String text, {String clientId = '', String secret = ''}) async {
  var link = parseSpotifyLink(text);
  if (link == null) {
    final short = RegExp(r'https?://spotify\.link/\S+').firstMatch(text)?.group(0);
    if (short != null) {
      final res = await Native.fetch(Uri.parse(short)).timeout(const Duration(seconds: 15));
      link = parseSpotifyLink(res.body);
    }
  }
  if (link == null) throw 'That doesn\'t look like a Spotify playlist, album or track link.';

  if (clientId.isNotEmpty && secret.isNotEmpty) {
    try {
      return await _fromApi(link, clientId, secret);
    } catch (_) {
      // Fall through to the embed page below.
    }
  }
  final res = await Native.fetch(Uri.parse('https://open.spotify.com/embed/${link.type}/${link.id}'),
          headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36'})
      .timeout(const Duration(seconds: 20));
  if (res.statusCode != 200) throw 'Spotify said no (error ${res.statusCode}). Is the playlist public?';
  final list = parseEmbedPage(res.body);
  if (list == null || list.tracks.isEmpty) {
    throw 'Couldn\'t read the tracks from Spotify. Add a Spotify client ID and secret in Settings and try again.';
  }
  return list;
}

Future<SpotifyList> _fromApi(SpotifyLink link, String clientId, String secret) async {
  final auth = base64Encode(utf8.encode('$clientId:$secret'));
  final tokenRes = await Native.fetch(
    Uri.parse('https://accounts.spotify.com/api/token'),
    method: 'POST',
    headers: {'Authorization': 'Basic $auth', 'Content-Type': 'application/x-www-form-urlencoded'},
    body: 'grant_type=client_credentials',
  );
  if (tokenRes.statusCode != 200) throw 'Spotify didn\'t accept the client ID and secret';
  final token = jsonDecode(tokenRes.body)['access_token'] as String;
  final headers = {'Authorization': 'Bearer $token'};

  Future<Map<String, dynamic>> get(String url) async {
    final res = await Native.fetch(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw 'Spotify API error ${res.statusCode}';
    return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
  }

  final first = await get('https://api.spotify.com/v1/${link.type}s/${link.id}');
  if (link.type == 'track') return SpotifyList(first['name'] as String? ?? 'Track', [_apiTrack(first, '')]);

  final tracks = <SpotifyTrack>[];
  final album = link.type == 'album' ? first['name'] as String? ?? '' : '';
  // Playlists wrap each track in {track: ...}; albums don't. Playlists are
  // also moving from "tracks" to "items", so accept either.
  var page = Map<String, dynamic>.from((first['tracks'] ?? first['items'] ?? {}) as Map);
  while (true) {
    for (final item in (page['items'] as List? ?? [])) {
      final t = item is Map && (item['track'] ?? item['item']) is Map ? (item['track'] ?? item['item']) : item;
      if (t is Map && t['name'] != null) tracks.add(_apiTrack(Map<String, dynamic>.from(t), album));
    }
    final next = page['next'] as String?;
    if (next == null) break;
    page = await get(next);
  }
  return SpotifyList(first['name'] as String? ?? 'Spotify', tracks);
}

SpotifyTrack _apiTrack(Map<String, dynamic> t, String album) => SpotifyTrack(
      title: t['name'] as String,
      artist: (t['artists'] as List? ?? []).map((a) => (a as Map)['name']).join(', '),
      album: album.isNotEmpty ? album : ((t['album'] as Map?)?['name'] as String? ?? ''),
      seconds: ((t['duration_ms'] as num? ?? 0) / 1000).round(),
    );

/// Reads the track list out of the JSON Spotify puts inside its embed page.
SpotifyList? parseEmbedPage(String html) {
  final m = RegExp(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', dotAll: true).firstMatch(html);
  if (m == null) return null;
  try {
    final data = jsonDecode(m[1]!);
    final entity = data['props']['pageProps']['state']['data']['entity'] as Map;
    final name = (entity['name'] ?? entity['title'] ?? 'Spotify') as String;
    final list = entity['trackList'] as List?;
    if (list == null) {
      // A single track page.
      return SpotifyList(name, [
        SpotifyTrack(
          title: name,
          artist: (entity['artists'] as List? ?? []).map((a) => (a as Map)['name']).join(', '),
          seconds: ((entity['duration'] as num? ?? 0) / 1000).round(),
        )
      ]);
    }
    final isAlbum = entity['type'] == 'album';
    return SpotifyList(
      name,
      list
          .whereType<Map>()
          .map((t) => SpotifyTrack(
                title: t['title'] as String? ?? '',
                // The embed page lists artists as one line, e.g. "Toto" or "A, B".
                artist: (t['subtitle'] as String? ?? '').replaceAll(' ', ' '),
                album: isAlbum ? name : '',
                seconds: ((t['duration'] as num? ?? 0) / 1000).round(),
              ))
          .where((t) => t.title.isNotEmpty)
          .toList(),
    );
  } catch (_) {
    return null;
  }
}

class Candidate {
  final String id;
  final String title;
  final String channel;
  final int seconds;
  const Candidate({required this.id, required this.title, required this.channel, required this.seconds});

  String get url => 'https://www.youtube.com/watch?v=$id';
}

enum MatchState { good, check, none }

/// One Spotify track and the YouTube uploads found for it.
class TrackMatch {
  final SpotifyTrack track;
  List<Candidate> candidates = [];
  int chosen = -1;
  MatchState state = MatchState.none;
  bool selected = true;
  bool searching = true;
  String why = '';

  TrackMatch(this.track);

  Candidate? get pick => chosen >= 0 && chosen < candidates.length ? candidates[chosen] : null;
}

// Words that usually mean "not the studio version". Ignored if the Spotify
// title has them too (e.g. a live album).
const _otherVersions = [
  'live',
  'cover',
  'remix',
  'karaoke',
  'instrumental',
  'slowed',
  'sped up',
  'reverb',
  '8d',
  'nightcore',
  'acoustic',
  'lyrics video',
  'reaction',
  'tutorial',
  'lesson',
];

/// Works out which candidate is most likely the same recording and whether
/// it's worth a human checking. Length matters most: the same recording is
/// within a few seconds of Spotify's length.
({int index, MatchState state, String why}) pickBest(SpotifyTrack track, List<Candidate> found) {
  if (found.isEmpty) return (index: -1, state: MatchState.none, why: 'No match found');
  final wanted = track.title.toLowerCase();
  final artist = track.firstArtist.toLowerCase();

  double score(Candidate c) {
    final title = c.title.toLowerCase();
    final channel = c.channel.toLowerCase();
    var s = c.seconds > 0 && track.seconds > 0 ? (c.seconds - track.seconds).abs().toDouble() : 30.0;
    for (final w in _otherVersions) {
      if (RegExp('\\b$w\\b').hasMatch(title) && !wanted.contains(w)) s += 60;
    }
    // Official uploads: the artist's own channel or YouTube's "Artist - Topic" channels.
    if (channel.contains(artist) || channel.endsWith(' - topic')) s -= 5;
    if (!title.contains(wanted.split('(').first.trim())) s += 20;
    return s;
  }

  var best = 0;
  for (var i = 1; i < found.length; i++) {
    if (score(found[i]) < score(found[best])) best = i;
  }
  final c = found[best];
  final diff = c.seconds - track.seconds;
  final title = c.title.toLowerCase();
  final odd = _otherVersions.where((w) => RegExp('\\b$w\\b').hasMatch(title) && !wanted.contains(w)).firstOrNull;
  if (odd != null) return (index: best, state: MatchState.check, why: 'Check this - looks like a $odd version');
  if (track.seconds > 0 && c.seconds > 0 && diff.abs() > 10) {
    return (
      index: best,
      state: MatchState.check,
      why: 'Check this - ${mmss(diff.abs())} ${diff > 0 ? 'longer' : 'shorter'} than on Spotify',
    );
  }
  return (index: best, state: MatchState.good, why: 'Good match - ${mmss(c.seconds)}');
}

/// 185 seconds as 3:05.
String mmss(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

/// Searches YouTube through yt-dlp and returns the top results.
Future<List<Candidate>> searchYouTube(String query, {int count = 5}) async {
  final out = await Native.run(['--dump-single-json', '--flat-playlist', '--no-warnings', 'ytsearch$count:$query']);
  return parseSearch(out);
}

List<Candidate> parseSearch(String json) {
  if (json.trim().isEmpty) return [];
  final data = jsonDecode(json) as Map;
  return (data['entries'] as List? ?? [])
      .whereType<Map>()
      .where((e) => e['id'] != null)
      .map((e) => Candidate(
            id: e['id'] as String,
            title: e['title'] as String? ?? '',
            channel: (e['channel'] ?? e['uploader'] ?? '') as String,
            seconds: (e['duration'] as num? ?? 0).round(),
          ))
      .toList();
}
