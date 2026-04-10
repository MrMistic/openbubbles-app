import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class NoteViewer extends StatelessWidget {
  final api.DartNoteEntry noteEntry;

  const NoteViewer({
    super.key,
    required this.noteEntry,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.theme.colorScheme.background,
      appBar: AppBar(
        title: Text(
          noteEntry.title.isNotEmpty ? noteEntry.title : 'Untitled',
          style: context.theme.textTheme.titleLarge,
        ),
        centerTitle: ss.settings.skin.value == Skins.iOS,
        backgroundColor: context.theme.colorScheme.background,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: SelectableText(
          noteEntry.snippet.isNotEmpty ? noteEntry.snippet : '(No content)',
          style: context.theme.textTheme.bodyLarge,
        ),
      ),
    );
  }
}
