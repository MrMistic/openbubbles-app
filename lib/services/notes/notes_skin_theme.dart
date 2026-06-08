import 'package:bluebubbles/helpers/types/constants.dart';
import 'package:flutter/material.dart';

/// Checkbox style variants matching each skin's design language.
enum CheckboxStyle { circular, square, roundedToggle }

/// Skin-adaptive theme for the iCloud Notes viewer.
/// Provides colors, fonts, checkbox styles, and spacing based on the selected skin.
class NotesSkinTheme {
  final Color? backgroundColor;
  final Color? darkBackgroundColor;
  final String fontFamily;
  final double titleSize;
  final double headingSize;
  final double subheadingSize;
  final double bodySize;
  final FontWeight titleWeight;
  final FontWeight headingWeight;
  final CheckboxStyle checkboxStyle;
  final double listItemVerticalPadding;
  final double cardElevation;
  final double cardBorderRadius;
  final Color tableBorderColor;

  const NotesSkinTheme({
    this.backgroundColor,
    this.darkBackgroundColor,
    required this.fontFamily,
    required this.titleSize,
    required this.headingSize,
    required this.subheadingSize,
    required this.bodySize,
    required this.titleWeight,
    required this.headingWeight,
    required this.checkboxStyle,
    required this.listItemVerticalPadding,
    required this.cardElevation,
    required this.cardBorderRadius,
    required this.tableBorderColor,
  });

  /// Factory that returns the appropriate theme based on the selected skin.
  static NotesSkinTheme fromSkin(Skins skin, {bool isDarkMode = false}) {
    switch (skin) {
      case Skins.iOS:
        return const NotesSkinTheme(
          backgroundColor: Color(0xFFFFFDF6), // cream
          darkBackgroundColor: Color(0xFF1C1C1E), // Apple dark
          fontFamily: '.SF Pro Text', // system font
          titleSize: 28,
          headingSize: 22,
          subheadingSize: 20,
          bodySize: 17,
          titleWeight: FontWeight.bold,
          headingWeight: FontWeight.bold,
          checkboxStyle: CheckboxStyle.circular,
          listItemVerticalPadding: 8,
          cardElevation: 0,
          cardBorderRadius: 10,
          tableBorderColor: Color(0xFFD1D1D6),
        );
      case Skins.Material:
        return const NotesSkinTheme(
          backgroundColor: null, // uses Material surface color
          darkBackgroundColor: null, // uses Material dark surface
          fontFamily: 'Roboto',
          titleSize: 24,
          headingSize: 20,
          subheadingSize: 16,
          bodySize: 14,
          titleWeight: FontWeight.w500,
          headingWeight: FontWeight.w500,
          checkboxStyle: CheckboxStyle.square,
          listItemVerticalPadding: 4,
          cardElevation: 1,
          cardBorderRadius: 8,
          tableBorderColor: Color(0xFFBDBDBD),
        );
      case Skins.Samsung:
        return const NotesSkinTheme(
          backgroundColor: Color(0xFFFFFEFA), // warm white
          darkBackgroundColor: Color(0xFF1A1A1A),
          fontFamily: 'SamsungOne', // falls back to system
          titleSize: 30,
          headingSize: 24,
          subheadingSize: 21,
          bodySize: 18,
          titleWeight: FontWeight.bold,
          headingWeight: FontWeight.w600,
          checkboxStyle: CheckboxStyle.roundedToggle,
          listItemVerticalPadding: 12,
          cardElevation: 0.5,
          cardBorderRadius: 16,
          tableBorderColor: Color(0xFFE0E0E0),
        );
    }
  }

  /// Get the effective background color based on dark mode state.
  Color? getBackgroundColor({required bool isDarkMode}) {
    return isDarkMode ? darkBackgroundColor : backgroundColor;
  }
}
