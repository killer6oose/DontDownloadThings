import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:snag/home_ca.dart';

// Needs a local https server signed by a test CA: see SNAG_TEST_CA.
void main() {
  final ca = Platform.environment['SNAG_TEST_CA'];
  test('trusts the home CA on top of the normal ones', () async {
    final url = Uri.parse('https://localhost:8443/snag_version.txt');
    await expectLater(http.get(url), throwsA(isA<HandshakeException>()));
    trustHomeCa(File(ca!).readAsBytesSync());
    expect((await http.get(url)).body.trim(), '1.2.3+4');
  }, skip: ca == null ? 'Set SNAG_TEST_CA to run' : false);
}
