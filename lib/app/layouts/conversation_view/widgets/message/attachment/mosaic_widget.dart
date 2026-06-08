import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/tail_clipper.dart';
import 'package:bluebubbles/app/layouts/fullscreen_media/fullscreen_holder.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:tuple/tuple.dart';

/// Renders multiple image attachments in an iMessage-style z-stacked carousel
/// within a single message bubble. The front image is displayed at full size,
/// with subsequent images peeking behind it. Horizontal swipe navigates between
/// images.
class MosaicWidget extends StatefulWidget {
  const MosaicWidget({
    super.key,
    required this.attachments,
    required this.message,
    required this.isFromMe,
    required this.showTail,
    this.controller,
    this.onTileLongPress,
    this.onTileDoubleTap,
  });

  final List<Attachment> attachments;
  final Message message;
  final bool isFromMe;
  final bool showTail;
  final ConversationViewController? controller;
  /// Called when a tile is long-pressed, with the image's part index.
  final void Function(int partIndex)? onTileLongPress;
  /// Called when a tile is double-tapped, with the image's part index.
  final void Function(int partIndex)? onTileDoubleTap;

  @override
  State<MosaicWidget> createState() => _MosaicWidgetState();
}

class _MosaicWidgetState extends State<MosaicWidget> {
  /// Cached image data per attachment guid.
  final Map<String, Uint8List?> _imageData = {};

  /// Cached decoded image dimensions per attachment guid.
  final Map<String, Size> _imageSizes = {};

  /// Track loading state per attachment: true = loaded, false = failed/loading.
  final Map<String, bool> _loadState = {};

  /// Stream subscriptions for download error listeners (cleaned up on dispose).
  final List<StreamSubscription> _errorSubs = [];

  /// Current page index in the carousel.
  final ValueNotifier<int> _currentPage = ValueNotifier(0);

  late final PageController _pageController;

