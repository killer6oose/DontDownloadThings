import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'native.dart';
import 'prefs.dart';

/// What to download and how. Starts from the Settings defaults and can be
/// changed on the options sheet for one download.
class Options {
  bool audio;
  String audioFormat;
  int audioBitrate;
  bool embedArt;
  String videoQuality;
  String videoFormat;
  bool subtitles;
  String subtitleLangs;
  bool playlist;

  Options({
    required this.audio,
    required this.audioFormat,
    required this.audioBitrate,
    required this.embedArt,
    required this.videoQuality,
    required this.videoFormat,
    required this.subtitles,
    required this.subtitleLangs,
    this.playlist = false,
  });

  factory Options.fromPrefs(Prefs p, {required bool audio}) => Options(
        audio: audio,
        audioFormat: p.audioFormat,
        audioBitrate: p.audioBitrate,
        embedArt: p.embedArt,
        videoQuality: p.videoQuality,
        videoFormat: p.videoFormat,
        subtitles: p.subtitles,
        subtitleLangs: p.subtitleLangs,
      );

  Map<String, dynamic> toJson() => {
        'audio': audio,
        'audioFormat': audioFormat,
        'audioBitrate': audioBitrate,
        'embedArt': embedArt,
        'videoQuality': videoQuality,
        'videoFormat': videoFormat,
        'subtitles': subtitles,
        'subtitleLangs': subtitleLangs,
        'playlist': playlist,
      };

  factory Options.fromJson(Map<String, dynamic> j) => Options(
        audio: j['audio'] as bool? ?? true,
        audioFormat: j['audioFormat'] as String? ?? 'mp3',
        audioBitrate: j['audioBitrate'] as int? ?? 320,
        embedArt: j['embedArt'] as bool? ?? true,
        videoQuality: j['videoQuality'] as String? ?? '1080',
        videoFormat: j['videoFormat'] as String? ?? 'mp4',
        subtitles: j['subtitles'] as bool? ?? false,
        subtitleLangs: j['subtitleLangs'] as String? ?? 'en.*',
        playlist: j['playlist'] as bool? ?? false,
      );

  /// Short description for the queue and history, e.g. "Audio MP3 320".
  String get label {
    if (audio) {
      final f = audioFormat.toUpperCase();
      return audioFormat == 'flac' ? 'Audio $f' : 'Audio $f $audioBitrate';
    }
    final q = videoQuality == 'best'
        ? 'Best'
        : videoQuality == '2160'
            ? '4K'
            : '${videoQuality}p';
    return 'Video $q ${videoFormat.toUpperCase()}';
  }
}

/// Track details from Spotify, written into the file's tags instead of
/// whatever the YouTube upload was called.
class TrackTags {
  final String title;
  final String artist;
  final String album;
  const TrackTags({required this.title, required this.artist, this.album = ''});

  Map<String, dynamic> toJson() => {'title': title, 'artist': artist, 'album': album};
  factory TrackTags.fromJson(Map<String, dynamic> j) =>
      TrackTags(title: j['title'] as String, artist: j['artist'] as String, album: j['album'] as String? ?? '');
}

/// The yt-dlp options for one download. Kept apart from the queue so the
/// tests can check exactly what yt-dlp gets told.
List<String> buildArgs(Options o, {TrackTags? tags}) {
  final args = <String>[
    '--no-mtime',
    // Swaps characters like : and ? for look-alikes so every file name is valid.
    '--windows-filenames',
    o.playlist ? '--yes-playlist' : '--no-playlist',
  ];

  if (o.audio) {
    args.addAll(['-f', 'ba/b', '-x', '--audio-format', o.audioFormat, '--embed-metadata']);
    // FLAC is lossless so a bitrate means nothing there.
    if (o.audioFormat != 'flac') args.addAll(['--audio-quality', '${o.audioBitrate}K']);
    // Cover art only goes into MP3 and M4A. Opus and FLAC need an extra
    // Python module the Android build of yt-dlp doesn't have.
    if (o.embedArt && (o.audioFormat == 'mp3' || o.audioFormat == 'm4a')) {
      args.addAll([
        '--embed-thumbnail',
        '--convert-thumbnails', 'jpg',
        // Crops the 16:9 video thumbnail to a square, like album art.
        '--ppa', 'ThumbnailsConvertor:-qmin 1 -q:v 1 -vf crop="\'if(gt(ih,iw),iw,ih)\':\'if(gt(iw,ih),ih,iw)\'"',
      ]);
    }
  } else {
    // Largest resolution up to the chosen limit. For MP4, prefer H.264 video
    // and AAC audio because every phone and TV plays them.
    final res = o.videoQuality == 'best' ? 'res' : 'res:${o.videoQuality}';
    args.addAll([
      '-f',
      'bv*+ba/b',
      '-S',
      o.videoFormat == 'mp4' ? '$res,vcodec:h264,acodec:m4a' : res,
      '--merge-output-format',
      o.videoFormat,
      '--remux-video',
      o.videoFormat,
      '--embed-metadata',
    ]);
    if (o.subtitles) {
      args.addAll(['--write-subs', '--sub-langs', o.subtitleLangs.isEmpty ? 'en.*' : o.subtitleLangs, '--embed-subs']);
    }
  }

  if (tags != null) {
    // Copy the title into artist and album first so those fields exist, then
    // overwrite all three with Spotify's names.
    String literal(String s) => s.replaceAll('\\', '\\\\');
    args.addAll(['--parse-metadata', 'title:(?P<artist>.*)', '--parse-metadata', 'title:(?P<album>.*)']);
    args.addAll(['--replace-in-metadata', 'title', r'(?s)^.*$', literal(tags.title)]);
    args.addAll(['--replace-in-metadata', 'artist', r'(?s)^.*$', literal(tags.artist)]);
    if (tags.album.isNotEmpty) args.addAll(['--replace-in-metadata', 'album', r'(?s)^.*$', literal(tags.album)]);
    args.addAll(['-o', '%(artist).80B - %(title).120B.%(ext)s']);
  } else if (o.playlist) {
    args.addAll(['-o', '%(playlist_title).80B/%(playlist_index)03d - %(title).150B.%(ext)s']);
  } else {
    args.addAll(['-o', '%(title).150B.%(ext)s']);
  }
  return args;
}

