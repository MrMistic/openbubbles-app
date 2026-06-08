import 'dart:async';
import 'dart:math';

import 'package:bluebubbles/app/layouts/conversation_details/dialogs/add_participant.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/chat_info.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/chat_options.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/interactive/url_preview.dart';
import 'package:bluebubbles/app/layouts/settings/pages/profile/profile_scaffold.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/media_gallery_card.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/contact_tile.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;

class ConversationDetails extends StatefulWidget {
  final Chat chat;

  ConversationDetails({super.key, required this.chat});

  @override
  State<ConversationDetails> createState() => _ConversationDetailsState();
}

enum _SectionState { idle, loading, loaded }

class _ConversationDetailsState extends OptimizedState<ConversationDetails> with WidgetsBindingObserver {
  List<Attachment> media = <Attachment>[];
  List<Attachment> docs = <Attachment>[];
  List<Attachment> locations = <Attachment>[];
  List<Message> links = [];
  // Media/docs/locations and links are loaded lazily on first tap of their
  // section headers, so opening the details page does no attachment/link DB
  // work — most visits (mute, participants, etc.) never touch these.
  _SectionState attachmentsState = _SectionState.idle;
  _SectionState linksState = _SectionState.idle;
  bool showMoreParticipants = false;
  late Chat chat = widget.chat;
  late StreamSubscription sub;
  final RxList<String> selected = <String>[].obs;

  bool get shouldShowMore => chat.participants.length > 5;
  List<Handle> get clippedParticipants => showMoreParticipants
      ? chat.participants
      : chat.participants.take(5).toList();

  List<String> ftSupportedParticipants = [];

  @override
  void initState() {
    super.initState();

    cm.setActiveToDead();

    cvc(widget.chat).showingOverlays = true;

    (() async {
      var data = await chat.getConversationData();
      ftSupportedParticipants = await api.validateTargetsFacetime(state: pushService.state!.client, targets: data.participants, sender: await chat.ensureHandle());
      setState(() { });
    })();

    if (!kIsWeb) {
      final chatQuery = Database.chats.query(Chat_.guid.equals(chat.guid)).watch();
      sub = chatQuery.listen((Query<Chat> query) async {
        final _chat = await runAsync(() {
          return Database.chats.get(chat.id!);
        });
        if (_chat != null) {
          final update = _chat.getTitle() != chat.title || _chat.participants.length != chat.participants.length;
          chat = _chat.merge(chat);
          if (update) {
            setState(() {});
          }
        }
      });
    } else {
      sub = WebListeners.chatUpdate.listen((_chat) {
        final update = _chat.getTitle() != chat.title || _chat.participants.length != chat.participants.length;
        chat = _chat.merge(chat);
        if (update) {
          setState(() {});
        }
      });
    }

    // Attachments and links are now loaded lazily when the user taps their
    // section headers (see fetchAttachments/fetchLinks), so nothing loads on
    // page open.
  }

  @override
  void dispose() {
    sub.cancel();
    cvc(widget.chat).showingOverlays = false;
    if (cm.activeChat != null) {
      cm.setActiveToAlive();
      cvc(cm.activeChat!.chat).lastFocusedNode.requestFocus();
    }
    super.dispose();
  }