  List<Attachment> get attachments => widget.attachments;
  Message get message => widget.message;
  bool get isFromMe => widget.isFromMe;
  ConversationViewController? get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    // Reset the carousel page tracker so reactions/replies start aimed at
    // the first image when the widget rebuilds.
    if (message.guid != null) {
      getActiveMwc(message.guid!)?.carouselPage.value = 0;
    }
    _loadImages();
  }

  @override
  void dispose() {
    for (final sub in _errorSubs) {
      sub.cancel();
    }
    _pageController.dispose();
    _currentPage.dispose();
    super.dispose();
  }

  void _loadImages() {
    if (controller == null) return;
    for (int i = 0; i < attachments.length; i++) {
      final att = attachments[i];
      final cached = controller!.imageData[att.guid];
      if (cached != null) {
        _imageData[att.guid!] = cached;
        _loadState[att.guid!] = true;
      } else {
        _loadState[att.guid!] = false;
        _queueImage(att);
      }
    }
  }

  void _queueImage(Attachment att) async {
    if (controller == null) return;

    // For outgoing/temp messages, the file lives locally (in attachment.bytes
    // or at attachment.sourcePath/path) — skip the download check and queue
    // the file directly. as.getContent treats temp guids as upload-progress
    // probes, so we'd never get a PlatformFile back from it.
    final isTemp = (att.guid?.startsWith("temp") ?? false) ||
        (message.guid?.contains("temp") ?? false);
    if (isTemp) {
      _queueImageFromFile(att, att.getFile());
      return;
    }

    // Check if the file actually exists on disk. If not, we need to download
    // it first (just like AttachmentHolder does via as.getContent).
    final content = as.getContent(att, onComplete: (file) {
      // Download completed — now queue the image for display
      if (!mounted) return;
      _queueImageFromFile(att, file);
    });

    if (content is PlatformFile) {
      // File already exists on disk — queue it directly
      _queueImageFromFile(att, content);
    } else if (content is AttachmentDownloadController) {
      // Download is in progress or was just started — wait for completion
      // The onComplete callback above will handle it. Also listen for errors.
      _errorSubs.add(content.error.listen((hasError) {
        if (hasError && mounted) {
          setState(() {
            _loadState[att.guid!] = false;
            _imageData[att.guid!] = null;
          });
        }
      }));
    } else if (content is Attachment) {
      // Auto-download is disabled and file doesn't exist — show error state
      // so the user can tap retry (which will force a download).
      if (mounted) {
        setState(() {
          _loadState[att.guid!] = false;
          _imageData[att.guid!] = null;
        });
      }
    }
  }

  void _queueImageFromFile(Attachment att, PlatformFile file) async {
    if (controller == null || !mounted) return;
    final completer = Completer<Uint8List>();

    controller!.queueImage(Tuple4(att, file, context, completer));

    try {
      final data = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => Uint8List(0),
      );
      if (!mounted) return;
      if (data.isNotEmpty) {
        // Decode image dimensions for proper aspect ratio sizing
        _resolveImageSize(att.guid!, data);
        setState(() {
          _imageData[att.guid!] = data;
          _loadState[att.guid!] = true;
        });
      } else {
        setState(() {
          _loadState[att.guid!] = false;
          _imageData[att.guid!] = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadState[att.guid!] = false;
        _imageData[att.guid!] = null;
      });
    }
  }

  /// Decode image dimensions from bytes and cache them for layout sizing.
  void _resolveImageSize(String guid, Uint8List data) async {
    if (_imageSizes.containsKey(guid)) return;
    try {
      final codec = await ui.instantiateImageCodec(data);
      final frame = await codec.getNextFrame();
      final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      frame.image.dispose();
      codec.dispose();
      if (mounted && !_imageSizes.containsKey(guid)) {
        setState(() {
          _imageSizes[guid] = size;
        });
      }
    } catch (_) {
      // If decoding fails, we'll just use the fallback aspect ratio
    }
  }

  void _retryImage(Attachment att) {
    setState(() {
      _loadState.remove(att.guid!);
      _imageData.remove(att.guid!);
    });
    // Force a download on retry (override auto-download setting)
    final content = attachmentDownloader.startDownload(att, onComplete: (file) {
      if (!mounted) return;
      _queueImageFromFile(att, file);
    }, onError: () {
      if (!mounted) return;
      setState(() {
        _loadState[att.guid!] = false;
        _imageData[att.guid!] = null;
      });
    });
  }

  void _openFullscreen(int index) {
    Navigator.of(Get.context!).push(
      MaterialPageRoute(
        builder: (context) => FullscreenMediaHolder(
          attachment: attachments[index],
          showInteractions: true,
          currentChat: cm.activeChat,
          scopedAttachments: attachments,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (attachments.length < 2) return const SizedBox.shrink();

    final availableWidth = ns.width(context) * 0.5;
    // Use the first loaded image's actual dimensions for aspect ratio.
    // Fall back to attachment metadata, then to 4:3 default.
    double aspectRatio = 4 / 3;
    final firstGuid = attachments[0].guid;
    if (firstGuid != null && _imageSizes.containsKey(firstGuid)) {
      final size = _imageSizes[firstGuid]!;
      if (size.height > 0) {
        aspectRatio = size.width / size.height;
      }
    } else {
      final firstAtt = attachments[0];
      if (firstAtt.width != null && firstAtt.height != null && firstAtt.height! > 0) {
        aspectRatio = firstAtt.width! / firstAtt.height!;
      }
    }
    // Clamp aspect ratio to avoid extremely tall or wide carousels
    aspectRatio = aspectRatio.clamp(0.5, 2.0);
    final cardHeight = availableWidth / aspectRatio;
    // Add space for stacked cards peeking behind + page indicator
    final stackPeekHeight = 12.0;
    final indicatorHeight = 20.0;
    final totalHeight = cardHeight + stackPeekHeight + indicatorHeight;

    Widget carousel = SizedBox(
      width: availableWidth,
      height: totalHeight,
      child: Column(
        children: [
          // Stacked card carousel
          SizedBox(
            width: availableWidth,
            height: cardHeight + stackPeekHeight,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                // Background cards - rebuild only when page changes
                ValueListenableBuilder<int>(
                  valueListenable: _currentPage,
                  builder: (context, page, _) => Stack(
                    children: _buildBackgroundCards(availableWidth, cardHeight),
                  ),
                ),
                // Foreground PageView - never rebuilds from page change
                Positioned(
                  top: stackPeekHeight,
                  left: 0,
                  right: 0,
                  height: cardHeight,
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: attachments.length,
                    onPageChanged: (index) {
                      _currentPage.value = index;
                      // Notify the message-level controller so popup/reply/
                      // tapback gestures can target the visible image.
                      if (message.guid != null) {
                        getActiveMwc(message.guid!)?.carouselPage.value = index;
                      }
                    },
                    itemBuilder: (context, index) {
                      final att = attachments[index];
                      return Semantics(
                        label: 'Image ${index + 1} of ${attachments.length}',
                        image: true,
                        button: true,
                        child: GestureDetector(
                          onTap: () => _openFullscreen(index),
                          onLongPress: widget.onTileLongPress != null
                              ? () => widget.onTileLongPress!(index)
                              : null,
                          onDoubleTap: widget.onTileDoubleTap != null
                              ? () => widget.onTileDoubleTap!(index)
                              : null,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: _buildCardImage(att, availableWidth, cardHeight),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          // Page indicator dots
          ValueListenableBuilder<int>(
            valueListenable: _currentPage,
            builder: (context, page, _) => SizedBox(
              height: indicatorHeight,
              child: _buildPageIndicator(),
            ),
          ),
        ],
      ),
    );

    // Apply tail clipper for bubble shape
    if (widget.showTail) {
      carousel = ClipPath(
        clipper: TailClipper(
          isFromMe: isFromMe,
          showTail: true,
          connectUpper: false,
          connectLower: false,
        ),
        child: carousel,
      );
    }

    return carousel;
  }

  /// Build the background cards that peek behind the current card.
  /// Shows actual adjacent images scaled down.
  List<Widget> _buildBackgroundCards(double width, double cardHeight) {
    final cards = <Widget>[];
    final behindCount = min(2, attachments.length - 1 - _currentPage.value);

    for (int i = behindCount; i >= 1; i--) {
      final scale = 1.0 - (i * 0.05); // Each card behind is 5% smaller
      final yOffset = stackPeekHeight - (i * 6.0); // Each card peeks 6px less
      final cardWidth = width * scale;
      final bgIndex = _currentPage.value + i;

      if (bgIndex >= attachments.length) continue;
      final bgAtt = attachments[bgIndex];

      cards.add(
        Positioned(
          top: yOffset,
          left: (width - cardWidth) / 2,
          width: cardWidth,
          height: cardHeight,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: _buildCardImage(bgAtt, cardWidth, cardHeight),
          ),
        ),
      );
    }
    return cards;
  }

  double get stackPeekHeight => 12.0;

  /// Build the page indicator dots.
  Widget _buildPageIndicator() {
    if (attachments.length <= 1) return const SizedBox.shrink();
    final dotCount = min(attachments.length, 9); // Cap visible dots
    final showOverflow = attachments.length > 9;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ...List.generate(dotCount, (i) {
          final isActive = i == _currentPage.value || (showOverflow && i == dotCount - 1 && _currentPage.value >= dotCount - 1);
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            width: isActive ? 7 : 5,
            height: isActive ? 7 : 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive
                  ? context.theme.colorScheme.primary
                  : context.theme.colorScheme.outline.withOpacity(0.4),
            ),
          );
        }),
        if (showOverflow)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              '${_currentPage.value + 1}/${attachments.length}',
              style: TextStyle(
                fontSize: 10,
                color: context.theme.colorScheme.outline,
              ),
            ),
          ),
      ],
    );
  }

  /// Build the image content for a card.
  Widget _buildCardImage(Attachment att, double width, double height) {
    final data = _imageData[att.guid];
    final loaded = _loadState[att.guid];

    // Error state
    if (loaded == false && data == null && _loadState.containsKey(att.guid!)) {
      return Container(
        width: width,
        height: height,
        color: context.theme.colorScheme.surfaceContainerHighest,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 28, color: Colors.red),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => _retryImage(att),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: context.theme.colorScheme.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    'Retry',
                    style: TextStyle(
                      color: context.theme.colorScheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Loading state
    if (data == null) {
      return Container(
        width: width,
        height: height,
        color: context.theme.colorScheme.surfaceContainerHighest,
        child: const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    // Loaded state
    return Image.memory(
      data,
      width: width,
      height: height,
      gaplessPlayback: true,
      filterQuality: FilterQuality.none,
      cacheWidth: (width * Get.pixelRatio).round().abs().nonZero,
      cacheHeight: (height * Get.pixelRatio).round().abs().nonZero,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => Container(
        width: width,
        height: height,
        color: context.theme.colorScheme.surfaceContainerHighest,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image_outlined, size: 28),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => _retryImage(att),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: context.theme.colorScheme.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    'Retry',
                    style: TextStyle(
                      color: context.theme.colorScheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
