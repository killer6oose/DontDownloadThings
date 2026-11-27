import 'package:flutter/material.dart';

/// The colours for one Snag theme. Lagoon matches the mockup.
class SnagColours extends ThemeExtension<SnagColours> {
  final Color bg, card, ink, muted, accent, onAccent, ring, good, warn, bad;

  const SnagColours({
    required this.bg,
    required this.card,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.ring,
    required this.good,
    required this.warn,
    required this.bad,
  });

  @override
  SnagColours copyWith() => this;

  @override
  SnagColours lerp(SnagColours? other, double t) => t < 0.5 || other == null ? this : other;
}

class SnagTheme {
  final String id;
  final String name;
  final Brightness brightness;
  final SnagColours c;
  const SnagTheme(this.id, this.name, this.brightness, this.c);

  ThemeData build() {
    final scheme = ColorScheme.fromSeed(
      seedColor: c.accent,
      brightness: brightness,
      primary: c.accent,
      onPrimary: c.onAccent,
      surface: c.bg,
      onSurface: c.ink,
      error: c.bad,
    );
    final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(20));
    final ring =
        OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: c.ring, width: 2));
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'Fredoka',
      scaffoldBackgroundColor: c.bg,
      extensions: [c],
      appBarTheme: AppBarTheme(backgroundColor: c.bg, foregroundColor: c.ink, elevation: 0, scrolledUnderElevation: 0),
      cardTheme: CardThemeData(color: c.card, elevation: 0, margin: EdgeInsets.zero, shape: rounded),
      dialogTheme: DialogThemeData(backgroundColor: c.card, shape: rounded),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.card,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        showDragHandle: true,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: c.onAccent,
          minimumSize: const Size(48, 50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontFamily: 'Fredoka', fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.accent,
          backgroundColor: c.card,
          side: BorderSide(color: c.accent, width: 2),
          minimumSize: const Size(48, 50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontFamily: 'Fredoka', fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: c.accent)),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.card,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: ring,
        enabledBorder: ring,
        focusedBorder: ring.copyWith(borderSide: BorderSide(color: c.accent, width: 2)),
        labelStyle: TextStyle(color: c.muted),
        hintStyle: TextStyle(color: c.muted),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.card,
        selectedColor: c.accent,
        labelStyle: TextStyle(color: c.ink, fontFamily: 'Fredoka'),
        secondaryLabelStyle: TextStyle(color: c.onAccent, fontFamily: 'Fredoka'),
        side: BorderSide(color: c.ring, width: 2),
        shape: const StadiumBorder(),
        showCheckmark: false,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : null),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : null),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent, linearTrackColor: c.ring),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.ink,
        contentTextStyle: TextStyle(color: c.bg, fontFamily: 'Fredoka'),
      ),
    );
  }
}

const snagThemes = [
  SnagTheme(
    'lagoon',
    'Lagoon',
    Brightness.light,
    SnagColours(
      bg: Color(0xFFF3F8F7),
      card: Colors.white,
      ink: Color(0xFF17302F),
      muted: Color(0xFF4D6664),
      accent: Color(0xFF0B6E78),
      onAccent: Colors.white,
      ring: Color(0xFFD4E4E2),
      good: Color(0xFF1F7A3A),
      warn: Color(0xFF8A5A00),
      bad: Color(0xFFB3261E),
    ),
  ),
  SnagTheme(
    'berry',
    'Berry',
    Brightness.light,
    SnagColours(
      bg: Color(0xFFFBF3F6),
      card: Colors.white,
      ink: Color(0xFF3A1724),
      muted: Color(0xFF6E4B58),
      accent: Color(0xFFB03A62),
      onAccent: Colors.white,
      ring: Color(0xFFEFD6DF),
      good: Color(0xFF1F7A3A),
      warn: Color(0xFF8A5A00),
      bad: Color(0xFFB3261E),
    ),
  ),
  SnagTheme(
    'fern',
    'Fern',
    Brightness.light,
    SnagColours(
      bg: Color(0xFFF4F7EF),
      card: Colors.white,
      ink: Color(0xFF223015),
      muted: Color(0xFF55633F),
      accent: Color(0xFF4A7324),
      onAccent: Colors.white,
      ring: Color(0xFFDCE5CF),
      good: Color(0xFF1F7A3A),
      warn: Color(0xFF8A5A00),
      bad: Color(0xFFB3261E),
    ),
  ),
  SnagTheme(
    'midnight',
    'Midnight (dark)',
    Brightness.dark,
    SnagColours(
      bg: Color(0xFF0F1A1C),
      card: Color(0xFF1A2A2D),
      ink: Color(0xFFE6F1EF),
      muted: Color(0xFFA3B8B5),
      accent: Color(0xFF4FC3C9),
      onAccent: Color(0xFF062326),
      ring: Color(0xFF2C4245),
      good: Color(0xFF7BD88F),
      warn: Color(0xFFF0C26B),
      bad: Color(0xFFFF8A80),
    ),
  ),
];

SnagTheme themeFor(String id) {
  return snagThemes.firstWhere((t) => t.id == id, orElse: () => snagThemes.first);
}

extension SnagContext on BuildContext {
  SnagColours get c => Theme.of(this).extension<SnagColours>()!;
}
