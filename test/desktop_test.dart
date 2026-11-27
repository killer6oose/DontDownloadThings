// Runs the PC download path against a real yt-dlp, if one is installed.
// Skipped otherwise. Needs a test page served on 127.0.0.1:8765 (see SETUP.md).
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snag/desktop.dart';
import 'package:snag/downloads.dart';

import 'args_test.dart' as a;

void main() {
  final page = Platform.environment['SNAG_TEST_PAGE'];
  test('download through yt-dlp.exe style path', () async {
    final folder = Directory.systemTemp.createTempSync('snagtest');
    final progress = <double>[];
    final files = await Desktop.download('t1', page!, buildArgs(a.audio()), folder.path, (p, _) => progress.add(p));
    expect(files.single['name'], endsWith('.mp3'));
    expect(File(files.single['path'] as String).existsSync(), isTrue);
    expect(progress, isNotEmpty);
    expect(progress.last, 100);
    folder.deleteSync(recursive: true);
  }, skip: page == null ? 'Set SNAG_TEST_PAGE to run' : false);

  test('a bad link fails with yt-dlp\'s error', () async {
    final folder = Directory.systemTemp.createTempSync('snagtest');
    await expectLater(
      Desktop.download('t2', 'http://127.0.0.1:9/nothing', buildArgs(a.audio()), folder.path, (_, __) {}),
      throwsA(isA<PlatformException>().having((e) => e.message, 'message', contains('ERROR'))),
    );
  }, skip: page == null ? 'Set SNAG_TEST_PAGE to run' : false);
}
