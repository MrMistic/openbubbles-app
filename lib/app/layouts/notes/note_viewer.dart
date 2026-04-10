import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as lib;
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class NoteViewer extends StatefulWidget {
  final lib.ArcNotesClientDefaultAnisetteProvider notesClient;
  final api.DartNoteEntry noteEntry;

  const NoteViewer({
    super.key,
    required this.notesClient,
    required this.noteEntry,
  });

  @override
  State<NoteViewer> createState() => _NoteViewerState();
}

class _NoteViewerState extends OptimizedState<NoteViewer> {
  api.DartParsedNote? parsedNote;
  bool isLoading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadNote();
  }

  Future<void> _loadNote() async {
    try {
      final note = await api.getNote(
        notes: widget.notesClient,
        noteId: widget.noteEntry.id,
      );
      if (!mounted) return;
      setState(() {
        parsedNote = note;
        isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString();
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.theme.colorScheme.background,
      appBar: AppBar(
        title: Text(
          widget.noteEntry.title.isNotEmpty
              ? widget.noteEntry.title
              : 'Untitled',
          style: context.theme.textTheme.titleLarge,
        ),
        centerTitle: ss.settings.skin.value == Skins.iOS,
        backgroundColor: context.theme.colorScheme.background,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 48, color: context.theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(
                'Failed to load note',
                style: context.theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                error!,
                style: context.theme.textTheme.bodyMedium?.copyWith(
                  color: context.theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    isLoading = true;
                    error = null;
                  });
                  _loadNote();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final note = parsedNote!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: _buildFormattedContent(note),
    );
  }

  Widget _buildFormattedContent(api.DartParsedNote note) {
    if (note.formatting.isEmpty) {
      return SelectableText(
        note.body,
        style: context.theme.textTheme.bodyLarge,
      );
    }

    final spans = <TextSpan>[];
    int offset = 0;

    for (final run in note.formatting) {
      final end = (offset + run.length).clamp(0, note.body.length);
      if (offset >= note.body.length) break;
      final text = note.body.substring(offset, end);
      spans.add(TextSpan(
        text: text,
        style: _styleForRun(run),
      ));
      offset = end;
    }

    // Remaining text after all formatting runs
    if (offset < note.body.length) {
      spans.add(TextSpan(
        text: note.body.substring(offset),
        style: context.theme.textTheme.bodyLarge,
      ));
    }

    return SelectableText.rich(
      TextSpan(children: spans),
    );
  }

  TextStyle _styleForRun(api.DartFormattingRun run) {
    final base = context.theme.textTheme.bodyLarge ?? const TextStyle();
    switch (run.style) {
      case api.DartNoteStyleType.bold:
        return base.copyWith(fontWeight: FontWeight.bold);
      case api.DartNoteStyleType.italic:
        return base.copyWith(fontStyle: FontStyle.italic);
      case api.DartNoteStyleType.title:
        return (context.theme.textTheme.headlineMedium ?? base).copyWith(
          fontWeight: FontWeight.bold,
        );
      case api.DartNoteStyleType.heading:
        return (context.theme.textTheme.titleLarge ?? base).copyWith(
          fontWeight: FontWeight.w600,
        );
      case api.DartNoteStyleType.monospace:
        return base.copyWith(fontFamily: 'monospace');
      case api.DartNoteStyleType.checklist:
      case api.DartNoteStyleType.bulletedList:
      case api.DartNoteStyleType.dashedList:
      case api.DartNoteStyleType.numberedList:
        return base;
      case api.DartNoteStyleType.defaultStyle:
      default:
        return base;
    }
  }
}
