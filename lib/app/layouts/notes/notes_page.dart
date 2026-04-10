import 'package:bluebubbles/app/layouts/notes/note_viewer.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/lib.dart' as lib;
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends OptimizedState<NotesPage> {
  lib.ArcNotesClientDefaultAnisetteProvider? notesClient;
  List<api.DartNoteFolder> folders = [];
  List<api.DartNoteEntry> entries = [];
  String? selectedFolderId;
  bool isLoading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    notesClient = pushService.state?.icloudServices?.notes;
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    if (notesClient == null) {
      setState(() {
        error = 'Notes client not available';
        isLoading = false;
      });
      return;
    }

    try {
      final result = await api.syncNotes(notes: notesClient!);
      if (!mounted) return;
      setState(() {
        folders = result.$2;
        entries = result.$3;
        if (folders.isNotEmpty && selectedFolderId == null) {
          selectedFolderId = folders.first.id;
        }
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

  List<api.DartNoteEntry> get filteredEntries {
    if (selectedFolderId == null) return entries;
    return entries.where((e) => e.folderId == selectedFolderId).toList();
  }

  String _folderName(String folderId) {
    return folders.firstWhereOrNull((f) => f.id == folderId)?.title ?? 'Unknown';
  }

  void _openNote(api.DartNoteEntry entry) {
    Navigator.of(context).push(
      ThemeSwitcher.buildPageRoute(
        builder: (context) => NoteViewer(
          noteEntry: entry,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.theme.colorScheme.background,
      appBar: AppBar(
        title: Text(
          selectedFolderId != null ? _folderName(selectedFolderId!) : 'Notes',
          style: context.theme.textTheme.titleLarge,
        ),
        centerTitle: ss.settings.skin.value == Skins.iOS,
        backgroundColor: context.theme.colorScheme.background,
        leading: selectedFolderId != null && folders.length > 1
            ? IconButton(
                icon: Icon(Icons.arrow_back,
                    color: context.theme.colorScheme.primary),
                onPressed: () {
                  setState(() => selectedFolderId = null);
                },
              )
            : null,
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
                'Failed to load notes',
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
                  _loadNotes();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    // If no folder selected and multiple folders, show folder list
    if (selectedFolderId == null && folders.length > 1) {
      return _buildFolderList();
    }

    // Show notes for selected folder (or all if only one folder)
    return _buildNotesList();
  }

  Widget _buildFolderList() {
    return ListView.builder(
      itemCount: folders.length,
      itemBuilder: (context, index) {
        final folder = folders[index];
        final noteCount =
            entries.where((e) => e.folderId == folder.id).length;
        return ListTile(
          leading: Icon(Icons.folder_outlined,
              color: context.theme.colorScheme.primary),
          title: Text(
            folder.title,
            style: context.theme.textTheme.bodyLarge,
          ),
          trailing: Text(
            '$noteCount',
            style: context.theme.textTheme.bodyMedium?.copyWith(
              color: context.theme.colorScheme.onSurfaceVariant,
            ),
          ),
          onTap: () {
            setState(() => selectedFolderId = folder.id);
          },
        );
      },
    );
  }

  Widget _buildNotesList() {
    final notes = filteredEntries;

    if (notes.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.note_outlined,
                size: 48,
                color: context.theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              'No notes',
              style: context.theme.textTheme.titleMedium?.copyWith(
                color: context.theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadNotes,
      child: ListView.separated(
        itemCount: notes.length,
        separatorBuilder: (context, index) => Divider(
          height: 1,
          indent: 16,
          endIndent: 16,
          color: context.theme.colorScheme.outline.withOpacity(0.2),
        ),
        itemBuilder: (context, index) {
          final note = notes[index];
          final modified = DateTime.fromMillisecondsSinceEpoch(
              note.modified.toInt() * 1000);
          final formattedDate = _formatDate(modified);

          return ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            title: Text(
              note.title.isNotEmpty ? note.title : 'Untitled',
              style: context.theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                Text(
                  formattedDate,
                  style: context.theme.textTheme.bodySmall?.copyWith(
                    color: context.theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (note.snippet.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    note.snippet,
                    style: context.theme.textTheme.bodyMedium?.copyWith(
                      color: context.theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
            onTap: () => _openNote(note),
          );
        },
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[date.weekday - 1];
    } else {
      return '${date.month}/${date.day}/${date.year}';
    }
  }
}
