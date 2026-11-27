import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'downloads.dart';
import 'home_ca.dart' if (dart.library.js_interop) 'home_ca_web.dart';
import 'native.dart';
import 'prefs.dart';
import 'screens/home.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  trustHomeCa((await rootBundle.load('assets/certs/adgoose-home-ca.crt')).buffer.asUint8List());
  Native.listen();
  final prefs = await Prefs.load();
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: prefs),
      ChangeNotifierProvider(create: (_) => Downloads(prefs)),
    ],
    child: const SnagApp(),
  ));
}

class SnagApp extends StatelessWidget {
  const SnagApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeId = context.select<Prefs, String>((p) => p.theme);
    // "Match phone" uses Lagoon by day and Midnight when the phone is in dark mode.
    final followPhone = themeId == 'system';
    return MaterialApp(
      title: 'Snag',
      debugShowCheckedModeBanner: false,
      theme: themeFor(followPhone ? 'lagoon' : themeId).build(),
      darkTheme: followPhone ? themeFor('midnight').build() : null,
      themeMode: ThemeMode.system,
      // On a wide PC window, keep the phone-style layout in a centred column.
      builder: (context, child) => ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: child)),
      ),
      home: const HomeScreen(),
    );
  }
}
