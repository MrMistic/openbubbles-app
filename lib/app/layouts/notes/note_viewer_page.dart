import 'package:bluebubbles/app/layouts/notes/widgets/formatted_note_widget.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/services/notes/models.dart';
import 'package:bluebubbles/services/notes/notes_controller.dart';
import 'package:bluebubbles/services/notes/notes_skin_theme.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Displays a single note's full content with rich formatting.
/// Uses NotesSkinTheme for background color and passes theme to FormattedNoteWidget.
class NoteViewerPage extends StatefulWidget {
  final NoteEntry entry;

  const NoteViewerPage({super.key, required this.entry});

  @override
  State<NoteViewerPage> createState() => _NoteViewerPageState();
}

class _NoteViewerPageState extends State<NoteViewerPage> {
  ParsedNote? _parsedNote;
  bool _isLoading = true;
  bool _parseError = false;

  @override
  void initState() {
    super.initState();
    _parseNote();
  }

  Future<void> _parseNote() async {
    try {
      final controller = Get.find<NotesController>();
      final parsed = await controller.parseNote(widget.entry);
      if (mounted) {
        setState(() {
          _parsedNote = parsed;
          _isLoading = false;
          _parseError = parsed == null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _parseError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final theme = NotesSkinTheme.fromSkin(
        ss.settings.skin.value,
        isDarkMode: Get.isDarkMode,
      );

      final bgColor = theme.getBackgroundColor(isDarkMode: Get.isDarkMode) ??
          Theme.of(context).scaffoldBackgroundColor;

      return Scaffold(
        backgroundColor: bgColor,
        appBar: AppBar(
          title: Text(widget.entry.title),
          backgroundColor: bgColor,
        ),
        body: _buildBody(theme),
      );
    });
  }

  Widget _buildBody(NotesSkinTheme theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_parseError || _parsedNote == null) {
      // Fallback: show raw snippet text with error notification
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _parseError) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not render formatting'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      });

      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          widget.entry.snippet,
          style: TextStyle(
            fontSize: theme.bodySize,
            fontFamily: theme.fontFamily,
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: FormattedNoteWidget(
        parsedNote: _parsedNote!,
        theme: theme,
        onAttachmentTap: (identifier) {
          _openFullscreenImage(identifier);
        },
      ),
    );
  }

  void _openFullscreenImage(String identifier) async {
    final controller = Get.find<NotesController>();
    final data = await controller.fetchAttachment(identifier);
    if (data != null && mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black,
              iconTheme: const IconThemeData(color: Colors.white),
            ),
            body: Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.memory(data),
              ),
            ),
          ),
        ),
      );
    }
  }
}
