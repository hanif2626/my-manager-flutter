import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// ── "Ink & Paper" design system ──────────────────────────────────
/// Neutral-first, single-accent. Color is not used to carry meaning —
/// status, priority, and project identity are all conveyed through icon
/// shape, weight, and typography instead of hue. The only color besides
/// the accent is `danger`, reserved for destructive actions (delete),
/// which is a near-universal safety convention rather than a "meaning".
class AppTheme {
  // ── Light ──────────────────────────────────────────
  static const _lightBg      = Color(0xFFF7F7F8);
  static const _lightSurface = Color(0xFFFFFFFF);
  static const _lightSurface2= Color(0xFFF0F0F2);
  static const _lightBorder  = Color(0xFFE4E4E8);
  static const _lightInk     = Color(0xFF16161A);
  static const _lightInk2    = Color(0xFF5C5C66);
  static const _lightInk3    = Color(0xFF9A9AA5);

  // ── Dark ───────────────────────────────────────────
  static const _darkBg       = Color(0xFF121214);
  static const _darkSurface  = Color(0xFF1C1C20);
  static const _darkSurface2 = Color(0xFF26262B);
  static const _darkBorder   = Color(0xFF303036);
  static const _darkInk      = Color(0xFFF2F2F5);
  static const _darkInk2     = Color(0xFFA8A8B3);
  static const _darkInk3     = Color(0xFF6E6E78);

  // ── Project design (light grey + matching dark) ──────────
  // Demo-approved palette: light page is soft grey, cards a touch
  // lighter; dark page/card match the dark theme's bg/surface.
  static const _lightPage = Color(0xFFE8EAED);
  static const _lightCard = Color(0xFFF7F8F9);
  static const _darkPage  = Color(0xFF121214);
  static const _darkCard  = Color(0xFF1C1C20);

  static const accent = Color(0xFF4F46E5); // single accent — primary actions only
  static const danger = Color(0xFFDC4C4C); // destructive actions only
  // Universal feedback colors — success/warning/error. These are a
  // different thing from "color-coding meaning" (status, priority,
  // project identity, which deliberately stay neutral everywhere else).
  // A success snackbar being green, or a recording dot being amber, is a
  // near-universal UI convention independent of that — same category as
  // the delete button staying red.
  static const _lightSuccess = Color(0xFF15803D);
  static const _darkSuccess  = Color(0xFF4ADE80);
  static const _lightWarning = Color(0xFFB45309);
  static const _darkWarning  = Color(0xFFFBBF24);
  static const neutralAvatar = Color(0xFF5C5C66); // project monogram circles

  static bool _isDarkMode = false;

  // Semantic getters that resolve against whichever mode is active —
  // lets existing `AppTheme.bg` / `AppTheme.textPrimary` call sites
  // keep working without hunting down every reference.
  static Color get bg => _isDarkMode ? _darkBg : _lightBg;
  static Color get bg2 => _isDarkMode ? _darkSurface : _lightSurface;
  static Color get bg3 => _isDarkMode ? _darkSurface2 : _lightSurface2;
  static Color get bg4 => _isDarkMode ? _darkSurface2 : _lightSurface2;
  static Color get page => _isDarkMode ? _darkPage : _lightPage;
  static Color get card => _isDarkMode ? _darkCard : _lightCard;
  static Color get border => _isDarkMode ? _darkBorder : _lightBorder;
  static Color get textPrimary => _isDarkMode ? _darkInk : _lightInk;
  static Color get textSecondary => _isDarkMode ? _darkInk2 : _lightInk2;
  static Color get textMuted => _isDarkMode ? _darkInk3 : _lightInk3;

  // Kept for any old call sites that still reference these names — now
  // genuine feedback colors (success/warning), not neutral placeholders.
  static Color get green => _isDarkMode ? _darkSuccess : _lightSuccess;
  static Color get yellow => _isDarkMode ? _darkWarning : _lightWarning;
  static Color get red => danger;
  static Color get tape => bg3;

  /// Project identity is now a neutral monogram, not a color swatch.
  static const projectColors = [neutralAvatar];

