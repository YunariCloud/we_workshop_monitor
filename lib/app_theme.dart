import 'package:flutter/material.dart';

final appThemeMode = ValueNotifier<ThemeMode>(ThemeMode.light);

class AppPalette {
  static bool get dark => appThemeMode.value == ThemeMode.dark;
  static Color get bgCanvas =>
      dark ? const Color(0xFF15151A) : const Color(0xFFF7F7FA);
  static Color get bgSidebar =>
      dark ? const Color(0xFF1C1C23) : const Color(0xFFF0F0F5);
  static Color get bgCard => dark ? const Color(0xFF202027) : Colors.white;
  static Color get bgCardHover =>
      dark ? const Color(0xFF2B2A35) : const Color(0xFFF3F1FB);
  static Color get bgInput =>
      dark ? const Color(0xFF19191F) : const Color(0xFFF8F8FB);
  static Color get borderSubtle =>
      dark ? const Color(0xFF32313C) : const Color(0xFFE6E5ED);
  static Color get borderHighlight => accentCyan;
  static Color get accentCyan =>
      dark ? const Color(0xFFB4A3FF) : const Color(0xFF7560D5);
  static Color get accentIndigo => accentCyan;
  static Color get statusActive =>
      dark ? const Color(0xFF6EC7A0) : const Color(0xFF268360);
  static Color get statusMissing =>
      dark ? const Color(0xFFEF9196) : const Color(0xFFC14B57);
  static Color get statusModified =>
      dark ? const Color(0xFFE5BF75) : const Color(0xFFA67A26);
  static Color get textPrimary =>
      dark ? const Color(0xFFF0EFF5) : const Color(0xFF262430);
  static Color get textSecondary =>
      dark ? const Color(0xFFAAA8B8) : const Color(0xFF767180);
  static Color get textMuted =>
      dark ? const Color(0xFF817D91) : const Color(0xFF9792A2);
}

ThemeData buildWorkshopTheme() {
  final brightness = AppPalette.dark ? Brightness.dark : Brightness.light;
  final scheme = ColorScheme.fromSeed(
      seedColor: AppPalette.accentCyan,
      brightness: brightness,
      surface: AppPalette.bgCard,
      primary: AppPalette.accentCyan,
      error: AppPalette.statusMissing);
  final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: 'Microsoft YaHei');
  final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: AppPalette.borderSubtle));
  return base.copyWith(
    scaffoldBackgroundColor: AppPalette.bgCanvas,
    textTheme: base.textTheme.apply(
        bodyColor: AppPalette.textPrimary,
        displayColor: AppPalette.textPrimary),
    dividerColor: AppPalette.borderSubtle,
    cardTheme: CardThemeData(
        color: AppPalette.bgCard,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppPalette.borderSubtle))),
    inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppPalette.bgInput,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
        border: outline,
        enabledBorder: outline,
        focusedBorder: outline.copyWith(
            borderSide: BorderSide(color: AppPalette.accentCyan)),
        labelStyle: TextStyle(color: AppPalette.textSecondary, fontSize: 13),
        hintStyle: TextStyle(color: AppPalette.textMuted, fontSize: 13)),
    filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            textStyle: const TextStyle(
                fontFamily: 'Microsoft YaHei',
                fontSize: 13,
                fontWeight: FontWeight.w500))),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 40),
            foregroundColor: AppPalette.textPrimary,
            side: BorderSide(color: AppPalette.borderSubtle),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)))),
    textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)))),
    dialogTheme: DialogThemeData(
        backgroundColor: AppPalette.bgCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
    popupMenuTheme: PopupMenuThemeData(
        color: AppPalette.bgCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    tooltipTheme:
        const TooltipThemeData(waitDuration: Duration(milliseconds: 400)),
    dividerTheme: DividerThemeData(
        color: AppPalette.borderSubtle, thickness: 1, space: 1),
  );
}
