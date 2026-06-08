import 'dart:typed_data';

import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:mime_type/mime_type.dart';
import 'package:path/path.dart' hide context;
import 'package:universal_io/io.dart';

class StickerPicker extends StatefulWidget {
  StickerPicker({
    super.key,
    required this.controller,
  });
  final ConversationViewController controller;

  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends OptimizedState<StickerPicker> {
  List<File> _stickers = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    loadStickers();
  }

  Future<void> loadStickers() async {
    try {
      final stickerDir = await fs.stickersDirectory;
      final dir = Directory(stickerDir);
      if (await dir.exists()) {
        final entities = dir.listSync();
        _stickers = entities
            .whereType<File>()
            .where((f) {
              // Exclude the animated .heics companion files: they sit next to
              // the still PNG thumbnail (icloud_<id>.png) and are decoded to
              // APNG lazily on-select. Showing them would duplicate the grid.
              if (f.path.toLowerCase().endsWith('.heics')) return false;
              final mimeType = mime(f.path);
              return mimeType != null && mimeType.startsWith('image/');
            })
            .toList();
        // Sort by most recently modified first
        _stickers.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      }
    } catch (e) {
      Logger.error('Failed to load stickers', error: e);
    }
    _loading = false;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SizedBox(
        height: 300,
        child: Center(child: buildProgressIndicator(context)),
      );
    }

