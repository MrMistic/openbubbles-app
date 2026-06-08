import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/notes/models.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;

/// GetX controller for managing iCloud Notes state, sync, and caching.
class NotesController extends GetxController {
  final RxList<NoteFolder> folders = <NoteFolder>[].obs;
  final RxList<NoteEntry> notes = <NoteEntry>[].obs;
  final RxList<NoteEntry> sharedNotes = <NoteEntry>[].obs;
  final RxBool isLoading = false.obs;
  final RxnString errorMessage = RxnString();

  String? _privateToken;
  String? _sharedToken;
  /// Cached media map JSON from last sync (maps attachment→media record IDs)
  String? _mediaMapJson;

  /// Safely get the CloudKit client, returning null if unavailable.
  dynamic _getCloudKitClient() {
    try {
      return pushService.state?.icloudServices?.cloudkitClient;
    } on Object {
      // Catches both Exception and Error (including AssertionError
      // from service initialization in test environments)
      return null;
    }
  }

  /// Load cached data from disk, then trigger incremental sync.
  Future<void> init() async {
    await _loadCache();
    await syncNotes();
    // Shared notes sync is independent — failure doesn't affect private notes
    await syncSharedNotes();
  }

  /// Perform sync (full or incremental based on stored token).
  /// Uses merge strategy: upserts returned records into existing state
  /// rather than replacing, since incremental sync only returns deltas.
  Future<void> syncNotes() async {
    final cloudkit = _getCloudKitClient();
    if (cloudkit == null) {
      errorMessage.value = 'iCloud session not available. Please re-authenticate.';
      return;
    }

    isLoading.value = true;
    errorMessage.value = null;

    try {
      final tokenBytes = _privateToken != null
          ? base64Decode(_privateToken!)
          : null;
      final isFullSync = tokenBytes == null;

      final keychain = pushService.state?.icloudServices?.keychain;
      if (keychain == null) {
        errorMessage.value = 'Keychain not available.';
        isLoading.value = false;
        return;
      }

      final jsonStr = await api.fetchNotesJson(
        cloudkit: cloudkit,
        keychain: keychain,
        continuationToken: tokenBytes,
      );

      final Map<String, dynamic> result = jsonDecode(jsonStr);

      // Update continuation token
      _privateToken = result['token'] as String?;

      // Store media map for attachment downloads
      if (result['media_map'] != null) {
        _mediaMapJson = jsonEncode(result['media_map']);
      }

      // Parse incoming folders and notes
      final List<dynamic> foldersJson = result['folders'] ?? [];
      final incomingFolders = foldersJson
          .map((f) => NoteFolder.fromJson(f as Map<String, dynamic>))
          .toList();

      final List<dynamic> notesJson = result['notes'] ?? [];
      final incomingNotes = notesJson
          .map((n) => NoteEntry.fromJson(n as Map<String, dynamic>))
          .toList();

      if (isFullSync) {
        // Full sync: replace entirely
        folders.value = incomingFolders;
        notes.value = incomingNotes;
      } else {
        // Incremental sync: merge/upsert into existing state
        _mergeFolders(incomingFolders);
        _mergeNotes(incomingNotes);
      }

      await _persistCache();
    } catch (e) {
      // On error, preserve existing data if available
      if (notes.isEmpty && folders.isEmpty) {
        // No cached data — show full error state with actual error for debugging
        errorMessage.value = 'Sync failed: ${e.toString().length > 100 ? e.toString().substring(0, 100) : e.toString()}';
      } else {
        // Cached data exists — show non-blocking error
        errorMessage.value = 'Sync failed. Showing cached data.';
      }
    } finally {
      isLoading.value = false;
    }
  }

  /// Perform shared notes sync (independent of private notes).
  /// Failure does not affect private notes display.
  Future<void> syncSharedNotes() async {
    final cloudkit = _getCloudKitClient();
    if (cloudkit == null) return;

    final keychain = pushService.state?.icloudServices?.keychain;
    if (keychain == null) return;

    try {
      final tokenBytes = _sharedToken != null
          ? base64Decode(_sharedToken!)
          : null;

      final jsonStr = await api.fetchSharedNotesJson(
        cloudkit: cloudkit,
        keychain: keychain,
        continuationToken: tokenBytes,
      );

      final Map<String, dynamic> result = jsonDecode(jsonStr);

      _sharedToken = result['token'] as String?;

      final List<dynamic> notesJson = result['notes'] ?? [];
      sharedNotes.value = notesJson
          .map((n) => NoteEntry.fromJson(n as Map<String, dynamic>))
          .toList();

      await _persistCache();
    } catch (_) {
      // Shared sync failure is non-blocking — private notes remain unaffected
    }
  }

