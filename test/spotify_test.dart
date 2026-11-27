import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:snag/native.dart';
import 'package:snag/spotify.dart';
import 'package:snag/widgets/update_dialog.dart';

const sun = SpotifyTrack(title: 'Here Comes the Sun', artist: 'The Beatles', seconds: 185);

Candidate cand(String title, int seconds, {String channel = 'Someone'}) =>
    Candidate(id: title.hashCode.toString(), title: title, channel: channel, seconds: seconds);

void main() {
  test('Spotify links', () {
    final a = parseSpotifyLink('https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc123');
    expect([a!.type, a.id], ['playlist', '37i9dQZF1DXcBWIGoYBM5M']);
    final b = parseSpotifyLink('Listen: https://open.spotify.com/intl-de/album/4aawyAB9vmqN3uQ7FjRGTy');
    expect([b!.type, b.id], ['album', '4aawyAB9vmqN3uQ7FjRGTy']);
    final c = parseSpotifyLink('spotify:track:6dGnYIeXmHdcikdzNNDMm2');
    expect([c!.type, c.id], ['track', '6dGnYIeXmHdcikdzNNDMm2']);
    expect(parseSpotifyLink('https://open.spotify.com/artist/abc'), isNull);
    expect(parseSpotifyLink('https://youtube.com/watch?v=x'), isNull);
    expect(isSpotify('https://spotify.link/AbCdEf'), isTrue);
    expect(isSpotify('https://youtu.be/abc'), isFalse);
  });

  test('embed page playlist', () {
    final data = {
      'props': {
        'pageProps': {
          'state': {
            'data': {
              'entity': {
                'type': 'playlist',
                'name': 'Road Trip',
                'trackList': [
                  {'title': 'Africa', 'subtitle': 'Toto', 'duration': 295000},
                  {'title': 'Mr. Blue Sky', 'subtitle': 'Electric Light Orchestra', 'duration': 303000},
                  {'title': '', 'subtitle': 'Nobody'},
                  'junk',
                ],
              }
            }
          }
        }
      }
    };
    final html = '<html><script id="__NEXT_DATA__" type="application/json">${jsonEncode(data)}</script></html>';
    final list = parseEmbedPage(html)!;
    expect(list.name, 'Road Trip');
    expect(list.tracks.map((t) => t.title), ['Africa', 'Mr. Blue Sky']);
    expect(list.tracks.first.seconds, 295);
    expect(list.tracks.first.album, '');
  });

  test('embed page single track, and pages that are not embed pages', () {
    final data = {
      'props': {
        'pageProps': {
          'state': {
            'data': {
              'entity': {
                'type': 'track',
                'name': 'Africa',
                'artists': [
                  {'name': 'Toto'}
                ],
                'duration': 295000,
              }
            }
          }
        }
      }
    };
    final list = parseEmbedPage('<script id="__NEXT_DATA__" type="application/json">${jsonEncode(data)}</script>')!;
    expect(list.tracks.single.artist, 'Toto');
    expect(parseEmbedPage('<html>nothing here</html>'), isNull);
    expect(parseEmbedPage('<script id="__NEXT_DATA__" type="application/json">{"props":{}}</script>'), isNull);
    expect(parseEmbedPage('<script id="__NEXT_DATA__" type="application/json">not json</script>'), isNull);
  });

  test('picks the studio version over a live one', () {
    final r = pickBest(sun, [
      cand('The Beatles - Here Comes the Sun (Live at Shea)', 186),
      cand('Here Comes The Sun (Remastered 2009)', 186, channel: 'The Beatles - Topic'),
    ]);
    expect(r.index, 1);
    expect(r.state, MatchState.good);
  });

  test('flags a match whose length is well off', () {
    final r = pickBest(sun, [cand('Here Comes the Sun', 230)]);
    expect(r.state, MatchState.check);
    expect(r.why, contains('0:45 longer'));
  });

  test('flags a cover when it is the only result', () {
    final r = pickBest(sun, [cand('Here Comes the Sun - acoustic cover', 185)]);
    expect(r.state, MatchState.check);
  });

  test('live is fine when the Spotify track is live too', () {
    const live = SpotifyTrack(title: 'Africa (Live)', artist: 'Toto', seconds: 300);
    expect(pickBest(live, [cand('Toto - Africa (Live)', 302)]).state, MatchState.good);
  });

  test('no results', () {
    final r = pickBest(sun, []);
    expect(r.index, -1);
    expect(r.state, MatchState.none);
  });

  test('search results from yt-dlp', () {
    final out = jsonEncode({
      'entries': [
        {'id': 'abc', 'title': 'Song', 'channel': 'Band', 'duration': 200.0},
        {'id': 'def', 'title': 'Song 2', 'uploader': 'Other'},
        {'title': 'no id'},
      ]
    });
    final r = parseSearch(out);
    expect(r.map((c) => c.id), ['abc', 'def']);
    expect(r[1].channel, 'Other');
    expect(r[1].seconds, 0);
    expect(r[0].url, 'https://www.youtube.com/watch?v=abc');
    expect(parseSearch(''), isEmpty);
  });

  test('finds the link in shared text', () {
    expect(findLink('Check this out https://youtu.be/abc?si=1 cheers'), 'https://youtu.be/abc?si=1');
    expect(findLink('no link'), isNull);
  });

  test('times', () {
    expect(mmss(185), '3:05');
    expect(mmss(0), '0:00');
  });

  test('version compare for self-update', () {
    expect(isNewerVersion('1.0.1+2', '1.0.0+1'), isTrue);
    expect(isNewerVersion('1.0.0+2', '1.0.0+1'), isTrue);
    expect(isNewerVersion('1.0.0', '1.0.0+1'), isFalse);
    expect(isNewerVersion('0.9.9+9', '1.0.0+1'), isFalse);
  });
}
