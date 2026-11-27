import 'package:flutter_test/flutter_test.dart';
import 'package:snag/downloads.dart';
import 'package:snag/prefs.dart';

Options audio({String format = 'mp3', int bitrate = 320, bool art = true}) => Options(
      audio: true,
      audioFormat: format,
      audioBitrate: bitrate,
      embedArt: art,
      videoQuality: '1080',
      videoFormat: 'mp4',
      subtitles: false,
      subtitleLangs: 'en.*',
    );

Options video({String quality = '1080', String format = 'mp4', bool subs = false, String langs = 'en.*'}) => Options(
      audio: false,
      audioFormat: 'mp3',
      audioBitrate: 320,
      embedArt: true,
      videoQuality: quality,
      videoFormat: format,
      subtitles: subs,
      subtitleLangs: langs,
    );

/// The value straight after [flag] in an argument list.
String? after(List<String> args, String flag) {
  final i = args.indexOf(flag);
  return i < 0 || i + 1 >= args.length ? null : args[i + 1];
}

void main() {
  test('MP3 320 with cover art', () {
    final a = buildArgs(audio());
    expect(after(a, '--audio-format'), 'mp3');
    expect(after(a, '--audio-quality'), '320K');
    expect(a, contains('--embed-thumbnail'));
    expect(a, contains('--no-playlist'));
    expect(after(a, '-o'), '%(title).150B.%(ext)s');
  });

  test('FLAC has no bitrate and no cover art', () {
    final a = buildArgs(audio(format: 'flac'));
    expect(a, isNot(contains('--audio-quality')));
    expect(a, isNot(contains('--embed-thumbnail')));
  });

  test('Opus skips cover art, art switch off skips it for MP3 too', () {
    expect(buildArgs(audio(format: 'opus')), isNot(contains('--embed-thumbnail')));
    expect(buildArgs(audio(art: false)), isNot(contains('--embed-thumbnail')));
  });

  test('video quality limits and formats', () {
    expect(after(buildArgs(video()), '-S'), 'res:1080,vcodec:h264,acodec:m4a');
    expect(after(buildArgs(video(quality: 'best')), '-S'), 'res,vcodec:h264,acodec:m4a');
    final mkv = buildArgs(video(quality: '2160', format: 'mkv'));
    expect(after(mkv, '-S'), 'res:2160');
    expect(after(mkv, '--merge-output-format'), 'mkv');
    expect(mkv, isNot(contains('-x')));
  });

  test('subtitles only when asked, blank languages fall back to English', () {
    expect(buildArgs(video()), isNot(contains('--write-subs')));
    expect(after(buildArgs(video(subs: true, langs: 'en.*,mi')), '--sub-langs'), 'en.*,mi');
    expect(after(buildArgs(video(subs: true, langs: '')), '--sub-langs'), 'en.*');
  });

  test('whole playlist goes in its own folder', () {
    final o = audio()..playlist = true;
    final a = buildArgs(o);
    expect(a, contains('--yes-playlist'));
    expect(after(a, '-o'), startsWith('%(playlist_title)'));
  });

  test('Spotify tags replace the YouTube names, backslashes kept literal', () {
    final a = buildArgs(audio(), tags: const TrackTags(title: r'AC\DC Song', artist: 'Toto', album: 'IV'));
    final replaces = <String>[];
    for (var i = 0; i < a.length; i++) {
      if (a[i] == '--replace-in-metadata') replaces.add('${a[i + 1]}=${a[i + 3]}');
    }
    expect(replaces, [r'title=AC\\DC Song', 'artist=Toto', 'album=IV']);
    expect(after(a, '-o'), '%(artist).80B - %(title).120B.%(ext)s');
  });

  test('no album means no album replace', () {
    final a = buildArgs(audio(), tags: const TrackTags(title: 'A', artist: 'B'));
    expect(a.where((x) => x == 'album'), isEmpty);
  });

  test('labels', () {
    expect(audio().label, 'Audio MP3 320');
    expect(audio(format: 'flac').label, 'Audio FLAC');
    expect(video(quality: '2160', format: 'mkv').label, 'Video 4K MKV');
    expect(video(quality: 'best').label, 'Video Best MP4');
  });

  test('options survive a save and load', () {
    final o = video(quality: '720', subs: true)..playlist = true;
    final back = Options.fromJson(o.toJson());
    expect(back.toJson(), o.toJson());
    expect(Options.fromJson({}).audioFormat, 'mp3');
  });

  test('folder settings', () {
    expect(cleanFolder('music/Snag/', Prefs.audioRoots), 'Music/Snag');
    expect(cleanFolder(' Download \\ Snag ', Prefs.audioRoots), 'Download/Snag');
    expect(cleanFolder('Movies', Prefs.videoRoots), 'Movies');
    expect(cleanFolder('Documents/Snag', Prefs.audioRoots), isNull);
    expect(cleanFolder('Music/../Movies', Prefs.audioRoots), isNull);
    expect(cleanFolder('Music/a:b', Prefs.audioRoots), isNull);
    expect(cleanFolder('', Prefs.audioRoots), isNull);
    expect(cleanFolder('Movies/Snag', Prefs.audioRoots), isNull);
  });
}
