/// Stands in for desktop.dart in the web build, which can't start programs.
/// The web page uses pi.dart instead, so none of this is ever called.
class Desktop {
  static Never _no() => throw UnsupportedError('Not on the web');
  static Future<String> run(List<String> args) => _no();
  static Future<List<Map<String, dynamic>>> download(String id, String url, List<String> args, String folder,
          void Function(double percent, String detail) onProgress) =>
      _no();
  static Future<void> cancel(String id) => _no();
  static Future<String> version() => _no();
  static Future<String> update() => _no();
  static Future<void> open(String path) => _no();
}

String homeFolder(String folder) => '';