  // বাংলা ফন্ট: Noto Sans Bengali — সংখ্যা (বিশেষ করে ১) ও যুক্তাক্ষর স্পষ্ট। আগে Hind Siliguri ছিল,
  // যাতে ১ দেখতে অদ্ভুত লাগত। বদলাতে চাইলে নিচের চারটা জায়গার নাম একসাথে বদলাও (যেমন anekBangla, mukta)।
  static TextTheme _textTheme(Brightness b) =>
      GoogleFonts.notoSansBengaliTextTheme(
        b == Brightness.dark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
      );

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    _isDarkMode = brightness == Brightness.dark;
    final bgColor = _isDarkMode ? _darkBg : _lightBg;
    final surface = _isDarkMode ? _darkSurface : _lightSurface;
    final ink = _isDarkMode ? _darkInk : _lightInk;
    final ink2 = _isDarkMode ? _darkInk2 : _lightInk2;
    final borderColor = _isDarkMode ? _darkBorder : _lightBorder;

    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: bgColor,
      colorScheme: (_isDarkMode ? const ColorScheme.dark() : const ColorScheme.light())
          .copyWith(primary: accent, surface: surface, error: danger),
      appBarTheme: AppBarTheme(
        backgroundColor: bgColor, elevation: 0, scrolledUnderElevation: 0,
        titleTextStyle: GoogleFonts.notoSansBengali(
            color: ink, fontSize: 18, fontWeight: FontWeight.w700),
        iconTheme: IconThemeData(color: ink2),
      ),
      cardTheme: CardTheme(
        color: surface,
        elevation: _isDarkMode ? 0 : 1,
        shadowColor: Colors.black.withOpacity(0.06),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: _isDarkMode ? BorderSide(color: borderColor) : BorderSide.none,
        ),
        margin: EdgeInsets.zero,
      ),
      dividerColor: borderColor,
      textTheme: _textTheme(brightness),
      fontFamily: GoogleFonts.notoSansBengali().fontFamily,
    );
  }

  // ── Typography scale — 4 levels, use consistently ────────────────
  static TextStyle display({double size = 22, FontWeight weight = FontWeight.w800, Color? color}) =>
      GoogleFonts.notoSansBengali(fontSize: size, fontWeight: weight, color: color ?? textPrimary);
  static TextStyle title({double size = 16, FontWeight weight = FontWeight.w700, Color? color}) =>
      GoogleFonts.notoSansBengali(fontSize: size, fontWeight: weight, color: color ?? textPrimary);
  static TextStyle body({double size = 14, FontWeight weight = FontWeight.w400, Color? color}) =>
      GoogleFonts.notoSansBengali(fontSize: size, fontWeight: weight, color: color ?? textSecondary);
  static TextStyle caption({double size = 12, FontWeight weight = FontWeight.w500, Color? color}) =>
      GoogleFonts.notoSansBengali(fontSize: size, fontWeight: weight, color: color ?? textMuted);
}

/// Status conveyed by icon *shape*, not color — every state uses the same
/// neutral tone (kept as a real Color, not just for show, since some
/// screens still expect a `color` field here for borders/backgrounds).
const statusConfig = {
  'todo':  {'label': 'বাকি',  'icon': Icons.radio_button_unchecked, 'color': Color(0xFF6E6E78)},
  'doing': {'label': 'চলছে', 'icon': Icons.incomplete_circle_outlined, 'color': Color(0xFF6E6E78)},
  'done':  {'label': 'শেষ',  'icon': Icons.check_circle, 'color': Color(0xFF6E6E78)},
};

/// Priority conveyed by icon *fill level*, not color — same neutral tone
/// across all levels, kept for backward-compatible `color` access.
const priorityConfig = {
  'low':    {'label': 'কম',    'icon': Icons.signal_cellular_alt_1_bar, 'color': Color(0xFF6E6E78)},
  'medium': {'label': 'মাঝারি', 'icon': Icons.signal_cellular_alt_2_bar, 'color': Color(0xFF6E6E78)},
  'high':   {'label': 'জরুরি', 'icon': Icons.signal_cellular_alt, 'color': Color(0xFF6E6E78)},
};

int now() => DateTime.now().millisecondsSinceEpoch;