enum JobState { queued, running, done, failed, cancelled }

class Job {
  final String id;
  final String url;
  String title;
  final String? group; // e.g. the Spotify playlist it came from
  final Options options;
  final TrackTags? tags;
  final DateTime created;
  JobState state;
  double progress = 0; // 0 to 100
  String detail = '';
  String error;
  List<Map<String, dynamic>> files;

  Job({
    required this.id,
    required this.url,
    required this.title,
    required this.options,
    this.group,
    this.tags,
    DateTime? created,
    this.state = JobState.queued,
    this.error = '',
    List<Map<String, dynamic>>? files,
  })  : created = created ?? DateTime.now(),
        files = files ?? [];

  int get bytes => files.fold(0, (sum, f) => sum + ((f['size'] as num?)?.toInt() ?? 0));

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'title': title,
        'group': group,
        'options': options.toJson(),
        'tags': tags?.toJson(),
        'created': created.toIso8601String(),
        'state': state.name,
        'error': error,
        'files': files,
      };

  factory Job.fromJson(Map<String, dynamic> j) => Job(
        id: j['id'] as String,
        url: j['url'] as String,
        title: j['title'] as String? ?? '',
        group: j['group'] as String?,
        options: Options.fromJson(Map<String, dynamic>.from(j['options'] as Map)),
        tags: j['tags'] == null ? null : TrackTags.fromJson(Map<String, dynamic>.from(j['tags'] as Map)),
        created: DateTime.tryParse(j['created'] as String? ?? ''),
        state: JobState.values.firstWhere((s) => s.name == j['state'], orElse: () => JobState.failed),
        error: j['error'] as String? ?? '',
        files: (j['files'] as List? ?? []).map((f) => Map<String, dynamic>.from(f as Map)).toList(),
      );
}

/// The download queue and history. Two downloads run at once; the rest wait.
class Downloads extends ChangeNotifier {
  static const _maxRunning = 2;
  static const _historyKey = 'history';
  static const _historyLimit = 300;

  final Prefs prefs;
  final List<Job> active = [];
  final List<Job> history = [];

  Downloads(this.prefs) {
    final saved = prefs.raw.getString(_historyKey);
    if (saved != null) {
      try {
        history.addAll((jsonDecode(saved) as List).map((j) => Job.fromJson(Map<String, dynamic>.from(j as Map))));
      } catch (_) {
        // A damaged history isn't worth crashing over. Start a fresh one.
      }
    }
  }

  int _counter = 0;

  void add(String url, String title, Options options, {String? group, TrackTags? tags}) {
    final id = '${DateTime.now().millisecondsSinceEpoch}-${_counter++}';
    active.add(Job(id: id, url: url, title: title, options: options, group: group, tags: tags));
    notifyListeners();
    _next();
  }

  void retry(Job old) {
    history.remove(old);
    _saveHistory();
    add(old.url, old.title, old.options, group: old.group, tags: old.tags);
  }

  Future<void> cancel(Job job) async {
    if (job.state == JobState.queued) {
      job.state = JobState.cancelled;
      _finish(job);
      return;
    }
    await Native.cancel(job.id);
  }

  void removeFromHistory(Job job) {
    history.remove(job);
    _saveHistory();
    notifyListeners();
  }

  void clearHistory() {
    history.clear();
    _saveHistory();
    notifyListeners();
  }

  void _next() {
    while (active.where((j) => j.state == JobState.running).length < _maxRunning) {
      final job = active.where((j) => j.state == JobState.queued).firstOrNull;
      if (job == null) return;
      _run(job);
    }
  }

  Future<void> _run(Job job) async {
    job.state = JobState.running;
    notifyListeners();
    try {
      job.files = await Native.download(
        job.id,
        job.url,
        buildArgs(job.options, tags: job.tags),
        job.options.audio ? prefs.audioFolder : prefs.videoFolder,
        (percent, detail) {
          if (percent >= 0) job.progress = percent;
          if (detail.isNotEmpty) job.detail = detail;
          notifyListeners();
        },
      );
      job.state = JobState.done;
      // Use the real file name when we only had the link to go on.
      if (job.files.length == 1 && (job.title.isEmpty || job.title == job.url)) {
        job.title = (job.files.first['name'] as String).replaceFirst(RegExp(r'\.[^.]+$'), '');
      }
    } on PlatformException catch (e) {
      job.state = e.code == 'cancelled' ? JobState.cancelled : JobState.failed;
      job.error = e.message ?? 'Something went wrong';
    } catch (e) {
      job.state = JobState.failed;
      job.error = e.toString();
    }
    _finish(job);
  }

  void _finish(Job job) {
    active.remove(job);
    history.insert(0, job);
    if (history.length > _historyLimit) history.removeRange(_historyLimit, history.length);
    _saveHistory();
    notifyListeners();
    _next();
  }

  void _saveHistory() => prefs.raw.setString(_historyKey, jsonEncode(history.map((j) => j.toJson()).toList()));
}
