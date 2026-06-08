import 'package:bluebubbles/services/notes/models.dart';
import 'package:bluebubbles/services/notes/notes_skin_theme.dart';
import 'package:flutter/material.dart';

/// Renders a NoteTable as a grid with visible cell borders.
/// Wrapped in horizontal scroll for wide tables.
class NoteTableWidget extends StatelessWidget {
  final NoteTable table;
  final NotesSkinTheme theme;

  const NoteTableWidget({
    super.key,
    required this.table,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    if (table.cells.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Table could not be displayed',
          style: TextStyle(
            fontSize: theme.bodySize,
            fontStyle: FontStyle.italic,
            color: Colors.grey,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          border: TableBorder.all(color: theme.tableBorderColor),
          defaultColumnWidth: const IntrinsicColumnWidth(),
          children: table.cells.map((row) {
            return TableRow(
              children: row.map((cellText) {
                return Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    cellText,
                    style: TextStyle(
                      fontSize: theme.bodySize,
                      fontFamily: theme.fontFamily,
                    ),
                  ),
                );
              }).toList(),
            );
          }).toList(),
        ),
      ),
    );
  }
}
