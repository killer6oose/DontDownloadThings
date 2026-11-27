import 'dart:io';

/// hub.adgoose (and the other family sites) use https certificates from the
/// ADGoose Home CA, which phones and PCs don't know about. This adds it to the
/// certificates Snag trusts, on top of the normal ones.
void trustHomeCa(List<int> pem) => HttpOverrides.global = _HomeCa(pem);

class _HomeCa extends HttpOverrides {
  _HomeCa(this.pem);
  final List<int> pem;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(SecurityContext(withTrustedRoots: true)..setTrustedCertificatesBytes(pem));
}
