import 'package:web/web.dart' as web;

/// Hands a file to the browser to save, the same as clicking a download link.
void saveFromUrl(String url, String name) {
  final link = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  web.document.body!.append(link);
  link.click();
  link.remove();
}
