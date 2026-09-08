import 'package:flutter/material.dart';

/// Consistent spacing scale. Use these instead of ad-hoc EdgeInsets values so
/// vertical rhythm stays the same across screens.
class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Corner radii. Cards and sheets use [lg]; buttons and inputs use [md].
class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double pill = 999;
}

/// The single source of truth for colour, type and component styling.
///
/// Green is the brand and action colour — it belongs on primary buttons,
/// active states and branding, not on whole surfaces. Everything else sits on
/// white/neutral so the green stays meaningful.
class AppTheme {
  // ── Brand ──────────────────────────────────────────────────────────────
  static const Color primaryGreen = Color(0xFF319F43);
  static const Color primaryGreenDark = Color(0xFF25792F);
  static const Color primaryGreenLight = Color(0xFF5CBB6C);

  /// Reserved for informational accents (maps, tracking, links).
  static const Color primaryBlue = Color(0xFF1565C0);

  // ── Status ─────────────────────────────────────────────────────────────
  // Status must never be communicated by colour alone — pair these with an
  // icon or text label.
  static const Color success = Color(0xFF2E7D32);
  static const Color warning = Color(0xFFE58900);
  static const Color errorRed = Color(0xFFD32F2F);
  static const Color info = Color(0xFF1565C0);

  // ── Light neutrals ─────────────────────────────────────────────────────
  static const Color white = Colors.white;
  static const Color backgroundGray = Color(0xFFF5F6F7);
  static const Color surfaceLight = Colors.white;
  static const Color borderLight = Color(0xFFE2E5E9);
  static const Color textPrimaryLight = Color(0xFF1A1C1E);
  static const Color textSecondaryLight = Color(0xFF5B6169);
  static const Color textTertiaryLight = Color(0xFF8A9099);

  // ── Dark neutrals ──────────────────────────────────────────────────────
  static const Color backgroundDark = Color(0xFF121212);
  static const Color surfaceDark = Color(0xFF1E1E1E);
  static const Color borderDark = Color(0xFF33383D);
  static const Color textPrimaryDark = Color(0xFFECEDEE);
  static const Color textSecondaryDark = Color(0xFFA8AEB5);
  static const Color textTertiaryDark = Color(0xFF7C838B);

  /// Const-safe muted text colour, usable inside `const` widgets where the
  /// context-aware helpers below cannot be called.
  ///
  /// Chosen to balance both themes: 4.8:1 on white (passes WCAG AA for normal
  /// text, where the previous `Colors.grey` failed at 2.9:1) and 4.2:1 on the
  /// dark surface. Prefer [secondaryText] when a BuildContext is available.
  static const Color textMuted = Color(0xFF6B7280);

  /// Muted secondary text for the current brightness. Replaces scattered
  /// `Colors.grey` usages so contrast stays correct in dark mode.
  static Color secondaryText(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? textSecondaryDark
      : textSecondaryLight;

  /// Even lower-emphasis text (hints, timestamps, captions).
  static Color tertiaryText(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? textTertiaryDark
      : textTertiaryLight;

  /// Hairline borders and dividers for the current brightness.
  static Color border(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? borderDark
      : borderLight;

  static TextTheme _textTheme(Color primary, Color secondary) {
    return TextTheme(
      headlineLarge: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.bold,
        color: primary,
      ),
      headlineMedium: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.bold,
        color: primary,
      ),
      headlineSmall: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: primary,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: primary,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: primary,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: primary,
      ),
      bodyLarge: TextStyle(fontSize: 16, color: primary),
      bodyMedium: TextStyle(fontSize: 14, color: primary),
      bodySmall: TextStyle(fontSize: 13, color: secondary),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: primary,
      ),
      labelMedium: TextStyle(fontSize: 12, color: secondary),
      labelSmall: TextStyle(fontSize: 11, color: secondary),
    );
  }

  static ThemeData _base({
    required Brightness brightness,
    required Color scaffold,
    required Color surface,
    required Color borderColor,
    required Color textPrimary,
    required Color textSecondary,
    required Color appBarBg,
  }) {
    final isDark = brightness == Brightness.dark;
    final outlineBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      borderSide: BorderSide(color: borderColor),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      primaryColor: primaryGreen,
      scaffoldBackgroundColor: scaffold,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: primaryGreen,
            brightness: brightness,
          ).copyWith(
            primary: primaryGreen,
            surface: surface,
            error: errorRed,
          ),
      textTheme: _textTheme(textPrimary, textSecondary),
      appBarTheme: AppBarTheme(
        backgroundColor: appBarBg,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(color: borderColor),
        ),
      ),
      dividerTheme: DividerThemeData(color: borderColor, thickness: 1),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: primaryGreen.withValues(alpha: isDark ? 0.3 : 0.12),
        elevation: 0,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: primaryGreen,
        unselectedItemColor: textSecondary,
        type: BottomNavigationBarType.fixed,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryGreen,
          foregroundColor: Colors.white,
          disabledBackgroundColor: isDark
              ? const Color(0xFF2C2F33)
              : const Color(0xFFDDE1E5),
          disabledForegroundColor: textSecondary,
          elevation: 0,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.md,
            horizontal: AppSpacing.xl,
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryGreen,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.md,
            horizontal: AppSpacing.xl,
          ),
          side: const BorderSide(color: primaryGreen),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primaryGreen,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: outlineBorder,
        enabledBorder: outlineBorder,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: primaryGreen, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: errorRed),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: errorRed, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.lg,
        ),
        prefixIconColor: textSecondary,
        labelStyle: TextStyle(color: textSecondary),
        hintStyle: TextStyle(color: textSecondary),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: textPrimary,
        ),
        contentTextStyle: TextStyle(fontSize: 14, color: textPrimary),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? const Color(0xFF2C2F33) : textPrimaryLight,
        contentTextStyle: const TextStyle(fontSize: 14, color: Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: isDark
            ? const Color(0xFF2C2F33)
            : const Color(0xFFEFF1F3),
        labelStyle: TextStyle(fontSize: 12, color: textPrimary),
        side: BorderSide(color: borderColor),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: textSecondary,
        titleTextStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: textPrimary,
        ),
        subtitleTextStyle: TextStyle(fontSize: 13, color: textSecondary),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: primaryGreen,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primaryGreen,
        foregroundColor: Colors.white,
      ),
    );
  }

  static ThemeData get lightTheme => _base(
    brightness: Brightness.light,
    scaffold: backgroundGray,
    surface: surfaceLight,
    borderColor: borderLight,
    textPrimary: textPrimaryLight,
    textSecondary: textSecondaryLight,
    appBarBg: primaryGreen,
  );

  static ThemeData get darkTheme => _base(
    brightness: Brightness.dark,
    scaffold: backgroundDark,
    surface: surfaceDark,
    borderColor: borderDark,
    textPrimary: textPrimaryDark,
    textSecondary: textSecondaryDark,
    appBarBg: surfaceDark,
  );
}