  /// Parse a single note's content for the viewer.
  Future<ParsedNote?> parseNote(NoteEntry entry) async {
    if (entry.rawData == null || entry.rawData!.isEmpty) {
      return null;
    }

    try {
      final jsonStr = await api.parseNoteJson(data: entry.rawData!);
      final Map<String, dynamic> parsed = jsonDecode(jsonStr);
      return ParsedNote.fromJson(parsed);
    } catch (e) {
      return null;
    }
  }

  /// Download attachment image data (lazy, on-demand).
  Future<Uint8List?> fetchAttachment(String identifier) async {
    debugPrint('[Notes] fetchAttachment called for: $identifier');
    final cloudkit = _getCloudKitClient();
    if (cloudkit == null) { debugPrint('[Notes] fetchAttachment: no cloudkit'); return null; }

    final keychain = pushService.state?.icloudServices?.keychain;
    if (keychain == null) { debugPrint('[Notes] fetchAttachment: no keychain'); return null; }

    try {
      final result = await api.fetchAttachmentData(
        cloudkit: cloudkit,
        keychain: keychain,
        attachmentIdentifier: identifier,
      );
      debugPrint('[Notes] fetchAttachment success: ${result.length} bytes');
      return result;
    } catch (e) {
      debugPrint('[Notes] fetchAttachment error: $e');
      return null;
    }
  }

  /// Get notes for a specific folder, sorted by modification date descending.
  List<NoteEntry> notesForFolder(String? folderId) {
    final filtered = notes.where((n) => n.folderId == folderId).toList();
    filtered.sort((a, b) => b.modified.compareTo(a.modified));
    return filtered;
  }

  /// Group notes by folder for display.
  /// Returns a map of folder title → list of notes sorted by modified desc.
  Map<String, List<NoteEntry>> get groupedNotes {
    final Map<String, List<NoteEntry>> groups = {};

    // Build folder ID → title lookup
    final Map<String?, String> folderTitles = {};
    for (final folder in folders) {
      folderTitles[folder.id] = folder.title;
    }

    for (final note in notes) {
      final sectionTitle = folderTitles[note.folderId] ?? 'Notes';
      groups.putIfAbsent(sectionTitle, () => []);
      groups[sectionTitle]!.add(note);
    }

    // Sort each group by modification date descending
    for (final group in groups.values) {
      group.sort((a, b) => b.modified.compareTo(a.modified));
    }

    return groups;
  }

  /// Merge incoming folders into existing state (upsert by ID).
  void _mergeFolders(List<NoteFolder> incoming) {
    if (incoming.isEmpty) return;
    final existing = Map.fromEntries(folders.map((f) => MapEntry(f.id, f)));
    for (final folder in incoming) {
      existing[folder.id] = folder;
    }
    folders.value = existing.values.toList();
  }

  /// Merge incoming notes into existing state (upsert by ID).
  void _mergeNotes(List<NoteEntry> incoming) {
    if (incoming.isEmpty) return;
    final existing = Map.fromEntries(notes.map((n) => MapEntry(n.id, n)));
    for (final note in incoming) {
      existing[note.id] = note;
    }
    notes.value = existing.values.toList();
  }

  /// Persist sync results to disk for offline access.
  Future<void> _persistCache() async {
    if (kIsWeb) return;

    try {
      final file = await _cacheFile;
      final cache = jsonEncode({
        'privateToken': _privateToken,
        'sharedToken': _sharedToken,
        'mediaMapJson': _mediaMapJson,
        'folders': folders.map((f) => f.toJson()).toList(),
        'notes': notes.map((n) => n.toJson()).toList(),
        'sharedNotes': sharedNotes.map((n) => n.toJson()).toList(),
      });
      await file.writeAsString(cache);
    } catch (_) {
      // Cache persistence is best-effort
    }
  }

  /// Load cached data from disk.
  Future<void> _loadCache() async {
    if (kIsWeb) return;

    try {
      final file = await _cacheFile;
      if (await file.exists()) {
        final contents = await file.readAsString();
        final Map<String, dynamic> cache = jsonDecode(contents);

        _privateToken = cache['privateToken'] as String?;
        _sharedToken = cache['sharedToken'] as String?;
        _mediaMapJson = cache['mediaMapJson'] as String?;

        final List<dynamic> cachedFolders = cache['folders'] ?? [];
        folders.value = cachedFolders
            .map((f) => NoteFolder.fromJson(f as Map<String, dynamic>))
            .toList();

        final List<dynamic> cachedNotes = cache['notes'] ?? [];
        notes.value = cachedNotes
            .map((n) => NoteEntry.fromJson(n as Map<String, dynamic>))
            .toList();

        final List<dynamic> cachedShared = cache['sharedNotes'] ?? [];
        sharedNotes.value = cachedShared
            .map((n) => NoteEntry.fromJson(n as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {
      // Cache loading is best-effort
    }
  }

  Future<File> get _cacheFile async {
    final dir = fs.appDocDir.path;
    return File(p.join(dir, 'notes_cache.json'));
  }
}
