import 'package:bluebubbles/services/notes/models.dart';
import 'package:bluebubbles/services/notes/notes_skin_theme.dart';
import 'package:bluebubbles/app/layouts/notes/widgets/inline_attachment_widget.dart';
import 'package:bluebubbles/app/layouts/notes/widgets/note_table_widget.dart';
import 'package:flutter/material.dart';

/// Renders a ParsedNote as a vertical list of styled widgets.
/// Groups consecutive attribute runs into paragraphs (split on newlines),
/// rendering each paragraph as a single RichText with styled TextSpans.
class FormattedNoteWidget extends StatelessWidget {
  final ParsedNote parsedNote;
  final NotesSkinTheme theme;
  final Function(String identifier)? onAttachmentTap;

  const FormattedNoteWidget({
    super.key,
    required this.parsedNote,
    required this.theme,
    this.onAttachmentTap,
  });

  @override
  Widget build(BuildContext context) {
    final widgets = _buildContent();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  List<Widget> _buildContent() {
    final List<Widget> widgets = [];
    final body = parsedNote.body;
    int charOffset = 0;

    // Collect spans for the current paragraph, flushing on newlines
    List<_StyledSegment> currentParagraph = [];
    NoteStyleType? currentParagraphStyle;

    void flushParagraph() {
      if (currentParagraph.isEmpty) return;
      final widget = _buildParagraphWidget(currentParagraph, currentParagraphStyle ?? NoteStyleType.defaultStyle);
      if (widget != null) widgets.add(widget);
      currentParagraph = [];
    }

    for (final run in parsedNote.formatting) {
      final length = run.length;
      final end = (charOffset + length).clamp(0, body.length);
      final segment = body.substring(charOffset, end);

      // Check if this run contains U+FFFC (object replacement character)
      if (segment.contains('\uFFFC') && run.attachmentInfo != null) {
        flushParagraph();
        final identifier = run.attachmentInfo!.identifier;
        final typeUti = run.attachmentInfo!.typeUti ?? '';

        final table = parsedNote.tables.firstWhere(
          (t) => t.identifier == identifier,
          orElse: () => NoteTable(identifier: '', position: 0, rows: 0, columns: 0, cells: []),
        );

        if (table.identifier == identifier) {
          widgets.add(NoteTableWidget(table: table, theme: theme));
        } else {
          widgets.add(InlineAttachmentWidget(
            identifier: identifier,
            typeUti: typeUti,
            onTap: onAttachmentTap != null ? () => onAttachmentTap!(identifier) : null,
          ));
        }
        charOffset = end;
        continue;
      }

      // Split segment by newlines — each newline starts a new paragraph
      final lines = segment.split('\n');
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];

        // If paragraph style changes, flush
        if (currentParagraphStyle != null && currentParagraphStyle != run.style && currentParagraph.isNotEmpty) {
          flushParagraph();
        }
        currentParagraphStyle = run.style;

        if (line.isNotEmpty) {
          currentParagraph.add(_StyledSegment(
            text: line,
            run: run,
          ));
        }

        // If there are more lines after this one, flush (the \n boundary)
        if (i < lines.length - 1) {
          flushParagraph();
          currentParagraphStyle = run.style;
        }
      }

      charOffset = end;
    }

    // Flush remaining paragraph
    flushParagraph();

    return widgets;
  }

  Widget? _buildParagraphWidget(List<_StyledSegment> segments, NoteStyleType style) {
    if (segments.isEmpty) return null;
    final fullText = segments.map((s) => s.text).join();
    if (fullText.trim().isEmpty) return const SizedBox(height: 8);

    // Build a single RichText from all segments
    final spans = segments.map((s) => TextSpan(
      text: s.text,
      style: _textStyleForRun(s.run),
    )).toList();

    final richText = SelectableText.rich(
      TextSpan(children: spans),
    );

    switch (style) {
      case NoteStyleType.title:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: richText,
        );
      case NoteStyleType.heading:
        return Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: richText,
        );
      case NoteStyleType.subheading:
        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: richText,
        );
      case NoteStyleType.monospaced:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.withOpacity(0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: richText,
          ),
        );
      case NoteStyleType.checklist:
        final checked = segments.first.run.checked ?? false;
        return Padding(
          padding: EdgeInsets.symmetric(vertical: theme.listItemVerticalPadding / 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCheckbox(checked),
              const SizedBox(width: 8),
              Expanded(child: richText),
            ],
          ),
        );
      case NoteStyleType.bulletList:
        return Padding(
          padding: EdgeInsets.symmetric(vertical: theme.listItemVerticalPadding / 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 24, child: Text('•', style: TextStyle(fontSize: theme.bodySize))),
              Expanded(child: richText),
            ],
          ),
        );
      case NoteStyleType.numberedList:
        return Padding(
          padding: EdgeInsets.symmetric(vertical: theme.listItemVerticalPadding / 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 24, child: Text('', style: TextStyle(fontSize: theme.bodySize))),
              Expanded(child: richText),
            ],
          ),
        );
      case NoteStyleType.dashedList:
        return Padding(
          padding: EdgeInsets.symmetric(vertical: theme.listItemVerticalPadding / 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 24, child: Text('–', style: TextStyle(fontSize: theme.bodySize))),
              Expanded(child: richText),
            ],
          ),
        );
      case NoteStyleType.defaultStyle:
      default:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: richText,
        );
    }
  }

  TextStyle _textStyleForRun(FormattingRun run) {
    switch (run.style) {
      case NoteStyleType.title:
        return TextStyle(
          fontSize: theme.titleSize,
          fontWeight: theme.titleWeight,
          fontFamily: theme.fontFamily,
        );
      case NoteStyleType.heading:
        return TextStyle(
          fontSize: theme.headingSize,
          fontWeight: theme.headingWeight,
          fontFamily: theme.fontFamily,
        );
      case NoteStyleType.subheading:
        return TextStyle(
          fontSize: theme.subheadingSize,
          fontWeight: theme.headingWeight,
          fontFamily: theme.fontFamily,
        );
      case NoteStyleType.monospaced:
        return TextStyle(
          fontSize: theme.bodySize,
          fontFamily: 'monospace',
        );
      case NoteStyleType.checklist:
        final checked = run.checked ?? false;
        return TextStyle(
          fontSize: theme.bodySize,
          fontFamily: theme.fontFamily,
          decoration: checked ? TextDecoration.lineThrough : null,
          color: checked ? Colors.grey : null,
        );
      default:
        return TextStyle(
          fontSize: theme.bodySize,
          fontFamily: theme.fontFamily,
        );
    }
  }

  Widget _buildCheckbox(bool checked) {
    switch (theme.checkboxStyle) {
      case CheckboxStyle.circular:
        return Container(
          width: 20, height: 20,
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: checked ? Colors.orange : Colors.transparent,
            border: Border.all(color: checked ? Colors.orange : Colors.grey, width: 1.5),
          ),
          child: checked ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
        );
      case CheckboxStyle.square:
        return Container(
          width: 20, height: 20,
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            color: checked ? Colors.blue : Colors.transparent,
            border: Border.all(color: checked ? Colors.blue : Colors.grey, width: 1.5),
          ),
          child: checked ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
        );
      case CheckboxStyle.roundedToggle:
        return Container(
          width: 20, height: 20,
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: checked ? Colors.blue[700] : Colors.transparent,
            border: Border.all(color: checked ? Colors.blue[700]! : Colors.grey, width: 1.5),
          ),
          child: checked ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
        );
    }
  }
}

class _StyledSegment {
  final String text;
  final FormattingRun run;
  const _StyledSegment({required this.text, required this.run});
}
