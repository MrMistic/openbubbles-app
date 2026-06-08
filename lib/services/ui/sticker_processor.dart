import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/database/global/platform_file.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:image/image.dart' as img;
import 'package:mime_type/mime_type.dart';
import 'package:universal_io/io.dart';
import 'package:uuid/uuid.dart';

/// Stateless utility class responsible for preparing sticker images for sending.
/// Handles image resizing, format conversion, EXIF metadata injection, and validation.
class StickerProcessor {
  static const String _tag = 'StickerProcessor';

  /// Maximum allowed source dimension in either width or height.
  static const int _maxSourceDimension = 2048;

  /// Target sticker dimension (320×320).
  static const int _targetSize = 320;

  /// Supported MIME types for sticker processing.
  static const Set<String> _supportedMimeTypes = {
    'image/png',
    'image/jpeg',
    'image/webp',
    'image/heic',
    'image/heif',
  };

  /// Resize image to 320×320, preserving alpha, centering non-square images.
  /// Returns null if source exceeds 2048×2048 or format is unsupported.
  ///
  /// - For images already at 320×320, returns the decoded image as-is (no re-encoding).
  /// - For non-square images: scales to fit within 320×320 maintaining aspect ratio,
  ///   centers on canvas, fills padding with transparent pixels (RGBA 0,0,0,0).
  /// - Handles HEIC, JPEG, WebP → decode to RGBA before resize.
  /// - Rejects unsupported formats (not PNG, HEIC, JPEG, WebP) by returning null.
  static Future<img.Image?> resize(Uint8List sourceBytes, String mimeType) async {
    // Normalize MIME type
    final normalizedMime = mimeType.toLowerCase().trim();

    // Reject unsupported formats
    if (!_supportedMimeTypes.contains(normalizedMime)) {
      Logger.warn('Unsupported sticker format: $normalizedMime', tag: _tag);
      return null;
    }

    // Decode the image
    final img.Image? decoded = _decodeImage(sourceBytes, normalizedMime);
    if (decoded == null) {
      Logger.warn('Failed to decode sticker image (mime: $normalizedMime)', tag: _tag);
      return null;
    }

    // Reject images exceeding 2048×2048 in either dimension
    if (decoded.width > _maxSourceDimension || decoded.height > _maxSourceDimension) {
      Logger.warn(
        'Sticker source exceeds maximum dimensions: ${decoded.width}×${decoded.height} (max: $_maxSourceDimension×$_maxSourceDimension)',
        tag: _tag,
      );
      return null;
    }

    // If already 320×320, pass through without re-encoding
    if (decoded.width == _targetSize && decoded.height == _targetSize) {
      return decoded;
    }

    // Scale to fit within 320×320 maintaining aspect ratio
    final double scale = _targetSize / (decoded.width > decoded.height ? decoded.width : decoded.height);
    final int scaledWidth = (decoded.width * scale).round();
    final int scaledHeight = (decoded.height * scale).round();

    // Resize the image
    final img.Image scaled = img.copyResize(
      decoded,
      width: scaledWidth,
      height: scaledHeight,
      interpolation: img.Interpolation.linear,
    );

    // Create a 320×320 canvas with transparent pixels (RGBA 0,0,0,0)
    final img.Image canvas = img.Image(
      width: _targetSize,
      height: _targetSize,
      numChannels: 4,
    );

    // Fill canvas with fully transparent pixels
    img.fill(canvas, color: img.ColorRgba8(0, 0, 0, 0));

    // Center the scaled image on the canvas
    final int offsetX = ((_targetSize - scaledWidth) / 2).round();
    final int offsetY = ((_targetSize - scaledHeight) / 2).round();

    img.compositeImage(canvas, scaled, dstX: offsetX, dstY: offsetY);

    return canvas;
  }

  /// Decode image bytes based on MIME type, ensuring RGBA output.
  static img.Image? _decodeImage(Uint8List bytes, String mimeType) {
    try {
      img.Image? image;

      switch (mimeType) {
        case 'image/png':
          image = img.decodePng(bytes);
          break;
        case 'image/jpeg':
          image = img.decodeJpg(bytes);
          break;
        case 'image/webp':
          image = img.decodeWebP(bytes);
          break;
        case 'image/heic':
        case 'image/heif':
          // The image package supports HEIC decoding via its generic decoder
          image = img.decodeImage(bytes);
          break;
        default:
          return null;
      }

      if (image == null) return null;

      // Ensure RGBA color space (4 channels)
      if (image.numChannels < 4) {
        return image.convert(numChannels: 4);
      }

      return image;
    } catch (e, stackTrace) {
      Logger.error('Error decoding image: $e', tag: _tag, error: e, trace: stackTrace);
      return null;
    }
  }