  /// A tappable section header that triggers a lazy load. Shows a chevron when
  /// idle (tap to load), a spinner while loading, and plain text once loaded.
  Widget _lazyHeader(String label, _SectionState state, VoidCallback onTap) {
    final style = context.theme.textTheme.bodyMedium!.copyWith(color: context.theme.colorScheme.outline);
    if (state == _SectionState.loaded) {
      return Text(label, style: style);
    }
    return InkWell(
      onTap: state == _SectionState.idle ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Text(label, style: style),
            const SizedBox(width: 8),
            if (state == _SectionState.loading)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: context.theme.colorScheme.outline),
              )
            else
              Icon(iOS ? CupertinoIcons.chevron_down : Icons.expand_more, size: 16, color: context.theme.colorScheme.outline),
          ],
        ),
      ),
    );
  }

  void _assignHandle(Attachment a) {
    a.message.target?.handle =
        chat.participants.firstWhereOrNull((e) => e.originalROWID == a.message.target?.handleId);
  }

  /// Load the Images & Videos / Other Files / Locations sections. Bounded:
  /// each kind is fetched via a limited attachment query, not a full-history
  /// scan. Triggered on first tap of the "IMAGES & VIDEOS" header.
  Future<void> fetchAttachments() async {
    if (kIsWeb || attachmentsState != _SectionState.idle) return;
    setState(() => attachmentsState = _SectionState.loading);

    final results = await Future.wait([
      chat.getMediaAttachmentsAsync("media", limit: 24),
      chat.getMediaAttachmentsAsync("doc", limit: 24),
      chat.getMediaAttachmentsAsync("location", limit: 10),
    ]);
    final _media = results[0];
    final _docs = results[1];
    final _locations = results[2];

    for (final a in _media) { _assignHandle(a); }
    for (final a in _docs) { _assignHandle(a); }
    for (final a in _locations) { _assignHandle(a); }

    if (!mounted) return;
    setState(() {
      media = _media;
      docs = _docs;
      locations = _locations;
      attachmentsState = _SectionState.loaded;
    });
  }

  /// Load the Links section. Already bounded (limit 20) via a targeted query.
  /// Triggered on first tap of the "LINKS" header.
  Future<void> fetchLinks() async {
    if (kIsWeb || linksState != _SectionState.idle) return;
    setState(() => linksState = _SectionState.loading);

    final found = await runAsync(() {
      final query = (Database.messages.query(Message_.dateDeleted.isNull()
        & Message_.dbPayloadData.notNull()
        & Message_.balloonBundleId.contains("URLBalloonProvider"))
        ..link(Message_.chat, Chat_.id.equals(chat.id!))
        ..order(Message_.dateCreated, flags: Order.descending))
          .build();
      query.limit = 20;
      final result = query.find();
      query.close();
      return result;
    });

    if (!mounted) return;
    setState(() {
      links = found;
      linksState = _SectionState.loaded;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        systemNavigationBarColor: ss.settings.immersiveMode.value ? Colors.transparent : context.theme.colorScheme.background, // navigation bar color
        systemNavigationBarIconBrightness: context.theme.colorScheme.brightness.opposite,
        statusBarColor: Colors.transparent, // status bar color
        statusBarIconBrightness: context.theme.colorScheme.brightness.opposite,
      ),
      child: Theme(
        data: context.theme.copyWith(
          // in case some components still use legacy theming
          primaryColor: context.theme.colorScheme.bubble(context, chat.isIMessage),
          colorScheme: context.theme.colorScheme.copyWith(
            primary: context.theme.colorScheme.bubble(context, chat.isIMessage),
            onPrimary: context.theme.colorScheme.onBubble(context, chat.isIMessage),
            surface: ss.settings.monetTheming.value == Monet.full
                ? null
                : (context.theme.extensions[BubbleColors] as BubbleColors?)?.receivedBubbleColor,
            onSurface: ss.settings.monetTheming.value == Monet.full
                ? null
                : (context.theme.extensions[BubbleColors] as BubbleColors?)?.onReceivedBubbleColor,
          ),
        ),
        child: Obx(() {
          var actions = [
            Obx(() {
              if (selected.isNotEmpty) {
                return IconButton(
                  icon: Icon(iOS ? CupertinoIcons.xmark : Icons.close, color: context.theme.colorScheme.onBackground),
                  onPressed: () {
                    selected.clear();
                  },
                );
              } else {
                return const SizedBox.shrink();
              }
            }),
            Obx(() {
              if (selected.isNotEmpty) {
                return IconButton(
                  icon: Icon(iOS ? CupertinoIcons.cloud_download : Icons.file_download, color: context.theme.colorScheme.onBackground),
                  onPressed: () {
                    final attachments = media.where((e) => selected.contains(e.guid!));
                    for (Attachment a in attachments) {
                      final file = as.getContent(a, autoDownload: false);
                      if (file is PlatformFile) {
                        as.saveToDisk(file);
                      }
                    }
                  },
                );
              } else {
                return const SizedBox.shrink();
              }
            }),
          ];

          var slivers = [
            if (chat.isGroup)
            SliverToBoxAdapter(
              child: ChatInfo(chat: chat, ftSupportedParticipants: ftSupportedParticipants,),
            ),
            if (chat.isGroup)
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final addMember = ListTile(
                    mouseCursor: MouseCursor.defer,
                    title: Text("Add ${iOS ? "Member" : "people"}", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
                    leading: Container(
                      width: 40 * ss.settings.avatarScale.value,
                      height: 40 * ss.settings.avatarScale.value,
                      decoration: BoxDecoration(
                        color: !iOS ? null : context.theme.colorScheme.properSurface,
                        shape: BoxShape.circle,
                        border: iOS ? null : Border.all(color: context.theme.colorScheme.primary, width: 3)
                      ),
                      child: Icon(
                        Icons.add,
                        color: context.theme.colorScheme.primary,
                        size: 20
                      ),
                    ),
                    onTap: () {
                      showAddParticipant(context, chat);
                    },
                  );

                  if (index > clippedParticipants.length) {
                    if (ss.settings.enablePrivateAPI.value && chat.isIMessage && chat.isGroup && shouldShowMore) {
                      return addMember;
                    } else {
                      return const SizedBox.shrink();
                    }
                  }
                  if (index == clippedParticipants.length) {
                    if (shouldShowMore) {
                      return ListTile(
                        mouseCursor: SystemMouseCursors.click,
                        onTap: () {
                          setState(() {
                            showMoreParticipants = !showMoreParticipants;
                          });
                        },
                        title: Text(
                          showMoreParticipants ? "Show less" : "Show more",
                          style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary),
                        ),
                        leading: Container(
                          width: 40 * ss.settings.avatarScale.value,
                          height: 40 * ss.settings.avatarScale.value,
                          decoration: BoxDecoration(
                              color: !iOS ? null : context.theme.colorScheme.properSurface,
                              shape: BoxShape.circle,
                              border: iOS ? null : Border.all(color: context.theme.colorScheme.primary, width: 3)
                          ),
                          child: Icon(
                            Icons.more_horiz,
                            color: context.theme.colorScheme.primary,
                            size: 20
                          ),
                        ),
                      );
                    } else if (ss.settings.enablePrivateAPI.value && chat.isIMessage && chat.isGroup) {
                      return addMember;
                    } else {
                      return const SizedBox.shrink();
                    }
                  }

                  return ContactTile(
                    key: Key(chat.participants[index].address),
                    handle: chat.participants[index],
                    chat: chat,
                    canBeRemoved: chat.participants.length > 1
                        && ss.settings.enablePrivateAPI.value
                        && chat.isIMessage,
                    facetimeSupported: ftSupportedParticipants.contains(RustPushBBUtils.bbHandleToRust(chat.participants[index])),
                  );
                }, childCount: clippedParticipants.length + 2),
              ),
            if (ss.settings.enablePrivateAPI.value && chat.participants.length > 2 && backend.canLeaveChat()) // evaluate this first to make GetX happy
              SliverToBoxAdapter(
                child: Builder(
                  builder: (context) {
                    return ListTile(
                      mouseCursor: MouseCursor.defer,
                      title: Text("Leave ${iOS ? "Chat" : "chat"}", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.error)),
                      leading: Container(
                        width: 40 * ss.settings.avatarScale.value,
                        height: 40 * ss.settings.avatarScale.value,
                        decoration: BoxDecoration(
                          color: !iOS ? null : context.theme.colorScheme.properSurface,
                          shape: BoxShape.circle,
                          border: iOS ? null : Border.all(color: context.theme.colorScheme.error, width: 3)
                        ),
                        child: Icon(
                          Icons.error_outline,
                          color: context.theme.colorScheme.error,
                          size: 20
                        ),
                      ),
                      onTap: () async {
                        showDialog(
                          context: context,
                          builder: (BuildContext context) {
                            return AlertDialog(
                              backgroundColor: context.theme.colorScheme.properSurface,
                              title: Text(
                                "Leaving chat...",
                                style: context.theme.textTheme.titleLarge,
                              ),
                              content: Container(
                                height: 70,
                                child: Center(
                                  child: CircularProgressIndicator(
                                    backgroundColor: context.theme.colorScheme.properSurface,
                                    valueColor: AlwaysStoppedAnimation<Color>(context.theme.colorScheme.primary),
                                  ),
                                ),
                              ),
                            );
                          }
                        );
                        final response = await backend.leaveChat(chat);
                        if (response) {
                          Get.back();
                          showSnackbar("Notice", "Left chat successfully!");
                        } else {
                          Get.back();
                          showSnackbar("Error", "Failed to leave chat!");
                        }
                      },
                    );
                  }
                ),
              ),
            const SliverPadding(
              padding: EdgeInsets.symmetric(vertical: 10),
            ),
            ChatOptions(chat: chat),
            if (!kIsWeb)
              SliverPadding(
                padding: const EdgeInsets.only(top: 20, bottom: 10, left: 15),
                sliver: SliverToBoxAdapter(
                  child: _lazyHeader("IMAGES & VIDEOS", attachmentsState, fetchAttachments),
                ),
              ),
            if (!kIsWeb && attachmentsState == _SectionState.loaded && media.isEmpty && docs.isEmpty && locations.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.only(left: 15, bottom: 10),
                sliver: SliverToBoxAdapter(
                  child: Text("No media in this conversation",
                      style: context.theme.textTheme.bodySmall!.copyWith(color: context.theme.colorScheme.outline)),
                ),
              ),
            if (!kIsWeb && media.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.all(10),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: max(2, ns.width(context) ~/ 200),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, int index) {
                      final attachment = media[index];
                      // Build the (expensive) thumbnail card ONCE, outside the
                      // Obx closure, so toggling selection on one item doesn't
                      // rebuild every card's MediaGalleryCard — only the thin
                      // selection chrome below re-renders.
                      final card = MediaGalleryCard(attachment: attachment);
                      void toggle() {
                        if (selected.contains(attachment.guid)) {
                          selected.remove(attachment.guid!);
                        } else {
                          selected.add(attachment.guid!);
                        }
                      }
                      return Obx(() {
                        final isSelected = selected.contains(attachment.guid);
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          margin: EdgeInsets.all(isSelected ? 10 : 0),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: GestureDetector(
                            onTap: selected.isNotEmpty ? toggle : null,
                            onLongPress: toggle,
                            child: AbsorbPointer(
                              absorbing: selected.isNotEmpty,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  card,
                                  if (isSelected)
                                    Container(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: context.theme.colorScheme.primary
                                      ),
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
                          ),
                        );
                      });
                    },
                    childCount: media.length,
                  ),
                ),
              ),
            if (!kIsWeb)
              SliverPadding(
                padding: const EdgeInsets.only(top: 20, bottom: 10, left: 15),
                sliver: SliverToBoxAdapter(
                  child: _lazyHeader("LINKS", linksState, fetchLinks),
                ),
              ),
            if (!kIsWeb && linksState == _SectionState.loaded && links.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.only(left: 15, bottom: 10),
                sliver: SliverToBoxAdapter(
                  child: Text("No links in this conversation",
                      style: context.theme.textTheme.bodySmall!.copyWith(color: context.theme.colorScheme.outline)),
                ),
              ),
            if (!kIsWeb && links.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.all(10),
                sliver: SliverToBoxAdapter(
                  child: MasonryGridView.count(
                    crossAxisCount: max(2, ns.width(context) ~/ 200),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemBuilder: (context, index) {
                      if (links[index].payloadData?.urlData?.firstOrNull == null) {
                        return const Text("Failed to load link!");
                      }
                      return Material(
                        color: context.theme.colorScheme.properSurface,
                        borderRadius: BorderRadius.circular(20),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () async {
                            final data = links[index].payloadData!.urlData!.first;
                            if ((data.url ?? data.originalUrl) == null) return;
                            await launchUrl(
                                Uri.parse((data.url ?? data.originalUrl)!),
                                mode: LaunchMode.externalApplication
                            );
                          },
                          child: Center(
                            child: UrlPreview(
                              data: links[index].payloadData!.urlData!.first,
                              message: links[index],
                            ),
                          ),
                        ),
                      );
                    },
                    itemCount: links.length,
                  ),
                ),
              ),
            if (!kIsWeb && locations.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.only(top: 20, bottom: 10, left: 15),
                sliver: SliverToBoxAdapter(
                  child: Text("LOCATIONS", style: context.theme.textTheme.bodyMedium!.copyWith(color: context.theme.colorScheme.outline)),
                ),
              ),
            if (!kIsWeb && locations.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.all(10),
                sliver: SliverToBoxAdapter(
                  child: MasonryGridView.count(
                    crossAxisCount: max(2, ns.width(context) ~/ 200),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemBuilder: (context, index) {
                      if (as.getContent(locations[index]) is! PlatformFile) {
                        return const Text("Failed to load location!");
                      }
                      return Material(
                        color: context.theme.colorScheme.properSurface,
                        borderRadius: BorderRadius.circular(20),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () async {
                            final data = links[index].payloadData!.urlData!.first;
                            if ((data.url ?? data.originalUrl) == null) return;
                            await launchUrl(
                                Uri.parse((data.url ?? data.originalUrl)!),
                                mode: LaunchMode.externalApplication
                            );
                          },
                          child: Center(
                            child: UrlPreview(
                              data: UrlPreviewData(
                                title: "Location from ${DateFormat.yMd().format(locations[index].message.target!.dateCreated!)}",
                                siteName: "Tap to open",
                              ),
                              message: locations[index].message.target!,
                              file: as.getContent(locations[index]),
                            ),
                          ),
                        ),
                      );
                    },
                    itemCount: locations.length,
                  ),
                ),
              ),
            if (!kIsWeb && docs.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.only(top: 20, bottom: 10, left: 15),
                sliver: SliverToBoxAdapter(
                  child: Text("OTHER FILES", style: context.theme.textTheme.bodyMedium!.copyWith(color: context.theme.colorScheme.outline)),
                ),
              ),
            if (!kIsWeb && docs.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.all(10),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: max(2, ns.width(context) ~/ 200),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.75,
                  ),
                  delegate: SliverChildBuilderDelegate(
                        (context, int index) {
                      return MediaGalleryCard(
                        attachment: docs[index],
                      );
                    },
                    childCount: docs.length,
                  ),
                ),
              ),
            const SliverPadding(
              padding: EdgeInsets.only(top: 50),
            ),
          ];
          
          if (!chat.isGroup) {
            return ProfileScaffold(
              bodySlivers: slivers,
              handle: chat.participants[0],
              actions: actions,
              chatOptions: ChatInfo(chat: chat, ftSupportedParticipants: ftSupportedParticipants,),
            );
          }

          return SettingsScaffold(
            headerColor: headerColor,
            title: "Details",
            tileColor: tileColor,
            initialHeader: null,
            iosSubtitle: iosSubtitle,
            materialSubtitle: materialSubtitle,
            actions: actions,
            bodySlivers: slivers
          );
        })
      ),
    );
  }
}
