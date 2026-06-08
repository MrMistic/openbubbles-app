import 'package:bluebubbles/app/layouts/notes/note_viewer_page.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/services/notes/models.dart';
import 'package:bluebubbles/services/notes/notes_controller.dart';
import 'package:bluebubbles/services/notes/notes_skin_theme.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Displays folders and note entries with pull-to-refresh,
/// folder-grouped sections, and skin-adaptive styling.
class NotesListPage extends StatefulWidget {
  const NotesListPage({super.key});

  @override
  State<NotesListPage> createState() => _NotesListPageState();
}

class _NotesListPageState extends State<NotesListPage> {
  late final NotesController controller;

  @override
  void initState() {
    super.initState();
    controller = Get.put(NotesController());
    controller.init();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('iCloud Notes'),
      ),
      body: Obx(() {
        final theme = NotesSkinTheme.fromSkin(
          ss.settings.skin.value,
          isDarkMode: Get.isDarkMode,
        );

        // Loading state with no cached data
        if (controller.isLoading.value &&
            controller.notes.isEmpty &&
            controller.folders.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        // Error state with no cached data
        if (controller.errorMessage.value != null &&
            controller.notes.isEmpty &&
            controller.folders.isEmpty) {
          return _buildErrorState(controller.errorMessage.value!);
        }

        // Empty state
        if (controller.notes.isEmpty && controller.folders.isEmpty) {
          return _buildEmptyState();
        }

        // Show notes grouped by folder
        final grouped = controller.groupedNotes;
        final shared = controller.sharedNotes;

        return RefreshIndicator(
          onRefresh: () async {
            await controller.syncNotes();
            await controller.syncSharedNotes();
          },
          child: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  // Private notes grouped by folder
                  ...grouped.entries.map((entry) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Section header
                      Padding(
                        padding: const EdgeInsets.only(top: 16, bottom: 8),
                        child: Text(
                          entry.key,
                          style: TextStyle(
                            fontSize: theme.headingSize - 4,
                            fontWeight: FontWeight.w600,
                            fontFamily: theme.fontFamily,
                          ),
                        ),
                      ),
                      // Note tiles
                      ...entry.value.map((note) => _buildNoteTile(note, theme)),
                    ],
                  )),
                  // Shared notes section
                  if (shared.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 24, bottom: 8),
                      child: Text(
                        'Shared with Me',
                        style: TextStyle(
                          fontSize: theme.headingSize - 4,
                          fontWeight: FontWeight.w600,
                          fontFamily: theme.fontFamily,
                        ),
                      ),
                    ),
                    ...shared.map((note) => _buildSharedNoteTile(note, theme)),
                  ],
                ],
              ),
              // Non-blocking error snackbar overlay
              if (controller.errorMessage.value != null &&
                  controller.notes.isNotEmpty)
                Positioned(
                  bottom: 16,
                  left: 16,
                  right: 16,
                  child: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.orange[50],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline,
                              color: Colors.orange, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              controller.errorMessage.value!,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          GestureDetector(
                            onTap: () => controller.errorMessage.value = null,
                            child: const Icon(Icons.close, size: 18),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildNoteTile(NoteEntry note, NotesSkinTheme theme) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: theme.listItemVerticalPadding / 2),
      child: Material(
        elevation: theme.cardElevation,
        borderRadius: BorderRadius.circular(theme.cardBorderRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(theme.cardBorderRadius),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => NoteViewerPage(entry: note),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title
                Text(
                  note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: theme.bodySize,
                    fontWeight: FontWeight.w600,
                    fontFamily: theme.fontFamily,
                  ),
                ),
                const SizedBox(height: 4),
                // Snippet
                Text(
                  note.snippet,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: theme.bodySize - 2,
                    color: Colors.grey[600],
                    fontFamily: theme.fontFamily,
                  ),
                ),
                const SizedBox(height: 4),
                // Relative date
                Text(
                  _formatRelativeDate(note.modified),
                  style: TextStyle(
                    fontSize: theme.bodySize - 4,
                    color: Colors.grey[500],
                    fontFamily: theme.fontFamily,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSharedNoteTile(NoteEntry note, NotesSkinTheme theme) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: theme.listItemVerticalPadding / 2),
      child: Material(
        elevation: theme.cardElevation,
        borderRadius: BorderRadius.circular(theme.cardBorderRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(theme.cardBorderRadius),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => NoteViewerPage(entry: note),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title
                Text(
                  note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: theme.bodySize,
                    fontWeight: FontWeight.w600,
                    fontFamily: theme.fontFamily,
                  ),
                ),
                const SizedBox(height: 4),
                // Sharing indicator
                Row(
                  children: [
                    Icon(Icons.person_outline, size: 14, color: Colors.grey[500]),
                    const SizedBox(width: 4),
                    Text(
                      'Shared by ${note.ownerName ?? "Unknown"}',
                      style: TextStyle(
                        fontSize: theme.bodySize - 3,
                        color: Colors.grey[500],
                        fontFamily: theme.fontFamily,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // Snippet
                Text(
                  note.snippet,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: theme.bodySize - 2,
                    color: Colors.grey[600],
                    fontFamily: theme.fontFamily,
                  ),
                ),
                const SizedBox(height: 4),
                // Relative date
                Text(
                  _formatRelativeDate(note.modified),
                  style: TextStyle(
                    fontSize: theme.bodySize - 4,
                    color: Colors.grey[500],
                    fontFamily: theme.fontFamily,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => controller.syncNotes(),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.note_outlined, size: 48, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'No notes found',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
            SizedBox(height: 8),
            Text(
              'Make sure your iCloud account has notes.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  String _formatRelativeDate(double secondsSinceEpoch) {
    final date = DateTime.fromMillisecondsSinceEpoch(
        (secondsSinceEpoch * 1000).toInt());
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${date.month}/${date.day}/${date.year}';
  }
}
