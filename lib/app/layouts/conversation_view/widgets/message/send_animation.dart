import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';

import 'package:async_task/async_task_extension.dart';
import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:bluebubbles/app/components/custom_text_editing_controllers.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/misc/tail_clipper.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dotted_border/dotted_border.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:mime_type/mime_type.dart';
import 'package:simple_animations/simple_animations.dart';
import 'package:tuple/tuple.dart';

/// Resolve a MIME type for an outgoing attachment from its path/name.
///
/// The `mime_type` package does not recognize the HEIC-sequence extensions
/// (`.heics` / `.heifs`) used by animated Live Stickers, returning null. That
/// left the locally-stored Attachment with no mimeType, so the sent sticker
/// never rendered on the sender's own screen (the recipient was fine — the
/// wire path hardcodes `image/heic-sequence`). Map those extensions explicitly
/// so the local row renders as an animated sticker like any received one.
String? resolveSendMime(String? pathOrName) {
  final resolved = mime(pathOrName);
  if (resolved != null) return resolved;
  final lower = (pathOrName ?? "").toLowerCase();
  if (lower.endsWith(".heics")) return "image/heic-sequence";
  if (lower.endsWith(".heifs")) return "image/heif-sequence";
  return null;
}

class SendAnimation extends CustomStateful<ConversationViewController> {
  const SendAnimation({super.key, required super.parentController});

  @override
  CustomState createState() => _SendAnimationState();
}

