import 'package:bluebubbles/database/models.dart' hide Entity;
import 'package:bluebubbles/helpers/ui/apple_maps_link.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_ml_kit/google_ml_kit.dart' hide Message;
import 'package:maps_launcher/maps_launcher.dart';
import 'package:tuple/tuple.dart';
import 'package:url_launcher/url_launcher.dart';

List<InlineSpan> buildMessageSpans(BuildContext context, MessagePart part, Message message, {Color? colorOverride, bool hideBodyText = false}) {
  final textSpans = <InlineSpan>[];
  final textStyle = (context.theme.extensions[BubbleText] as BubbleText).bubbleText.apply(
    color: colorOverride ?? (message.isFromMe! ? context.theme.colorScheme.onPrimary : context.theme.colorScheme.properOnSurface),
    fontSizeFactor: message.isBigEmoji ? 3 : 1,
  );

  if (!isNullOrEmpty(part.subject)) {
    textSpans.addAll(MessageHelper.buildEmojiText(
      "${part.displaySubject}${!hideBodyText ? "\n" : ""}",
      textStyle.apply(fontWeightDelta: 2),
    ));
  }
  if (part.annotations.isNotEmpty) {
    part.annotations.forEachIndexed((i, e) {
      final range = part.annotations[i].range;
      var style = textStyle;
      if (e.bold ?? false) style = style.apply(fontWeightDelta: 2);
      if (e.italic ?? false) style = style.apply(fontStyle: FontStyle.italic);
      style = style.apply(decoration: TextDecoration.combine([
        if (e.strikethrough ?? false) TextDecoration.lineThrough,
        if (e.underline ?? false) TextDecoration.underline,
      ]));
      if (e.textEffect == Attributes.BIG) style = style.apply(fontSizeDelta: 4);
      if (e.textEffect == Attributes.SMALL) style = style.apply(fontSizeDelta: -2);
      if (e.mentionedAddress != null) {
        textSpans.addAll(MessageHelper.buildEmojiText(
          part.displayText!.substring(range.first, range.last),
          style.apply(fontWeightDelta: 2),
          recognizer: TapGestureRecognizer()..onTap = () async {
            if (kIsDesktop || kIsWeb) return;
            final handle = cm.activeChat!.chat.participants.firstWhereOrNull((e) => e.address == part.annotations[i].mentionedAddress);
            if (handle?.contact == null && handle != null) {
              await mcs.invokeMethod("open-contact-form", {'address': handle.address, 'address_type': handle.address.isEmail ? 'email' : 'phone'});
            } else if (handle?.contact != null) {
              try {
                await mcs.invokeMethod("view-contact-form", {'id': handle!.contact!.id});
              } catch (_) {
                showSnackbar("Error", "Failed to find contact on device!");
              }
            }
          }
        ));
      } else {  
        textSpans.addAll(MessageHelper.buildEmojiText(
          part.displayText!.substring(range.first, range.last),
          style,
        ));
      }
    });
  } else if (!isNullOrEmpty(part.displayText)) {
    textSpans.addAll(MessageHelper.buildEmojiText(
      part.displayText!,
      textStyle,
    ));
  }

  return textSpans;
}

