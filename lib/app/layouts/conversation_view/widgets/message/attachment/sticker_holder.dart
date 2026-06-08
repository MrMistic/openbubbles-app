import 'dart:async';

import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:universal_io/io.dart';

class StickerHolder extends StatefulWidget {
  StickerHolder({super.key, required this.stickerMessages, required this.controller});
  final Iterable<Message> stickerMessages;
  final ConversationViewController controller;

  @override
  State<StickerHolder> createState() => _StickerHolderState();
}

class _StickerHolderState extends OptimizedState<StickerHolder> with AutomaticKeepAliveClientMixin {
  Iterable<Message> get messages => widget.stickerMessages;
  ConversationViewController get controller => widget.controller;
  
  bool _visible = true;
  int renderedStickers = 0;

  @override
  void initState() {
    super.initState();
    updateObx(() {
      loadStickers();
    });
  }

  Future<void> loadStickers() async {
    if (renderedStickers == messages.length) return;
    renderedStickers = messages.length;
    for (Message msg in messages) {
      for (Attachment? attachment in msg.attachments) {
        // If we've already loaded it, don't try again
        if (controller.stickerData.keys.contains(attachment!.guid)) continue;

        final pathName = attachment.path;
        if (await FileSystemEntity.type(pathName) == FileSystemEntityType.notFound) {
          attachmentDownloader.startDownload(attachment, onComplete: (_) async {
            await checkImage(msg, attachment);
          });
        } else {
          await checkImage(msg, attachment);
        }
      }
    }
  }

  Future<void> checkImage(Message message, Attachment attachment) async {
    try {
      String pathName = attachment.path;

      // Check for animated HEIC sequence (Live Stickers)
      if (attachment.mimeType?.contains('image/heic-sequence') == true) {
        Logger.info("[HEIC-SEQ] sticker_holder: detected image/heic-sequence, path=$pathName");
        final apngPath = "$pathName.apng";
        bool apngCacheValid = false;
        if (await File(apngPath).exists()) {
          try {
            apngCacheValid = await File(apngPath).length() > 0;
          } catch (_) {
            apngCacheValid = false;
          }
          if (!apngCacheValid) {
            Logger.warn("[HEIC-SEQ] sticker_holder: stale 0-byte .apng cache at $apngPath, deleting");
            try { await File(apngPath).delete(); } catch (_) {}
          }
        }
        if (apngCacheValid) {
          Logger.info("[HEIC-SEQ] sticker_holder: cache hit at $apngPath");
          pathName = apngPath;
        } else if (!kIsDesktop && (fs.androidInfo?.version.sdkInt ?? 0) >= 28
            && ss.settings.liveStickerAnimateNoAlpha.value) {
          Logger.info("[HEIC-SEQ] sticker_holder: no cache, invoking decode-heic-sequence (animateNoAlpha=true)");
          try {
            final bytes = await mcs.invokeMethod("decode-heic-sequence", {
              "file": pathName,
              "animateNoAlpha": true,
              "blackThreshold": ss.settings.liveStickerBlackThreshold.value,
            });
            if (bytes != null) {
              Logger.info("[HEIC-SEQ] sticker_holder: decode success, ${bytes.length} bytes, caching");
              await File(apngPath).writeAsBytes(bytes);
              pathName = apngPath;
            } else {
              Logger.warn("[HEIC-SEQ] sticker_holder: decode returned null, falling back to still-frame");
              final pngPath = "$pathName.png";
              final converted = await as.convertHeicToPng(sourcePath: pathName, outputPath: pngPath);
              if (converted != null) pathName = converted.path;
            }
          } catch (e) {
            Logger.warn("[HEIC-SEQ] sticker_holder: decode exception: $e, falling back to still-frame");
            final pngPath = "$pathName.png";
            final converted = await as.convertHeicToPng(sourcePath: pathName, outputPath: pngPath);
            if (converted != null) pathName = converted.path;
          }
        } else {
          // Either API < 28, desktop, or user opted for static-with-alpha
          // (liveStickerAnimateNoAlpha=false). Use the HeifCoder still-frame
          // path which preserves transparency.
          if (!kIsDesktop) {
            Logger.info("[HEIC-SEQ] sticker_holder: using still-frame fallback (animateNoAlpha=${ss.settings.liveStickerAnimateNoAlpha.value})");
            final pngPath = "$pathName.png";
            final converted = await as.convertHeicToPng(sourcePath: pathName, outputPath: pngPath);
            if (converted != null) pathName = converted.path;
          }
        }
      } else if (attachment.mimeType?.contains('image/hei') == true) {
        // Check for HEIC and use converted PNG if available, or convert
        if (!kIsDesktop) {
          final pngPath = "$pathName.png";
          final converted = await as.convertHeicToPng(sourcePath: pathName, outputPath: pngPath);
          if (converted != null) pathName = converted.path;
        }
      }

      // Check via the image package to make sure this is a valid, render-able image
      // final image = await compute(decodeIsolate, PlatformFile(
      //     path: pathName,
      //     name: attachment.transferName!,
      //     bytes: attachment.bytes,
      //     size: attachment.totalBytes ?? 0,
      //   ),
      // );
      final bytes = await File(pathName).readAsBytes();
      Logger.info("[HEIC-SEQ] sticker_holder: final load from $pathName, ${bytes.length} bytes, mime=${attachment.mimeType}");
      var stickerData = message.attributedBody.firstOrNull?.runs
        .firstWhereOrNull((element) => element.attributes?.attachmentGuid == attachment.guid)?.attributes?.stickerData;
      controller.stickerData[message.guid!] = {
        attachment.guid!: (bytes, stickerData)
      };
      Logger.debug("sticker count ${controller.stickerData.length}");
      setState(() {});
    } catch (e, stack) {
      Logger.error("Failed to load sticker image", error: e, trace: stack);
    }
  }

  @override
  void didUpdateWidget(StickerHolder oldWidget) { 
    super.didUpdateWidget(oldWidget);
    Logger.debug("ugh why ${messages.length}");
    updateObx(() {
      loadStickers();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final guids = messages.map((e) => e.guid!);
    final stickers = controller.stickerData.entries.where((element) => guids.contains(element.key)).map((e) => e.value);
    if (stickers.isEmpty) return const SizedBox.shrink();

    final data = stickers.map((e) => e.values).expand((element) => element);
    return Positioned(top: -20, left: -20, right: -20, bottom: -20, child: GestureDetector(
      onTap: () {
        setState(() {
          _visible = !_visible;
        });
      },
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: _visible ? 1.0 : 0.25,
        child: Stack(
          children: data.map((e) => Container(
            child: Transform.rotate(
              angle: e.$2?.rotation ?? 0,
              alignment: FractionalOffset(e.$2?.normalizedX ?? .5, e.$2?.normalizedY ?? .5),
              child: Transform.scale(
                child: Image.memory(
                  e.$1,
                  scale: .01,
                  gaplessPlayback: true,
                  cacheHeight: 200,
                  filterQuality: FilterQuality.none,
                  errorBuilder: (context, error, stackTrace) {
                    return const SizedBox.shrink();
                  },
                ),
                scale: e.$2?.scale ?? 1,
              ),
            ),
            alignment: FractionalOffset(e.$2?.normalizedX ?? .5, e.$2?.normalizedY ?? .5),
          )).toList(),
        )
      ),
    ));
  }

  @override
  bool get wantKeepAlive => true;
}