class _SendAnimationState
    extends CustomState<SendAnimation, Tuple7<List<PlatformFile>, AttributedBody, String, String?, int?, String?, PayloadData?>, ConversationViewController> {
  Message? message;
  Tween<double> tween = Tween<double>(begin: 1, end: 0);
  Control control = Control.stop;
  double textFieldSize = 0;

  double get focusInfoSize => (controller.focusInfoKey.currentContext?.findRenderObject() as RenderBox?)?.size.height ?? 0;

  @override
  void initState() {
    super.initState();
    controller.sendFunc = send;
    updateObx(() {
      final box = controller.textFieldKey.currentContext?.findRenderObject() as RenderBox?;
      textFieldSize = box?.size.height ?? 0;
    });
  }

  Future<void> send(Tuple7<List<PlatformFile>, AttributedBody, String, String?, int?, String?, PayloadData?> tuple, bool isAudioMessage, DateTime? schedule) async {
    // do not add anything above this line, the attachments must be extracted first
    final attachments = List<PlatformFile>.from(tuple.item1);
    AttributedBody annotations = tuple.item2;
    final subject = tuple.item3;
    final replyGuid = tuple.item4;
    final part = tuple.item5;
    final effectId = tuple.item6;
    final payload = tuple.item7;
    if (ss.settings.scrollToBottomOnSend.value) {
      await controller.scrollToTime(schedule ?? DateTime.now());
    }
    if (ss.settings.sendSoundPath.value != null && !(isNullOrEmptyString(annotations.string) && isNullOrEmptyString(subject) && controller.pickedAttachments.isEmpty && controller.pickedApp.value == null)) {
      if (kIsDesktop) {
        Player player = Player();
        await player.setVolume(ss.settings.soundVolume.value.toDouble());
        await player.open(Media(ss.settings.sendSoundPath.value!));
        player.stream.completed
            .firstWhere((completed) => completed)
            .then((_) async => Future.delayed(const Duration(milliseconds: 450), () async => await player.dispose()));
      } else {
        PlayerController controller = PlayerController();
        controller.preparePlayer(path: ss.settings.sendSoundPath.value!, volume: ss.settings.soundVolume.value / 100).then((_) => controller.startPlayer());
      }
    }

    String? replyRun = part != null ? Message.findOne(guid: replyGuid)?.replyPart(part) : null;

    // Separate image files from non-image files for multi-image bundling
    final imageFiles = attachments.where((f) =>
        resolveSendMime(f.path ?? f.name)?.startsWith("image/") ?? false).toList();
    final nonImageFiles = attachments.where((f) =>
        !(resolveSendMime(f.path ?? f.name)?.startsWith("image/") ?? false)).toList();

    if (imageFiles.length >= 2) {
      // Bundle all images into a single multi-image message
      String data = await DefaultAssetBundle.of(Get.context!).loadString("assets/rustpush/uti-map.json");
      final utiMap = jsonDecode(data);
      Logger.info(
        "[Carousel] Bundling ${imageFiles.length} images into single message",
        tag: "Carousel",
      );
      // Diagnostic: sticker state when going through the multi-image path.
      // Multi-attachment bundles do not currently propagate sticker metadata,
      // so this lets us tell if a sticker silently took the bundle branch.
      Logger.info(
        "queue MULTI bundling=${imageFiles.length} isSticker=${controller.isStickerSend} "
        "pickedAttachments=${controller.pickedAttachments.length}",
        tag: "StickerSend",
      );

      final message = Message(
        text: "",
        dateCreated: DateTime.now(),
        dateScheduled: schedule,
        hasAttachments: true,
        attachments: imageFiles.map((file) => Attachment(
          isOutgoing: true,
          mimeType: resolveSendMime(file.path ?? file.name),
          uti: utiMap[resolveSendMime(file.path ?? file.name)] ?? "public.data",
          bytes: file.bytes,
          transferName: file.name,
          totalBytes: file.size,
          sourcePath: file.path,
        )).toList(),
        isFromMe: true,
        handleId: 0,
        threadOriginatorGuid: replyGuid,
        threadOriginatorPart: replyRun,
        expressiveSendStyleId: effectId,
      );
      message.generateTempGuid();
      for (int i = 0; i < message.attachments.length; i++) {
        message.attachments[i]!.guid = "${message.guid}_$i";
      }
      await outq.queue(OutgoingItem(
        type: QueueType.sendMultiAttachment,
        chat: controller.chat,
        message: message,
        customArgs: {"audio": isAudioMessage},
      ));
    }

    // Send non-image files (or all files if < 2 images) individually
    final filesToSendIndividually = imageFiles.length >= 2 ? nonImageFiles : attachments;
    for (int i = 0; i < filesToSendIndividually.length; i++) {
      final file = filesToSendIndividually[i];
      String data = await DefaultAssetBundle.of(Get.context!).loadString("assets/rustpush/uti-map.json");
      final utiMap = jsonDecode(data);

      final isSticker = controller.isStickerSend;
      final stickerBundleId = isSticker
          ? "com.apple.Stickers.UserGenerated.MessagesExtension"
          : null;
      // Diagnostic: capture sticker state at queue-time to debug why
      // [StickerSend]/[StickerProcessor] aren't firing on send.
      Logger.info(
        "queue isSticker=$isSticker name=${file.name} mime=${mime(file.path ?? file.name)} "
        "pickedAttachments=${controller.pickedAttachments.length} "
        "showAttachmentPicker=${controller.showAttachmentPicker} "
        "payloadBundleId=${payload?.bundleId} stickerBundleId=$stickerBundleId",
        tag: "StickerSend",
      );

      final message = Message(
        text: "",
        dateCreated: DateTime.now(),
        dateScheduled: schedule,
        hasAttachments: true,
        attachments: [
          Attachment(
            isOutgoing: true,
            mimeType: resolveSendMime(file.path ?? file.name),
            uti: utiMap[resolveSendMime(file.path ?? file.name)] ?? "public.data",
            bytes: file.bytes,
            transferName: file.name,
            totalBytes: file.size,
            sourcePath: file.path,
          ),
        ],
        isFromMe: true,
        handleId: 0,
        threadOriginatorGuid: i == 0 && imageFiles.length < 2 ? replyGuid : null,
        threadOriginatorPart: i == 0 && imageFiles.length < 2 ? replyRun : null,
        expressiveSendStyleId: effectId,
        payloadData: payload,
        balloonBundleId: stickerBundleId ?? payload?.bundleId,
        stagingGuid: (payload != null || isSticker) ? uuid.v4().toUpperCase() : null,
      );
      message.generateTempGuid();
      message.attachments.first!.guid = message.guid;
      await outq.queue(OutgoingItem(type: QueueType.sendAttachment, chat: controller.chat, message: message, customArgs: {"audio": isAudioMessage}));
    }

    if (attachments.isEmpty && payload != null) {
      final message = Message(
        text: "",
        dateCreated: DateTime.now(),
        dateScheduled: schedule,
        hasAttachments: false,
        attachments: [],
        isFromMe: true,
        handleId: 0,
        threadOriginatorGuid: replyGuid,
        threadOriginatorPart: replyRun,
        expressiveSendStyleId: effectId,
        payloadData: payload,
        balloonBundleId: payload.bundleId,
        stagingGuid: uuid.v4().toUpperCase(),
        hasApplePayloadData: true,
      );
      message.generateTempGuid();
      await outq.queue(OutgoingItem(type: QueueType.sendMessage, chat: controller.chat, message: message, customArgs: {"audio": isAudioMessage}));
    }

    if (annotations.string.trim().isNotEmpty || subject.isNotEmpty) {
      var text = annotations.string;
      final _message = Message(
        text: text.isEmpty && subject.isNotEmpty ? subject : text,
        subject: text.isEmpty && subject.isNotEmpty ? null : subject,
        threadOriginatorGuid: attachments.isEmpty ? replyGuid : null,
        threadOriginatorPart: attachments.isEmpty ? replyRun : null,
        expressiveSendStyleId: effectId,
        dateCreated: DateTime.now(),
        dateScheduled: schedule,
        hasAttachments: false,
        isFromMe: true,
        handleId: 0,
        hasDdResults: true,
        attributedBody: [
          if (annotations.string.isNotEmpty)
            annotations
        ],
      );
      _message.generateTempGuid();
      outq.queue(OutgoingItem(
        type: QueueType.sendMessage,
        chat: controller.chat,
        message: _message,
      ));
      setState(() {
        tween = Tween<double>(
          begin: 0.9,
          end: 0,
        );
        control = Control.play;
        message = _message;
      });
    }
    super.updateWidget(tuple);
  }

  @override
  Widget build(BuildContext context) {
    final typicalWidth = message?.isBigEmoji ?? false ? ns.width(context) : ns.width(context) * MessageWidgetController.maxBubbleSizeFactor - 40;
    const duration = 500;
    const curve = Curves.easeInOut;
    const buttonSize = 44;
    final messageBoxSize = ns.width(context) - buttonSize;
    return AnimatedPositioned(
      duration: Duration(milliseconds: message != null ? duration : 0),
      bottom: message != null ? textFieldSize + focusInfoSize + 17.5 + (controller.showTypingIndicatorFor.isNotEmpty ? 50 : 0) + (!iOS ? 15 : 0) : 0,
      right: samsung ? -37.5 : 5,
      curve: curve,
      onEnd: () async {
        if (message != null) {
          await Future.delayed(const Duration(milliseconds: 100));
          setState(() {
            tween = Tween<double>(begin: 1, end: 0);
            control = Control.stop;
            message = null;
          });
        }
      },
      child: Visibility(
        visible: message != null,
        child: CustomAnimationBuilder<double>(
          control: control,
          tween: tween,
          duration: Duration(milliseconds: message != null ? duration : 0),
          builder: (context, linear, child) {
            var value = curve.transform(linear);
            var exp = Curves.easeIn.transform(linear);
            var child = ClipPath(
                clipper: TailClipper(
                  isFromMe: true,
                  showTail: true,
                  connectLower: false,
                  connectUpper: false,
                ),
                child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: max(messageBoxSize * exp, typicalWidth) - (message?.dateScheduled != null ? 4 : 0),
                        minWidth: max(messageBoxSize * exp - (message?.dateScheduled != null ? 4 : 0), 0),
                        minHeight: 40 - (message?.dateScheduled != null ? 4 : 0),
                      ),
                      color: !message!.isBigEmoji && message?.dateScheduled == null ? context.theme.colorScheme.primary.withAlpha(((1-value) * 255).toInt()) : null,
                      padding: EdgeInsets.symmetric(vertical: 10 - (message?.dateScheduled != null ? 4 : 0), horizontal: 15 - (message?.dateScheduled != null ? 4 : 0)).add(EdgeInsets.only(
                        left: message?.dateScheduled != null && message!.isBigEmoji ? -8 : message!.isFromMe! || message!.isBigEmoji ? 0 : 10, right: message!.isFromMe! && !message!.isBigEmoji ? 10 : 0)),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        widthFactor: 1,
                        child: Padding(
                          padding: message!.fullText.length == 1 ? const EdgeInsets.only(left: 3, right: 3) : EdgeInsets.zero,
                          child: RichText(
                            text: TextSpan(
                              children: buildMessageSpans(
                                context,
                                message!.buildMessageParts().firstOrNull ?? MessagePart(part: 0, text: message!.text, subject: message!.subject),
                                message!,
                                colorOverride: Color.lerp(context.theme.colorScheme.properOnSurface, message?.dateScheduled != null ? context.theme.colorScheme.primary : context.theme.colorScheme.onPrimary, 1 - value)
                              ),
                            ),
                          ),
                        ),
                      )
                    ),),
              );
            return Transform.scale(
              scale: (1-value) < .5 ? lerpDouble(1.1, .9, (1-value) / .5) : lerpDouble(.9, 1, (.5-value) / .5),
              alignment: Alignment.centerRight,
              child: message!.dateScheduled != null ? DottedBorder(
                          customPath: (size) => TailClipper(
                            isFromMe: true,
                            showTail: true,
                            connectLower: false,
                            connectUpper: false,
                          ).getClip(size),
                          color: context.theme.colorScheme.primaryContainer,
                          strokeWidth: 2,
                          dashPattern: [7, 4],
                          child: child,
                        ) : child,
            );
          },
        ),
      ),
    );
  }
}