    if (_stickers.isEmpty) {
      return SizedBox(
        height: 300,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  iOS ? CupertinoIcons.smiley : Icons.emoji_emotions_outlined,
                  size: 48,
                  color: context.theme.colorScheme.outline,
                ),
                const SizedBox(height: 12),
                Text(
                  'No stickers saved yet',
                  style: context.theme.textTheme.bodyLarge?.copyWith(
                    color: context.theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Save images as stickers from the attachment viewer,\nor add image files to the stickers folder.',
                  textAlign: TextAlign.center,
                  style: context.theme.textTheme.bodySmall?.copyWith(
                    color: context.theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 300,
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: CustomScrollView(
          scrollDirection: Axis.horizontal,
          slivers: [
            SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              delegate: SliverChildBuilderDelegate(
                childCount: _stickers.length,
                (context, index) {
                  return _StickerPickerFile(
                    file: _stickers[index],
                    controller: widget.controller,
                    onTap: () async {
                      final file = _stickers[index];

                      // Prefer the animated .heics companion when it exists so
                      // Live Stickers send as the original Apple HEIC-sequence
                      // (which iOS renders as a native animated sticker). The
                      // grid tile shows the still PNG (icloud_<id>.png); its
                      // companion is icloud_<id>.heics next to it.
                      File sendFile = file;
                      final lower = file.path.toLowerCase();
                      if (lower.endsWith('.png')) {
                        final heicsPath =
                            '${file.path.substring(0, file.path.length - 4)}.heics';
                        if (await File(heicsPath).exists()) {
                          sendFile = File(heicsPath);
                        }
                      }

                      final bytes = await sendFile.readAsBytes();
                      final name = basename(sendFile.path);

                      // Check if already selected — deselect. Match on either
                      // the still PNG (tile identity) or the .heics we actually
                      // queue, so a second tap always toggles off.
                      final existing =
                          widget.controller.pickedAttachments.firstWhereOrNull(
                              (e) =>
                                  e.path == file.path || e.path == sendFile.path);
                      if (existing != null) {
                        widget.controller.pickedAttachments.removeWhere(
                            (e) =>
                                e.path == file.path || e.path == sendFile.path);
                        // Clear sticker flag if no attachments remain
                        if (widget.controller.pickedAttachments.isEmpty) {
                          widget.controller.isStickerSend = false;
                        }
                      } else {
                        widget.controller.pickedAttachments.add(PlatformFile(
                          path: sendFile.path,
                          name: name,
                          size: bytes.length,
                        ));
                        widget.controller.isStickerSend = true;
                      }
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StickerPickerFile extends StatefulWidget {
  _StickerPickerFile({
    required this.file,
    required this.controller,
    required this.onTap,
  });
  final File file;
  final ConversationViewController controller;
  final Function() onTap;

  @override
  State<_StickerPickerFile> createState() => _StickerPickerFileState();
}

class _StickerPickerFileState extends OptimizedState<_StickerPickerFile>
    with AutomaticKeepAliveClientMixin {
  Uint8List? image;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final path = widget.file.path;
      final mimeType = mime(path);
      if (mimeType == 'image/heic' ||
          mimeType == 'image/heif' ||
          mimeType == 'image/tif' ||
          mimeType == 'image/tiff') {
        final fakeAttachment = Attachment(
          transferName: path,
          mimeType: mimeType!,
        );
        image = await as.loadAndGetProperties(fakeAttachment,
            actualPath: path, onlyFetchData: true, isPreview: true);
      } else {
        image = await widget.file.readAsBytes();
      }
      setState(() {});

      // If this sticker has an animated (.heics) companion and Live Stickers
      // are enabled, decode/load the animated APNG in the background and swap
      // it in once ready. The still image above is shown immediately so the
      // grid never blocks or flashes blank while decoding.
      _swapInAnimated(path);
    } catch (e) {
      Logger.error('Failed to load sticker thumbnail', error: e);
    }
  }

  /// If [stillPath] (icloud_<id>.png) has an animated .heics companion and Live
  /// Stickers are enabled, decode/load the animated APNG (caching on first use
  /// via the same native pipeline as chat Live Stickers) and swap it into the
  /// thumbnail. No-op when there's no animated version, the setting is off, or
  /// the platform can't decode it — the still image already shown remains.
  Future<void> _swapInAnimated(String stillPath) async {
    try {
      if (kIsDesktop) return;
      if (!ss.settings.liveStickerAnimateNoAlpha.value) return;
      if ((fs.androidInfo?.version.sdkInt ?? 0) < 28) return;
      if (!stillPath.toLowerCase().endsWith('.png')) return;

      final heicsPath = '${stillPath.substring(0, stillPath.length - 4)}.heics';
      if (!await File(heicsPath).exists()) return;

      final apngFile = File('$heicsPath.apng');
      Uint8List? animated;

      // Use the cached APNG if we already decoded it, else decode once.
      if (await apngFile.exists() && await apngFile.length() > 0) {
        animated = await apngFile.readAsBytes();
      } else {
        final decoded = await mcs.invokeMethod("decode-heic-sequence", {
          "file": heicsPath,
          "animateNoAlpha": true,
          "blackThreshold": ss.settings.liveStickerBlackThreshold.value,
        });
        if (decoded is Uint8List && decoded.isNotEmpty) {
          await apngFile.writeAsBytes(decoded);
          animated = decoded;
        }
      }

      if (animated != null && mounted) {
        image = animated;
        setState(() {});
      }
    } catch (e) {
      Logger.warn('Animated sticker decode failed: $e', tag: 'StickerPicker');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Obx(() {
      // The tile may have queued its animated .heics companion instead of the
      // still PNG, so match on either path for the selection indicator.
      final stillPath = widget.file.path;
      final heicsPath = stillPath.toLowerCase().endsWith('.png')
          ? '${stillPath.substring(0, stillPath.length - 4)}.heics'
          : null;
      bool containsThis = widget.controller.pickedAttachments.firstWhereOrNull(
              (e) => e.path == stillPath || e.path == heicsPath) !=
          null;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        margin: EdgeInsets.all(containsThis ? 10 : 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: widget.onTap,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              if (image != null)
                Image.memory(
                  image!,
                  // Use contain (not cover) so the whole sticker fits inside
                  // the tile. cover fills the square and crops the overflow,
                  // clipping non-square stickers at the edges.
                  fit: BoxFit.contain,
                  width: 150,
                  height: 150,
                  cacheWidth: 300,
                  frameBuilder:
                      (context, child, frame, wasSynchronouslyLoaded) {
                    if (frame == null) {
                      return Positioned.fill(
                        child: Container(
                          color: context.theme.colorScheme.properSurface,
                        ),
                      );
                    } else {
                      return child;
                    }
                  },
                ),
              if (image == null)
                Positioned.fill(
                  child: Container(
                    color: context.theme.colorScheme.properSurface,
                    alignment: Alignment.center,
                    child: buildProgressIndicator(context),
                  ),
                ),
              if (containsThis)
                Container(
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: context.theme.colorScheme.primary),
                  child: Padding(
                    padding: const EdgeInsets.all(5.0),
                    child: Icon(
                      iOS ? CupertinoIcons.check_mark : Icons.check,
                      color: context.theme.colorScheme.onPrimary,
                      size: 18,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }

  @override
  bool get wantKeepAlive => true;
}