  // ─── PNG Chunk Constants ───

  /// PNG file signature (8 bytes).
  static const List<int> _pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];

  // ─── TIFF/EXIF Tag IDs ───

  static const int _tagSoftware = 0x0131;
  static const int _tagDocumentName = 0x010D;
  static const int _tagImageDescription = 0x010E;
  static const int _tagOrientation = 0x0112;
  static const int _tagXPosition = 0x011E;
  static const int _tagYPosition = 0x011F;
  static const int _tagTileWidth = 0x0142;
  static const int _tagTileLength = 0x0143;
  static const int _tagExifIfdPointer = 0x8769;

  // ExifIFD (SubIFD) tags
  static const int _tagColorSpace = 0xA001;
  static const int _tagExifImageWidth = 0xA002;
  static const int _tagExifImageLength = 0xA003;

  // ─── TIFF Type Constants ───

  static const int _tiffTypeAscii = 2;
  static const int _tiffTypeShort = 3;
  static const int _tiffTypeLong = 4;
  static const int _tiffTypeRational = 5;

  /// Inject Apple sticker EXIF metadata into PNG bytes.
  /// Strips existing eXIf chunks, then writes the 6 required TIFF/EXIF tags
  /// into a new PNG eXIf chunk.
  ///
  /// Tags written:
  /// - Software: "Apple TextKit"
  /// - DocumentName: "<UUID>0" (uppercase UUID v4 with hyphens + "0" suffix)
  /// - XPosition: 0/1 (RATIONAL)
  /// - YPosition: 0/1 (RATIONAL)
  /// - TileWidth: 320 (SHORT)
  /// - TileLength: 320 (SHORT)
  static Uint8List injectExifMetadata(Uint8List pngBytes) {
    // Parse PNG chunks, stripping any existing eXIf chunks
    final chunks = _parsePngChunks(pngBytes);
    final filteredChunks = chunks.where((c) => c.type != 'eXIf').toList();

    // Build the TIFF/EXIF data for the eXIf chunk
    final exifData = _buildExifData();

    // Create the eXIf chunk
    final exifChunk = _PngChunk('eXIf', exifData);

    // Insert eXIf chunk before the first IDAT chunk
    final idatIndex = filteredChunks.indexWhere((c) => c.type == 'IDAT');
    final insertIndex = idatIndex >= 0 ? idatIndex : filteredChunks.length - 1;
    filteredChunks.insert(insertIndex, exifChunk);

    // Reassemble the PNG
    return _assemblePng(filteredChunks);
  }

  /// Validate that all 6 required EXIF tags are present in the PNG bytes.
  /// Returns true if all tags are found with correct values.
  static bool validateExifTags(Uint8List pngBytes) {
    try {
      final chunks = _parsePngChunks(pngBytes);
      final exifChunk = chunks.where((c) => c.type == 'eXIf').firstOrNull;

      if (exifChunk == null) {
        Logger.warn('No eXIf chunk found in PNG', tag: _tag);
        return false;
      }

      final tags = _parseExifTags(exifChunk.data);
      if (tags == null) return false;

      // Verify all 6 required tags are present
      final hasSoftware = tags.containsKey(_tagSoftware) &&
          tags[_tagSoftware] == 'Apple TextKit';
      final hasDocumentName = tags.containsKey(_tagDocumentName) &&
          _isValidDocumentName(tags[_tagDocumentName] as String?);
      final hasXPosition = tags.containsKey(_tagXPosition) &&
          tags[_tagXPosition] == 0.0;
      final hasYPosition = tags.containsKey(_tagYPosition) &&
          tags[_tagYPosition] == 0.0;
      final hasTileWidth = tags.containsKey(_tagTileWidth) &&
          tags[_tagTileWidth] == 320;
      final hasTileLength = tags.containsKey(_tagTileLength) &&
          tags[_tagTileLength] == 320;

      if (!hasSoftware) Logger.warn('Missing or invalid Software tag', tag: _tag);
      if (!hasDocumentName) Logger.warn('Missing or invalid DocumentName tag', tag: _tag);
      if (!hasXPosition) Logger.warn('Missing or invalid XPosition tag', tag: _tag);
      if (!hasYPosition) Logger.warn('Missing or invalid YPosition tag', tag: _tag);
      if (!hasTileWidth) Logger.warn('Missing or invalid TileWidth tag', tag: _tag);
      if (!hasTileLength) Logger.warn('Missing or invalid TileLength tag', tag: _tag);

      return hasSoftware && hasDocumentName && hasXPosition &&
          hasYPosition && hasTileWidth && hasTileLength;
    } catch (e, stackTrace) {
      Logger.error('Error validating EXIF tags: $e', tag: _tag, error: e, trace: stackTrace);
      return false;
    }
  }

  /// Validates that a DocumentName string matches the expected format:
  /// uppercase UUID v4 with hyphens. Apple emits the bare UUID — no trailing
  /// "0" — so accept either form for forward compatibility.
  static bool _isValidDocumentName(String? name) {
    if (name == null) return false;
    final pattern = RegExp(
      r'^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}0?$',
    );
    return pattern.hasMatch(name);
  }

  // ─── PNG Chunk Parsing ───

  /// Parse a PNG file into its constituent chunks.
  static List<_PngChunk> _parsePngChunks(Uint8List pngBytes) {
    final chunks = <_PngChunk>[];
    final data = ByteData.sublistView(pngBytes);

    // Skip the 8-byte PNG signature
    int offset = 8;

    while (offset < pngBytes.length) {
      // Read chunk length (4 bytes, big-endian)
      final length = data.getUint32(offset, Endian.big);
      offset += 4;

      // Read chunk type (4 bytes ASCII)
      final type = ascii.decode(pngBytes.sublist(offset, offset + 4));
      offset += 4;

      // Read chunk data
      final chunkData = Uint8List.sublistView(pngBytes, offset, offset + length);
      offset += length;

      // Skip CRC (4 bytes) - we'll recalculate on output
      offset += 4;

      chunks.add(_PngChunk(type, chunkData));
    }

    return chunks;
  }

  /// Reassemble PNG from chunks, recalculating CRCs.
  static Uint8List _assemblePng(List<_PngChunk> chunks) {
    final builder = BytesBuilder();

    // Write PNG signature
    builder.add(_pngSignature);

    // Write each chunk
    for (final chunk in chunks) {
      final typeBytes = ascii.encode(chunk.type);

      // Length (4 bytes, big-endian)
      final lengthBytes = ByteData(4)..setUint32(0, chunk.data.length, Endian.big);
      builder.add(lengthBytes.buffer.asUint8List());

      // Type (4 bytes)
      builder.add(typeBytes);

      // Data
      builder.add(chunk.data);

      // CRC32 over type + data
      final crcInput = BytesBuilder();
      crcInput.add(typeBytes);
      crcInput.add(chunk.data);
      final crc = _crc32(crcInput.toBytes());
      final crcBytes = ByteData(4)..setUint32(0, crc, Endian.big);
      builder.add(crcBytes.buffer.asUint8List());
    }

    return builder.toBytes();
  }

  // ─── TIFF/EXIF Data Construction ───

  /// Build the TIFF/EXIF binary data matching Apple's exact sticker layout.
  /// Uses big-endian byte order ("MM"), 9 IFD0 tags, and a SubIFD for
  /// ColorSpace / ExifImageWidth / ExifImageLength.
  ///
  /// Layout (big-endian throughout):
  ///   - TIFF header (8 bytes): "MM" + magic 42 + IFD0 offset
  ///   - IFD0 (9 entries, ascending tag order):
  ///       0x010D DocumentName  ASCII   — UUID v4 uppercase, no trailing "0"
  ///       0x010E ImageDescription ASCII — "missing description"
  ///       0x0112 Orientation   SHORT   — 1
  ///       0x011E XPosition     RATIONAL — 0/1
  ///       0x011F YPosition     RATIONAL — 0/1
  ///       0x0131 Software      ASCII   — "Apple TextKit"
  ///       0x0142 TileWidth     LONG    — 320
  ///       0x0143 TileLength    LONG    — 320
  ///       0x8769 ExifIFDPointer LONG   — offset to SubIFD
  ///   - SubIFD (3 entries):
  ///       0xA001 ColorSpace        SHORT — 1 (sRGB)
  ///       0xA002 ExifImageWidth    LONG  — 320
  ///       0xA003 ExifImageLength   LONG  — 320
  static Uint8List _buildExifData() {
    const endian = Endian.big;
    final uuid = const Uuid().v4().toUpperCase();

    final docNameBytes = ascii.encode(uuid);
    final docNameLen = docNameBytes.length + 1; // +null terminator

    const imageDesc = 'missing description';
    final imageDescBytes = ascii.encode(imageDesc);
    final imageDescLen = imageDescBytes.length + 1;

    const software = 'Apple TextKit';
    final softwareBytes = ascii.encode(software);
    final softwareLen = softwareBytes.length + 1;

    const ifd0TagCount = 9;
    const subIfdTagCount = 3;
    const tagEntrySize = 12;

    // Layout offsets:
    //   [0..8)         TIFF header
    //   [8..ifd0End)   IFD0
    //   ifd0End        next-IFD offset (0)
    //   then data area for IFD0 (strings, rationals)
    //   then SubIFD (3 entries) + next-IFD offset (0)
    //   then SubIFD data area (none — all values inline)
    const tiffHeaderSize = 8;
    const ifd0Start = tiffHeaderSize;
    const ifd0EntriesSize = ifd0TagCount * tagEntrySize;
    const ifd0End = ifd0Start + 2 + ifd0EntriesSize + 4; // count + entries + next-ifd

    // IFD0 data area
    final docNameOffset = ifd0End;
    final imageDescOffset = docNameOffset + docNameLen;
    final softwareOffset = imageDescOffset + imageDescLen;
    final xPositionOffset = softwareOffset + softwareLen;
    final yPositionOffset = xPositionOffset + 8; // RATIONAL is 8 bytes
    final ifd0DataEnd = yPositionOffset + 8;

    // SubIFD: count(2) + 3 entries(36) + next-ifd(4) = 42 bytes
    final subIfdOffset = ifd0DataEnd;
    final subIfdEnd = subIfdOffset + 2 + (subIfdTagCount * tagEntrySize) + 4;

    final totalSize = subIfdEnd;
    final buf = ByteData(totalSize);

    int p = 0;
    // ─── TIFF Header (big-endian "MM") ───
    buf.setUint8(p++, 0x4D); // 'M'
    buf.setUint8(p++, 0x4D); // 'M'
    buf.setUint16(p, 42, endian); p += 2;
    buf.setUint32(p, ifd0Start, endian); p += 4;

    // ─── IFD0 ───
    buf.setUint16(p, ifd0TagCount, endian); p += 2;

    // 0x010D DocumentName, ASCII, count=docNameLen, offset=docNameOffset
    p = _writeEntryOffset(buf, p, _tagDocumentName, _tiffTypeAscii, docNameLen, docNameOffset, endian);
    // 0x010E ImageDescription
    p = _writeEntryOffset(buf, p, _tagImageDescription, _tiffTypeAscii, imageDescLen, imageDescOffset, endian);
    // 0x0112 Orientation, SHORT, count=1, value=1 (inline)
    p = _writeEntryShortInline(buf, p, _tagOrientation, 1, endian);
    // 0x011E XPosition, RATIONAL, count=1, offset
    p = _writeEntryOffset(buf, p, _tagXPosition, _tiffTypeRational, 1, xPositionOffset, endian);
    // 0x011F YPosition, RATIONAL, count=1, offset
    p = _writeEntryOffset(buf, p, _tagYPosition, _tiffTypeRational, 1, yPositionOffset, endian);
    // 0x0131 Software, ASCII
    p = _writeEntryOffset(buf, p, _tagSoftware, _tiffTypeAscii, softwareLen, softwareOffset, endian);
    // 0x0142 TileWidth, LONG, count=1, value=320 (inline)
    p = _writeEntryLongInline(buf, p, _tagTileWidth, 320, endian);
    // 0x0143 TileLength, LONG, count=1, value=320 (inline)
    p = _writeEntryLongInline(buf, p, _tagTileLength, 320, endian);
    // 0x8769 ExifIFDPointer, LONG, count=1, value=subIfdOffset (inline)
    p = _writeEntryLongInline(buf, p, _tagExifIfdPointer, subIfdOffset, endian);

    // Next IFD offset (0 = none)
    buf.setUint32(p, 0, endian); p += 4;

    // ─── IFD0 data area ───
    // DocumentName
    for (final b in docNameBytes) { buf.setUint8(p++, b); }
    buf.setUint8(p++, 0);
    // ImageDescription
    for (final b in imageDescBytes) { buf.setUint8(p++, b); }
    buf.setUint8(p++, 0);
    // Software
    for (final b in softwareBytes) { buf.setUint8(p++, b); }
    buf.setUint8(p++, 0);
    // XPosition: 0/1
    buf.setUint32(p, 0, endian); p += 4;
    buf.setUint32(p, 1, endian); p += 4;
    // YPosition: 0/1
    buf.setUint32(p, 0, endian); p += 4;
    buf.setUint32(p, 1, endian); p += 4;

    // ─── SubIFD (ExifIFD) ───
    buf.setUint16(p, subIfdTagCount, endian); p += 2;
    // 0xA001 ColorSpace, SHORT, count=1, value=1 (sRGB)
    p = _writeEntryShortInline(buf, p, _tagColorSpace, 1, endian);
    // 0xA002 ExifImageWidth, LONG, count=1, value=320
    p = _writeEntryLongInline(buf, p, _tagExifImageWidth, 320, endian);
    // 0xA003 ExifImageLength, LONG, count=1, value=320
    p = _writeEntryLongInline(buf, p, _tagExifImageLength, 320, endian);
    // SubIFD next-IFD offset (0)
    buf.setUint32(p, 0, endian); p += 4;

    return buf.buffer.asUint8List();
  }

  /// Write a 12-byte IFD entry whose value lives at an offset.
  static int _writeEntryOffset(
      ByteData buf, int p, int tag, int type, int count, int valueOffset, Endian endian) {
    buf.setUint16(p, tag, endian); p += 2;
    buf.setUint16(p, type, endian); p += 2;
    buf.setUint32(p, count, endian); p += 4;
    buf.setUint32(p, valueOffset, endian); p += 4;
    return p;
  }

  /// Write a 12-byte IFD entry for a single SHORT value stored inline.
  /// In TIFF, when value fits in ≤4 bytes, it goes in the value field
  /// left-aligned; for SHORT (2 bytes) the high 2 bytes of the value field
  /// are zero (in either endian, semantically).
  static int _writeEntryShortInline(ByteData buf, int p, int tag, int value, Endian endian) {
    buf.setUint16(p, tag, endian); p += 2;
    buf.setUint16(p, _tiffTypeShort, endian); p += 2;
    buf.setUint32(p, 1, endian); p += 4;
    // Value field: 4 bytes, BE -> first 2 bytes hold the SHORT, last 2 are 0
    buf.setUint16(p, value, endian); p += 2;
    buf.setUint16(p, 0, endian); p += 2;
    return p;
  }

  /// Write a 12-byte IFD entry for a single LONG value stored inline.
  static int _writeEntryLongInline(ByteData buf, int p, int tag, int value, Endian endian) {
    buf.setUint16(p, tag, endian); p += 2;
    buf.setUint16(p, _tiffTypeLong, endian); p += 2;
    buf.setUint32(p, 1, endian); p += 4;
    buf.setUint32(p, value, endian); p += 4;
    return p;
  }

  // ─── EXIF Tag Parsing (for validation) ───

  /// Parse EXIF tags from TIFF data in an eXIf chunk.
  /// Returns a map of tag ID → value, or null on parse failure.
  static Map<int, dynamic>? _parseExifTags(Uint8List tiffData) {
    if (tiffData.length < 8) return null;

    final data = ByteData.sublistView(tiffData);

    // Determine byte order
    final byteOrder = tiffData[0] == 0x49 ? Endian.little : Endian.big;

    // Verify magic number
    final magic = data.getUint16(2, byteOrder);
    if (magic != 42) return null;

    // Get IFD0 offset
    final ifdOffset = data.getUint32(4, byteOrder);
    if (ifdOffset >= tiffData.length) return null;

    // Read tag count
    final tagCount = data.getUint16(ifdOffset, byteOrder);
    final tags = <int, dynamic>{};

    int pos = ifdOffset + 2;
    for (int i = 0; i < tagCount; i++) {
      if (pos + 12 > tiffData.length) break;

      final tagId = data.getUint16(pos, byteOrder);
      final type = data.getUint16(pos + 2, byteOrder);
      final count = data.getUint32(pos + 4, byteOrder);
      final valueField = pos + 8;

      switch (type) {
        case _tiffTypeAscii:
          // ASCII string - if > 4 bytes, value field is an offset
          final totalBytes = count;
          int strOffset;
          if (totalBytes <= 4) {
            strOffset = valueField;
          } else {
            strOffset = data.getUint32(valueField, byteOrder);
          }
          if (strOffset + totalBytes <= tiffData.length) {
            // Read string (excluding null terminator)
            final strBytes = tiffData.sublist(strOffset, strOffset + totalBytes - 1);
            tags[tagId] = ascii.decode(strBytes);
          }
          break;
        case _tiffTypeShort:
          // SHORT (2 bytes) - value stored inline
          tags[tagId] = data.getUint16(valueField, byteOrder);
          break;
        case 4: // LONG
          // LONG (4 bytes) - value stored inline
          tags[tagId] = data.getUint32(valueField, byteOrder);
          break;
        case _tiffTypeRational:
          // RATIONAL (8 bytes: num/denom) - value field is offset
          final ratOffset = data.getUint32(valueField, byteOrder);
          if (ratOffset + 8 <= tiffData.length) {
            final numerator = data.getUint32(ratOffset, byteOrder);
            final denominator = data.getUint32(ratOffset + 4, byteOrder);
            tags[tagId] = denominator != 0 ? numerator / denominator : 0.0;
          }
          break;
      }

      pos += 12;
    }

    return tags;
  }

  // ─── CRC32 for PNG Chunks ───

  /// CRC32 lookup table for PNG chunk CRC calculation.
  static final List<int> _crc32Table = _buildCrc32Table();

  static List<int> _buildCrc32Table() {
    final table = List<int>.filled(256, 0);
    for (int n = 0; n < 256; n++) {
      int c = n;
      for (int k = 0; k < 8; k++) {
        if ((c & 1) != 0) {
          c = 0xEDB88320 ^ (c >> 1);
        } else {
          c = c >> 1;
        }
      }
      table[n] = c;
    }
    return table;
  }

  /// Calculate CRC32 for PNG chunk (type + data).
  static int _crc32(Uint8List bytes) {
    int crc = 0xFFFFFFFF;
    for (int i = 0; i < bytes.length; i++) {
      crc = _crc32Table[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
  }

  // ─── Pipeline Constants ───

  /// Maximum allowed source file size in bytes (2MB).
  static const int _maxSourceFileSize = 2 * 1024 * 1024;

  /// Maximum allowed output file size in bytes (500KB).
  static const int _maxOutputFileSize = 500 * 1024;

  /// Maximum duration for the full processing pipeline.
  static const Duration _processTimeout = Duration(milliseconds: 500);

  /// Process a sticker image for sending.
  /// Returns processed PNG bytes ready for MMCS upload, or null on failure.
  ///
  /// Pipeline:
  /// 1. Validate input file size ≤ 2MB
  /// 2. Read source bytes (from `bytes` field or `path`)
  /// 3. Determine MIME type from file extension/name
  /// 4. Resize to 320×320 (delegates to [resize])
  /// 5. Encode to PNG
  /// 6. Inject Apple sticker EXIF metadata
  /// 7. Validate that all 6 required EXIF tags are present
  /// 8. Ensure output ≤ 500KB (apply max compression if needed)
  ///
  /// The entire pipeline is bounded by a 500ms timeout. Any failure (including
  /// timeout) returns null; the caller is responsible for fallback behavior.
  static Future<Uint8List?> process(PlatformFile file) async {
    try {
      return await _runPipeline(file).timeout(
        _processTimeout,
        onTimeout: () {
          Logger.warn(
            'Sticker processing exceeded ${_processTimeout.inMilliseconds}ms timeout',
            tag: _tag,
          );
          return null;
        },
      );
    } catch (e, stackTrace) {
      Logger.error(
        'Sticker processing failed: $e',
        tag: _tag,
        error: e,
        trace: stackTrace,
      );
      return null;
    }
  }

  /// Internal pipeline body. Returns null on any failure.
  static Future<Uint8List?> _runPipeline(PlatformFile file) async {
    // 1. Validate input file size
    if (file.size > _maxSourceFileSize) {
      Logger.warn(
        'Sticker source file exceeds $_maxSourceFileSize bytes: ${file.size}',
        tag: _tag,
      );
      return null;
    }

    // 2. Read source bytes (prefer in-memory bytes, fall back to disk)
    final Uint8List? sourceBytes = await _readBytes(file);
    if (sourceBytes == null) {
      Logger.warn('Failed to read sticker source bytes for ${file.name}', tag: _tag);
      return null;
    }

    // Re-validate size against actual byte length in case `file.size` was stale
    if (sourceBytes.length > _maxSourceFileSize) {
      Logger.warn(
        'Sticker source bytes exceed $_maxSourceFileSize: ${sourceBytes.length}',
        tag: _tag,
      );
      return null;
    }

    // PASS-THROUGH: If the source PNG already has valid Apple sticker EXIF,
    // send it byte-for-byte without re-processing. This preserves the exact
    // binary structure that iOS expects.
    if (file.name.endsWith('.png') && sourceBytes.length <= _maxOutputFileSize) {
      if (validateExifTags(sourceBytes)) {
        Logger.info('Source already has valid sticker EXIF, passing through unchanged (${sourceBytes.length} bytes)', tag: _tag);
        return sourceBytes;
      }
    }

    // 3. Determine MIME type from extension/name
    final String? mimeType = _resolveMimeType(file);
    if (mimeType == null) {
      Logger.warn('Could not determine MIME type for sticker ${file.name}', tag: _tag);
      return null;
    }

    // 4. Resize to 320×320
    final img.Image? resized = await resize(sourceBytes, mimeType);
    if (resized == null) {
      Logger.warn('Sticker resize returned null for ${file.name}', tag: _tag);
      return null;
    }

    // 5. Encode to PNG with max compression
    final Uint8List pngBytes = img.encodePng(resized, level: 9);

    // 6. Inject EXIF metadata
    final Uint8List exifBytes = injectExifMetadata(pngBytes);

    // 7. Validate EXIF tags
    if (!validateExifTags(exifBytes)) {
      Logger.warn('Sticker EXIF validation failed after injection', tag: _tag);
      return null;
    }

    // 8. Final size check
    if (exifBytes.length > _maxOutputFileSize) {
      Logger.warn(
        'Sticker output exceeds $_maxOutputFileSize after compression: ${exifBytes.length}',
        tag: _tag,
      );
      return null;
    }

    return exifBytes;
  }

  /// Read bytes from a [PlatformFile], preferring the in-memory `bytes` field
  /// and falling back to reading from `path`.
  static Future<Uint8List?> _readBytes(PlatformFile file) async {
    if (file.bytes != null && file.bytes!.isNotEmpty) {
      return file.bytes!;
    }
    final path = file.path;
    if (path == null || path.isEmpty) return null;
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (e, stackTrace) {
      Logger.error(
        'Failed to read sticker bytes from disk: $e',
        tag: _tag,
        error: e,
        trace: stackTrace,
      );
      return null;
    }
  }

  /// Resolve a MIME type for a [PlatformFile] using its name or path. Falls
  /// back to a small extension map for the formats we support.
  static String? _resolveMimeType(PlatformFile file) {
    final candidates = <String>[
      file.name,
      if (file.path != null) file.path!,
    ];

    for (final candidate in candidates) {
      final detected = mime(candidate);
      if (detected != null) return detected.toLowerCase();
    }

    // Fallback: derive from extension manually for the formats we accept.
    final ext = (file.extension ?? _extensionFrom(file.name) ?? '').toLowerCase();
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';
      default:
        return null;
    }
  }

  static String? _extensionFrom(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return null;
    return name.substring(dot + 1);
  }
}

/// Internal representation of a PNG chunk.
class _PngChunk {
  final String type;
  final Uint8List data;

  _PngChunk(this.type, this.data);
}
