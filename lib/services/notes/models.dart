// Data models for the iCloud Notes viewer feature.
// These models map to the JSON output from the Rust FRB bridge functions.

/// Represents a folder in iCloud Notes.
class NoteFolder {
  final String id;
  final String title;

  NoteFolder({required this.id, required this.title});

  factory NoteFolder.fromJson(Map<String, dynamic> json) => NoteFolder(
        id: json['id'] as String,
        title: json['title'] as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
      };
}

/// Represents a note entry (metadata for list display).
class NoteEntry {
  final String id;
  final String? folderId;
  final String title;
  final String snippet;
  final double modified; // seconds since epoch
  final List<int>? rawData; // raw protobuf bytes for parsing
  final String? ownerName; // for shared notes

  NoteEntry({
    required this.id,
    this.folderId,
    required this.title,
    required this.snippet,
    required this.modified,
    this.rawData,
    this.ownerName,
  });

  factory NoteEntry.fromJson(Map<String, dynamic> json) => NoteEntry(
        id: json['id'] as String,
        folderId: json['folder_id'] as String?,
        title: json['title'] as String,
        snippet: json['snippet'] as String,
        modified: (json['modified'] as num).toDouble(),
        rawData: (json['raw_data'] as List<dynamic>?)?.cast<int>(),
        ownerName: json['owner_name'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'folder_id': folderId,
        'title': title,
        'snippet': snippet,
        'modified': modified,
        'raw_data': rawData,
        'owner_name': ownerName,
      };
}

/// Parsed note content for the viewer.
class ParsedNote {
  final String title;
  final String body;
  final List<FormattingRun> formatting;
  final List<NoteAttachment> attachments;
  final List<NoteTable> tables;

  ParsedNote({
    required this.title,
    required this.body,
    required this.formatting,
    required this.attachments,
    required this.tables,
  });

  factory ParsedNote.fromJson(Map<String, dynamic> json) => ParsedNote(
        title: json['title'] as String,
        body: json['body'] as String,
        formatting: (json['formatting'] as List<dynamic>)
            .map((e) => FormattingRun.fromJson(e as Map<String, dynamic>))
            .toList(),
        attachments: (json['attachments'] as List<dynamic>)
            .map((e) => NoteAttachment.fromJson(e as Map<String, dynamic>))
            .toList(),
        tables: (json['tables'] as List<dynamic>)
            .map((e) => NoteTable.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Style type enum matching Rust NoteStyleType serialization.
enum NoteStyleType {
  defaultStyle,
  title,
  heading,
  subheading,
  monospaced,
  checklist,
  bulletList,
  numberedList,
  dashedList,
}

/// A formatting run segment.
class FormattingRun {
  final int length;
  final NoteStyleType style;
  final bool? checked; // only for checklist style
  final AttachmentRef? attachmentInfo;

  FormattingRun({
    required this.length,
    required this.style,
    this.checked,
    this.attachmentInfo,
  });

  /// Parse the style field from Rust's serde JSON output.
  /// Simple variants serialize as strings: "Default", "Title", etc.
  /// Checklist serializes as: {"Checklist": {"checked": true/false}}
  factory FormattingRun.fromJson(Map<String, dynamic> json) {
    final int length = json['length'] as int;
    final dynamic styleValue = json['style'];
    NoteStyleType style;
    bool? checked;

    if (styleValue is String) {
      style = _parseStyleString(styleValue);
    } else if (styleValue is Map<String, dynamic>) {
      // Handle {"Checklist": {"checked": bool}} variant
      if (styleValue.containsKey('Checklist')) {
        style = NoteStyleType.checklist;
        final checklistData = styleValue['Checklist'] as Map<String, dynamic>;
        checked = checklistData['checked'] as bool? ?? false;
      } else {
        style = NoteStyleType.defaultStyle;
      }
    } else {
      style = NoteStyleType.defaultStyle;
    }

    final attachmentInfoJson = json['attachment_info'];
    final AttachmentRef? attachmentInfo = attachmentInfoJson != null
        ? AttachmentRef.fromJson(attachmentInfoJson as Map<String, dynamic>)
        : null;

    return FormattingRun(
      length: length,
      style: style,
      checked: checked,
      attachmentInfo: attachmentInfo,
    );
  }

  static NoteStyleType _parseStyleString(String value) {
    switch (value) {
      case 'Default':
        return NoteStyleType.defaultStyle;
      case 'Title':
        return NoteStyleType.title;
      case 'Heading':
        return NoteStyleType.heading;
      case 'Subheading':
        return NoteStyleType.subheading;
      case 'Monospaced':
        return NoteStyleType.monospaced;
      case 'BulletList':
        return NoteStyleType.bulletList;
      case 'NumberedList':
        return NoteStyleType.numberedList;
      case 'DashedList':
        return NoteStyleType.dashedList;
      default:
        return NoteStyleType.defaultStyle;
    }
  }
}

/// Attachment reference within a formatting run.
class AttachmentRef {
  final String identifier;
  final String? typeUti;

  AttachmentRef({required this.identifier, this.typeUti});

  factory AttachmentRef.fromJson(Map<String, dynamic> json) => AttachmentRef(
        identifier: json['identifier'] as String,
        typeUti: json['type_uti'] as String?,
      );
}

/// Inline attachment metadata.
class NoteAttachment {
  final String identifier;
  final String? typeUti;
  final int position; // character offset in body

  NoteAttachment({
    required this.identifier,
    this.typeUti,
    required this.position,
  });

  factory NoteAttachment.fromJson(Map<String, dynamic> json) => NoteAttachment(
        identifier: json['identifier'] as String,
        typeUti: json['type_uti'] as String?,
        position: json['position'] as int,
      );
}

/// Table data.
class NoteTable {
  final String identifier;
  final int position; // character offset in body
  final int rows;
  final int columns;
  final List<List<String>> cells; // cells[row][col]

  NoteTable({
    required this.identifier,
    required this.position,
    required this.rows,
    required this.columns,
    required this.cells,
  });

  factory NoteTable.fromJson(Map<String, dynamic> json) => NoteTable(
        identifier: json['identifier'] as String,
        position: json['position'] as int,
        rows: json['rows'] as int,
        columns: json['columns'] as int,
        cells: (json['cells'] as List<dynamic>)
            .map((row) => (row as List<dynamic>).cast<String>().toList())
            .toList(),
      );
}