Future<List<InlineSpan>> buildEnrichedMessageSpans(BuildContext context, MessagePart part, Message message, {Color? colorOverride, bool hideBodyText = false}) async {
  final textSpans = <InlineSpan>[];
  final textStyle = (context.theme.extensions[BubbleText] as BubbleText).bubbleText.apply(
    color: colorOverride ?? (message.isFromMe! ? context.theme.colorScheme.onPrimary : context.theme.colorScheme.properOnSurface),
    fontSizeFactor: message.isBigEmoji ? 3 : 1,
  );
  // extract rich content
  final urlRegex = RegExp(r'((https?://)|(www\.))[-a-zA-Z0-9@:%._+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}([-a-zA-Z0-9/()@:%_.~#?&=*\[\]]*)\b');

  List<Annotation> annotations = part.annotations.map((a) => a.copy()).toList();
  void markRange(Tuple3<String, List<int>, List?> annotation) {
    var range = annotation.item2;
    List<Annotation> extras = [];
    // split em up correctly
    for (var a in annotations) {
      if (a.range[0] < range[0] && a.range[1] > range[0]) {
        var dup = a.copy();
        dup.range[1] = range[0];
        extras.add(dup);

        // end this range at the start of my new range
        a.range[0] = range[0];
      }

      if (a.range[0] < range[1] && a.range[1] > range[1]) {
        var dup = a.copy();
        dup.range[0] = range[1];
        extras.add(dup);

        // end this range at the start of my new range
        a.range[1] = range[1];
      }
    }
    annotations.addAll(extras);

    for (var a in annotations) {
      if (a.range[0] >= range[0] && a.range[1] <= range[1]) {
        a.renderExtras.add(annotation);
      }
    }
  }

  final controller = cvc(message.chat.target ?? cm.activeChat!.chat);
  if (!isNullOrEmpty(part.text)) {
    if (!kIsWeb && !kIsDesktop && ss.settings.smartReply.value) {
      if (controller.mlKitParsedText["${message.guid!}-${part.part}"] == null) {
        try {
          controller.mlKitParsedText["${message.guid!}-${part.part}"] = await GoogleMlKit.nlp.entityExtractor(EntityExtractorLanguage.english)
              .annotateText(part.text!);
        } catch (ex, stack) {
          Logger.warn('Failed to extract entities using mlkit!', error: ex, trace: stack);
        }
      }
      final entities = controller.mlKitParsedText["${message.guid!}-${part.part}"] ?? [];
      for (EntityAnnotation element in entities) {
        if (element.entities.first is AddressEntity) {
          markRange(Tuple3("map", [element.start, element.end], null));
        } else if (element.entities.first is PhoneEntity) {
          markRange(Tuple3("phone", [element.start, element.end], null));
        } else if (element.entities.first is EmailEntity) {
          markRange(Tuple3("email", [element.start, element.end], null));
        } else if (element.entities.first is UrlEntity) {
          markRange(Tuple3("link", [element.start, element.end], null));
        } else if (element.entities.first is DateTimeEntity) {
          final ent = (element.entities.first as DateTimeEntity);
          if (part.text?.substring(element.start, element.end).toLowerCase() == "now") {
            continue;
          }
          markRange(Tuple3("date", [element.start, element.end], [ent.timestamp]));
        } else if (element.entities.first is TrackingNumberEntity) {
          final ent = (element.entities.first as TrackingNumberEntity);
          markRange(Tuple3("tracking", [element.start, element.end], [ent.carrier, ent.number]));
        } else if (element.entities.first is FlightNumberEntity) {
          final ent = (element.entities.first as FlightNumberEntity);
          markRange(Tuple3("flight", [element.start, element.end], [ent.airlineCode, ent.flightNumber]));
        }
      }
    } else {
      List<RegExpMatch> matches = urlRegex.allMatches(part.text!).toList();
      for (RegExpMatch match in matches) {
        markRange(Tuple3("link", [match.start, match.end], null));
      }
    }

    // Apple Maps short-links (maps.apple/p/...) use a TLD-less domain that generic URL
    // detectors (ML Kit UrlEntity and urlRegex) miss. Scan explicitly so they get tappable
    // "link" treatment and the Apple Maps interceptor can handle them.
    final appleMapsShortRegex = RegExp(r'https?://maps\.apple/\S+');
    for (final match in appleMapsShortRegex.allMatches(part.text!)) {
      markRange(Tuple3("link", [match.start, match.end], null));
    }
  }

  annotations.sort((a, b) => a.range[0].compareTo(b.range[0]));
  
  // render subject
  if (!isNullOrEmpty(part.subject)) {
    textSpans.addAll(MessageHelper.buildEmojiText(
      "${part.displaySubject}${!hideBodyText ? "\n" : ""}",
      textStyle.apply(fontWeightDelta: 2),
    ));
  }
  // render rich content if needed
  if (annotations.isNotEmpty) {
    annotations.forEachIndexed((i, e) {
      
      var item = e.renderExtras.firstOrNull;

      final type = item?.item1;
      final range = e.range;
      final data = item?.item3;
      final text = part.displayText!.substring(range.first, range.last);

      var style = textStyle;
      if (e.bold ?? false) style = style.apply(fontWeightDelta: 2);
      if (e.italic ?? false) style = style.apply(fontStyle: FontStyle.italic);
      style = style.apply(decoration: TextDecoration.combine([
        if (e.strikethrough ?? false) TextDecoration.lineThrough,
        if (e.underline ?? false) TextDecoration.underline,
      ]));
      if (e.textEffect == Attributes.BIG) style = style.apply(fontSizeDelta: 4);
      if (e.textEffect == Attributes.SMALL) style = style.apply(fontSizeDelta: -2);

      if (e.mentionedAddress != null) {
        textSpans.addAll(MessageHelper.buildEmojiText(
          text,
          style.apply(fontWeightDelta: 2),
          recognizer: TapGestureRecognizer()..onTap = () async {
            if (kIsDesktop || kIsWeb) return;
            final handle = cm.activeChat!.chat.participants.firstWhereOrNull((e) => e.address == data!.first);
            if (handle?.contact == null && handle != null) {
              await mcs.invokeMethod("open-contact-form", {'address': handle.address, 'address_type': handle.address.isEmail ? 'email' : 'phone'});
            } else if (handle?.contact != null) {
              try {
                await mcs.invokeMethod("view-contact-form", {'id': handle!.contact!.id});
              } catch (_) {
                showSnackbar("Error", "Failed to find contact on device!");
              }
            }
          }
        ));
      } else if (urlRegex.hasMatch(text) || type == "map" || text.isPhoneNumber || text.isEmail || type == "date" || type == "tracking" || type == "flight") {
        textSpans.add(
          TextSpan(
            text: text,
            recognizer: TapGestureRecognizer()
              ..onTap = () async {
                if (type == "link") {
                  String url = text;
                  if (!url.startsWith("http://") && !url.startsWith("https://")) {
                    url = "http://$url";
                  }
                  // Apple Maps links (maps.apple.com or maps.apple/p/...) are useless on Android.
                  // Resolve (follows short-link redirects if needed), parse coords, and open in
                  // the in-app Find My map. Falls through to external launch if resolution fails
                  // or no coordinates are extractable.
                  Logger.info("Link tap: type=$type url=$url isApple=${AppleMapsLink.isAppleMapsLink(url)}");
                  if (AppleMapsLink.isAppleMapsLink(url)) {
                    final resolved = await AppleMapsLink.resolve(url);
                    Logger.info("Apple Maps resolve result: ${resolved?.coords} label=${resolved?.label}");
                    if (resolved != null) {
                      final sender = message.isFromMe!
                          ? "you"
                          : (message.getHandle()?.displayName ?? "a contact");
                      final label = resolved.label != null
                          ? "${resolved.label} — shared by $sender"
                          : "Shared Location from $sender";
                      await AppleMapsLink.openInFindMy(context, resolved.coords, label: label);
                      return;
                    }
                  }
                  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                } else if (type == "map") {
                  if (AppleMapsLink.isAppleMapsLink(text)) {
                    final resolved = await AppleMapsLink.resolve(text);
                    if (resolved != null) {
                      final sender = message.isFromMe!
                          ? "you"
                          : (message.getHandle()?.displayName ?? "a contact");
                      final label = resolved.label != null
                          ? "${resolved.label} — shared by $sender"
                          : "Shared Location from $sender";
                      await AppleMapsLink.openInFindMy(context, resolved.coords, label: label);
                      return;
                    }
                  }
                  await MapsLauncher.launchQuery(text);
                } else if (type == "phone") {
                  await launchUrl(Uri(scheme: "tel", path: text));
                } else if (type == "email") {
                  await launchUrl(Uri(scheme: "mailto", path: text));
                } else if (type == "date") {
                  await mcs.invokeMethod("open-calendar", {"date": data!.first});
                } else if (type == "tracking") {
                  final TrackingCarrier c = data!.first;
                  final String number = data.last;
                  Clipboard.setData(ClipboardData(text: number));
                  await launchUrl(Uri.parse("https://www.google.com/search?q=${c.name} $number"), mode: LaunchMode.externalApplication);
                } else if (type == "flight") {
                  final String c = data!.first;
                  final String number = data.last;
                  await launchUrl(Uri.parse("https://www.google.com/search?q=flight $c$number"), mode: LaunchMode.externalApplication);
                }
              },
            style: style.apply(decoration: TextDecoration.underline),
          ),
        );
      } else {
        textSpans.addAll(MessageHelper.buildEmojiText(
          text,
          style,
        ));
      }
    });
  } else if (!isNullOrEmpty(part.displayText)) {
    textSpans.addAll(MessageHelper.buildEmojiText(
      part.displayText!,
      textStyle,
    ));
  }

  return textSpans;
}