import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:matrix/matrix.dart';
import 'package:swipe_to_action/swipe_to_action.dart';

import 'package:psygo/config/setting_keys.dart';
import 'package:psygo/config/themes.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/pages/chat/events/room_creation_state_event.dart';
import 'package:psygo/services/agent_service.dart';
import 'package:psygo/utils/adaptive_bottom_sheet.dart';
import 'package:psygo/utils/date_time_extension.dart';
import 'package:psygo/utils/file_description.dart';
import 'package:psygo/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:psygo/utils/platform_infos.dart';
import 'package:psygo/utils/string_color.dart';
import 'package:psygo/widgets/avatar.dart';
import 'package:psygo/widgets/matrix.dart';
import 'package:psygo/widgets/member_actions_popup_menu_button.dart';
import '../../../config/app_config.dart';
import 'message_content.dart';
import 'message_reactions.dart';
import 'reply_content.dart';
import 'state_message.dart';

class Message extends StatelessWidget {
  final Event event;
  final Event? nextEvent;
  final Event? previousEvent;
  final bool displayReadMarker;
  final void Function(Event) onSelect;
  final void Function(Event) onInfoTab;
  final void Function(String) scrollToEventId;
  final void Function() onSwipe;
  final void Function() onMention;
  final void Function() onEdit;
  final void Function(String eventId)? enterThread;
  final bool longPressSelect;
  final bool selected;
  final bool singleSelected;
  final Timeline timeline;
  final bool highlightMarker;
  final bool animateIn;
  final void Function()? resetAnimateIn;
  final bool wallpaperMode;
  final ScrollController scrollController;
  final List<Color> colors;
  final void Function()? onExpand;
  final bool isCollapsed;

  const Message(
    this.event, {
    this.nextEvent,
    this.previousEvent,
    this.displayReadMarker = false,
    this.longPressSelect = false,
    required this.onSelect,
    required this.onInfoTab,
    required this.scrollToEventId,
    required this.onSwipe,
    this.selected = false,
    required this.onEdit,
    required this.singleSelected,
    required this.timeline,
    this.highlightMarker = false,
    this.animateIn = false,
    this.resetAnimateIn,
    this.wallpaperMode = false,
    required this.onMention,
    required this.scrollController,
    required this.colors,
    this.onExpand,
    required this.enterThread,
    this.isCollapsed = false,
    super.key,
  });

  ({Uri? avatarUrl, String displayName}) _resolveSenderPresentation(User user) {
    final agent = AgentService.instance.getAgentByMatrixUserId(user.id);
    final agentAvatarUri = AgentService.instance.getAgentAvatarUri(user.id);

    String normalizeDisplayName(String candidate) {
      final trimmed = candidate.trim();
      if (trimmed.isEmpty || trimmed == user.id) {
        return user.id.localpart ?? user.id;
      }
      return trimmed;
    }

    if (agent != null) {
      return (
        avatarUrl: agentAvatarUri ?? user.avatarUrl,
        displayName: normalizeDisplayName(agent.displayName),
      );
    }

    return (
      avatarUrl: user.avatarUrl,
      displayName: normalizeDisplayName(user.calcDisplayname()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!{
      EventTypes.Message,
      EventTypes.Sticker,
      EventTypes.Encrypted,
      EventTypes.CallInvite,
      PollEventContent.startType,
    }.contains(event.type)) {
      if (event.type.startsWith('m.call.')) {
        return const SizedBox.shrink();
      }
      if (event.type == EventTypes.RoomCreate) {
        return RoomCreationStateEvent(event: event);
      }
      return StateMessage(event, onExpand: onExpand, isCollapsed: isCollapsed);
    }

    if (event.type == EventTypes.Message &&
        event.messageType == EventTypes.KeyVerificationRequest) {
      return StateMessage(event);
    }

    final client = Matrix.of(context).client;
    final ownMessage = event.senderId == client.userID;
    final alignment = ownMessage ? Alignment.topRight : Alignment.topLeft;

    var color = theme.colorScheme.surfaceContainerHigh;
    final displayTime = event.type == EventTypes.RoomCreate ||
        nextEvent == null ||
        !event.originServerTs.sameEnvironment(nextEvent!.originServerTs);
    final nextEventSameSender = nextEvent != null &&
        {
          EventTypes.Message,
          EventTypes.Sticker,
          EventTypes.Encrypted,
        }.contains(nextEvent!.type) &&
        nextEvent!.senderId == event.senderId &&
        !displayTime;

    final textColor =
        ownMessage ? theme.onBubbleColor : theme.colorScheme.onSurface;

    final linkColor = ownMessage
        ? theme.brightness == Brightness.light
            ? theme.colorScheme.primaryFixed
            : theme.colorScheme.onTertiaryContainer
        : theme.colorScheme.primary;

    final rowMainAxisAlignment =
        ownMessage ? MainAxisAlignment.end : MainAxisAlignment.start;

    final displayEvent = event.getDisplayEvent(timeline);
    const borderRadius = BorderRadius.all(
      Radius.circular(FluffyThemes.radiusLg),
    );
    final noBubble = ({
              MessageTypes.Video,
              MessageTypes.Image,
              MessageTypes.Sticker,
            }.contains(event.messageType) &&
            event.fileDescription == null &&
            !event.redacted) ||
        (event.messageType == MessageTypes.Text &&
            event.relationshipType == null &&
            event.onlyEmotes &&
            event.numberEmotes > 0 &&
            event.numberEmotes <= 3);

    if (ownMessage) {
      color =
          displayEvent.status.isError ? Colors.redAccent : theme.bubbleColor;
    }

    final resetAnimateIn = this.resetAnimateIn;
    var animateIn = this.animateIn;

    final sentReactions = <String>{};
    if (singleSelected) {
      sentReactions.addAll(
        event
            .aggregatedEvents(
              timeline,
              RelationshipTypes.reaction,
            )
            .where(
              (event) =>
                  event.senderId == event.room.client.userID &&
                  event.type == 'm.reaction',
            )
            .map(
              (event) => event.content
                  .tryGetMap<String, Object?>('m.relates_to')
                  ?.tryGet<String>('key'),
            )
            .whereType<String>(),
      );
    }

    final showReceiptsRow =
        event.hasAggregatedEvents(timeline, RelationshipTypes.reaction);

    final threadChildren =
        event.aggregatedEvents(timeline, RelationshipTypes.thread);

    final showReactionPicker =
        singleSelected && event.room.canSendDefaultMessages;

    final enterThread = this.enterThread;

    // PC 端消息靠边对齐（自己的靠右，对方的靠左），移动端居中
    final Alignment messageAlignment;
    if (PlatformInfos.isDesktop) {
      messageAlignment = ownMessage ? Alignment.topRight : Alignment.topLeft;
    } else {
      messageAlignment = Alignment.center;
    }

    // 消息主体
    final Widget messageWidget = Align(
      alignment: messageAlignment,
      child: Swipeable(
        key: ValueKey(event.eventId),
        background: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12.0),
          child: Center(
            child: Icon(Icons.check_outlined),
          ),
        ),
        direction: AppSettings.swipeRightToLeftToReply.value
            ? SwipeDirection.endToStart
            : SwipeDirection.startToEnd,
        onSwipe: (_) => onSwipe(),
        child: Container(
          constraints: const BoxConstraints(
            maxWidth: FluffyThemes.maxTimelineWidth,
          ),
          padding: EdgeInsets.only(
            top: FluffyThemes.spacing8,
            bottom: FluffyThemes.spacing8,
            left: PlatformInfos.isDesktop ? 0.0 : FluffyThemes.spacing8,
            right: FluffyThemes.spacing8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment:
                ownMessage ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: <Widget>[
              // PC 端时间在外层显示，这里不显示
              if ((displayTime || selected) && !PlatformInfos.isDesktop)
                Padding(
                  padding: displayTime
                      ? const EdgeInsets.symmetric(
                          vertical: FluffyThemes.spacing8,
                        )
                      : EdgeInsets.zero,
                  child: Center(
                    child: Padding(
                      padding:
                          const EdgeInsets.only(top: FluffyThemes.spacing4),
                      child: Material(
                        borderRadius:
                            BorderRadius.circular(FluffyThemes.radiusXl),
                        color: theme.colorScheme.surface.withAlpha(128),
                        elevation: FluffyThemes.elevationXs,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: FluffyThemes.spacing8,
                            vertical: FluffyThemes.spacing2,
                          ),
                          child: Text(
                            event.originServerTs.localizedTime(context),
                            style: TextStyle(
                              fontSize: FluffyThemes.fontSizeSm *
                                  AppSettings.fontSizeFactor.value,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.secondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              StatefulBuilder(
                builder: (context, setState) {
                  if (animateIn && resetAnimateIn != null) {
                    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
                      animateIn = false;
                      setState(resetAnimateIn);
                    });
                  }
                  return AnimatedSize(
                    duration: FluffyThemes.durationFast,
                    curve: FluffyThemes.curveStandard,
                    clipBehavior: Clip.none,
                    alignment: ownMessage
                        ? Alignment.bottomRight
                        : Alignment.bottomLeft,
                    child: animateIn
                        ? const SizedBox(height: 0, width: double.infinity)
                        : Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned(
                                top: 0,
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: Material(
                                  borderRadius: BorderRadius.circular(
                                    FluffyThemes.radiusMd,
                                  ),
                                  // PC 端选择模式下，选择高亮在外层显示
                                  color: (longPressSelect &&
                                          PlatformInfos.isDesktop)
                                      ? Colors.transparent
                                      : (selected || highlightMarker
                                          ? theme.colorScheme.secondaryContainer
                                              .withAlpha(128)
                                          : Colors.transparent),
                                ),
                              ),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: rowMainAxisAlignment,
                                children: [
                                  // PC 端选择模式下勾选框在外层，这里不显示
                                  // 移动端选择模式下仍在这里显示
                                  if (longPressSelect &&
                                      !event.redacted &&
                                      !PlatformInfos.isDesktop)
                                    SizedBox(
                                      height: 32,
                                      width: Avatar.defaultSize,
                                      child: IconButton(
                                        padding: EdgeInsets.zero,
                                        tooltip: L10n.of(context).select,
                                        icon: Icon(
                                          selected
                                              ? Icons.check_circle
                                              : Icons.circle_outlined,
                                        ),
                                        onPressed: () => onSelect(event),
                                      ),
                                    )
                                  else if (ownMessage && !longPressSelect)
                                    SizedBox(
                                      width: Avatar.defaultSize,
                                      child: Center(
                                        child: SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: event.status ==
                                                  EventStatus.error
                                              ? const Icon(
                                                  Icons.error,
                                                  color: Colors.red,
                                                )
                                              : event.fileSendingStatus != null
                                                  ? const CircularProgressIndicator
                                                      .adaptive(
                                                      strokeWidth: 1,
                                                    )
                                                  : null,
                                        ),
                                      ),
                                    )
                                  else if (ownMessage && longPressSelect)
                                    // PC 端选择模式下，自己的消息不显示头像占位
                                    const SizedBox.shrink()
                                  else if (!ownMessage && !longPressSelect)
                                    FutureBuilder<User?>(
                                      future: event.fetchSenderUser(),
                                      builder: (context, snapshot) {
                                        final user = snapshot.data ??
                                            event.senderFromMemoryOrFallback;
                                        final sender =
                                            _resolveSenderPresentation(user);
                                        return Avatar(
                                          mxContent: sender.avatarUrl,
                                          name: sender.displayName,
                                          onTap: () =>
                                              showMemberActionsPopupMenu(
                                            context: context,
                                            user: user,
                                            onMention: onMention,
                                          ),
                                          presenceUserId: user.stateKey,
                                          presenceBackgroundColor: wallpaperMode
                                              ? Colors.transparent
                                              : null,
                                        );
                                      },
                                    )
                                  else if (!ownMessage && longPressSelect)
                                    // PC 端选择模式下，别人的消息也不显示头像（勾选框在外层）
                                    // 移动端保持原有逻辑
                                    PlatformInfos.isDesktop
                                        ? const SizedBox.shrink()
                                        : FutureBuilder<User?>(
                                            future: event.fetchSenderUser(),
                                            builder: (context, snapshot) {
                                              final user = snapshot.data ??
                                                  event
                                                      .senderFromMemoryOrFallback;
                                              final sender =
                                                  _resolveSenderPresentation(
                                                user,
                                              );
                                              return Avatar(
                                                mxContent: sender.avatarUrl,
                                                name: sender.displayName,
                                                onTap: () =>
                                                    showMemberActionsPopupMenu(
                                                  context: context,
                                                  user: user,
                                                  onMention: onMention,
                                                ),
                                                presenceUserId: user.stateKey,
                                                presenceBackgroundColor:
                                                    wallpaperMode
                                                        ? Colors.transparent
                                                        : null,
                                              );
                                            },
                                          ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (!nextEventSameSender)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              left: 8.0,
                                              bottom: 4,
                                            ),
                                            child: ownMessage ||
                                                    event.room.isDirectChat
                                                ? const SizedBox(height: 12)
                                                : FutureBuilder<User?>(
                                                    future:
                                                        event.fetchSenderUser(),
                                                    builder:
                                                        (context, snapshot) {
                                                      final user = snapshot
                                                              .data ??
                                                          event
                                                              .senderFromMemoryOrFallback;
                                                      final displayname =
                                                          _resolveSenderPresentation(
                                                        user,
                                                      ).displayName;
                                                      return Text(
                                                        displayname,
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color: (theme.brightness ==
                                                                  Brightness
                                                                      .light
                                                              ? displayname
                                                                  .color
                                                              : displayname
                                                                  .lightColorText),
                                                          shadows:
                                                              !wallpaperMode
                                                                  ? null
                                                                  : [
                                                                      const Shadow(
                                                                        offset:
                                                                            Offset(
                                                                          0.0,
                                                                          0.0,
                                                                        ),
                                                                        blurRadius:
                                                                            3,
                                                                        color: Colors
                                                                            .black,
                                                                      ),
                                                                    ],
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      );
                                                    },
                                                  ),
                                          ),
                                        Container(
                                          alignment: alignment,
                                          padding:
                                              const EdgeInsets.only(left: 8),
                                          child: GestureDetector(
                                            onLongPress: longPressSelect ||
                                                    PlatformInfos.isDesktop
                                                ? null
                                                : () {
                                                    HapticFeedback
                                                        .heavyImpact();
                                                    onSelect(event);
                                                  },
                                            onSecondaryTap: longPressSelect ||
                                                    !PlatformInfos.isDesktop
                                                ? null
                                                : () => onSelect(event),
                                            child: AnimatedOpacity(
                                              opacity: animateIn
                                                  ? 0
                                                  : event.messageType ==
                                                              MessageTypes
                                                                  .BadEncrypted ||
                                                          event.status.isSending
                                                      ? 0.5
                                                      : 1,
                                              duration:
                                                  FluffyThemes.durationFast,
                                              curve: FluffyThemes.curveStandard,
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  color: noBubble
                                                      ? Colors.transparent
                                                      : color,
                                                  borderRadius: borderRadius,
                                                  boxShadow:
                                                      noBubble || !ownMessage
                                                          ? null
                                                          : FluffyThemes.shadow(
                                                              context,
                                                              elevation:
                                                                  FluffyThemes
                                                                      .elevationSm,
                                                            ),
                                                ),
                                                clipBehavior: Clip.antiAlias,
                                                child: BubbleBackground(
                                                  colors: colors,
                                                  ignore: noBubble ||
                                                      !ownMessage ||
                                                      MediaQuery.highContrastOf(
                                                        context,
                                                      ),
                                                  scrollController:
                                                      scrollController,
                                                  child: Container(
                                                    decoration: BoxDecoration(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                        FluffyThemes.radiusLg,
                                                      ),
                                                    ),
                                                    constraints: BoxConstraints(
                                                      maxWidth: PlatformInfos
                                                              .isDesktop
                                                          ? FluffyThemes
                                                                  .columnWidth *
                                                              1.8
                                                          : FluffyThemes
                                                                  .columnWidth *
                                                              1.5,
                                                    ),
                                                    child: Column(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: <Widget>[
                                                        if (event
                                                                .inReplyToEventId(
                                                              includingFallback:
                                                                  false,
                                                            ) !=
                                                            null)
                                                          FutureBuilder<Event?>(
                                                            future: event
                                                                .getReplyEvent(
                                                              timeline,
                                                            ),
                                                            builder: (
                                                              BuildContext
                                                                  context,
                                                              snapshot,
                                                            ) {
                                                              final replyEvent =
                                                                  snapshot
                                                                          .hasData
                                                                      ? snapshot
                                                                          .data!
                                                                      : Event(
                                                                          eventId:
                                                                              event.inReplyToEventId() ?? '\$fake_event_id',
                                                                          content: {
                                                                            'msgtype':
                                                                                'm.text',
                                                                            'body':
                                                                                '...',
                                                                          },
                                                                          senderId:
                                                                              event.senderId,
                                                                          type:
                                                                              'm.room.message',
                                                                          room:
                                                                              event.room,
                                                                          status:
                                                                              EventStatus.sent,
                                                                          originServerTs:
                                                                              DateTime.now(),
                                                                        );
                                                              return Padding(
                                                                padding:
                                                                    const EdgeInsets
                                                                        .only(
                                                                  left: 16,
                                                                  right: 16,
                                                                  top: 8,
                                                                ),
                                                                child: Material(
                                                                  color: Colors
                                                                      .transparent,
                                                                  borderRadius:
                                                                      ReplyContent
                                                                          .borderRadius,
                                                                  child:
                                                                      InkWell(
                                                                    borderRadius:
                                                                        ReplyContent
                                                                            .borderRadius,
                                                                    onTap: () =>
                                                                        scrollToEventId(
                                                                      replyEvent
                                                                          .eventId,
                                                                    ),
                                                                    child:
                                                                        AbsorbPointer(
                                                                      child:
                                                                          ReplyContent(
                                                                        replyEvent,
                                                                        ownMessage:
                                                                            ownMessage,
                                                                        timeline:
                                                                            timeline,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              );
                                                            },
                                                          ),
                                                        MessageContent(
                                                          displayEvent,
                                                          textColor: textColor,
                                                          linkColor: linkColor,
                                                          onInfoTab: onInfoTab,
                                                          borderRadius:
                                                              borderRadius,
                                                          timeline: timeline,
                                                          selected: selected,
                                                        ),
                                                        if (event
                                                            .hasAggregatedEvents(
                                                          timeline,
                                                          RelationshipTypes
                                                              .edit,
                                                        ))
                                                          Padding(
                                                            padding:
                                                                const EdgeInsets
                                                                    .only(
                                                              bottom: 8.0,
                                                              left: 16.0,
                                                              right: 16.0,
                                                            ),
                                                            child: Row(
                                                              mainAxisSize:
                                                                  MainAxisSize
                                                                      .min,
                                                              spacing: 4.0,
                                                              children: [
                                                                Icon(
                                                                  Icons
                                                                      .edit_outlined,
                                                                  color: textColor
                                                                      .withAlpha(
                                                                    164,
                                                                  ),
                                                                  size: 14,
                                                                ),
                                                                Text(
                                                                  displayEvent
                                                                      .originServerTs
                                                                      .localizedTimeShort(
                                                                    context,
                                                                  ),
                                                                  style:
                                                                      TextStyle(
                                                                    color: textColor
                                                                        .withAlpha(
                                                                      164,
                                                                    ),
                                                                    fontSize:
                                                                        11,
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        Align(
                                          alignment: ownMessage
                                              ? Alignment.bottomRight
                                              : Alignment.bottomLeft,
                                          child: AnimatedSize(
                                            duration:
                                                FluffyThemes.durationFast,
                                            curve: FluffyThemes.curveStandard,
                                            child: showReactionPicker
                                                ? Padding(
                                                    padding:
                                                        const EdgeInsets.all(
                                                      4.0,
                                                    ),
                                                    child: Material(
                                                      elevation: 4,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                        AppConfig.borderRadius,
                                                      ),
                                                      shadowColor: theme
                                                          .colorScheme.surface
                                                          .withAlpha(128),
                                                      child:
                                                          SingleChildScrollView(
                                                        scrollDirection:
                                                            Axis.horizontal,
                                                        child: Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            ...AppConfig
                                                                .defaultReactions
                                                                .map(
                                                              (emoji) =>
                                                                  IconButton(
                                                                padding:
                                                                    EdgeInsets
                                                                        .zero,
                                                                icon: Center(
                                                                  child:
                                                                      Opacity(
                                                                    opacity: sentReactions
                                                                            .contains(
                                                                      emoji,
                                                                    )
                                                                        ? 0.33
                                                                        : 1,
                                                                    child: Text(
                                                                      emoji,
                                                                      style:
                                                                          const TextStyle(
                                                                        fontSize:
                                                                            20,
                                                                      ),
                                                                      textAlign:
                                                                          TextAlign
                                                                              .center,
                                                                    ),
                                                                  ),
                                                                ),
                                                                onPressed:
                                                                    sentReactions
                                                                            .contains(
                                                                  emoji,
                                                                )
                                                                        ? null
                                                                        : () {
                                                                            onSelect(
                                                                              event,
                                                                            );
                                                                            event.room.sendReaction(
                                                                              event.eventId,
                                                                              emoji,
                                                                            );
                                                                          },
                                                              ),
                                                            ),
                                                            IconButton(
                                                              icon: const Icon(
                                                                Icons
                                                                    .add_reaction_outlined,
                                                              ),
                                                              tooltip: L10n.of(
                                                                context,
                                                              ).customReaction,
                                                              onPressed:
                                                                  () async {
                                                                final emoji =
                                                                    await showAdaptiveBottomSheet<
                                                                        String>(
                                                                  context:
                                                                      context,
                                                                  builder:
                                                                      (context) =>
                                                                          Scaffold(
                                                                    appBar:
                                                                        AppBar(
                                                                      title:
                                                                          Text(
                                                                        L10n.of(context)
                                                                            .customReaction,
                                                                      ),
                                                                      leading:
                                                                          CloseButton(
                                                                        onPressed:
                                                                            () =>
                                                                                Navigator.of(
                                                                          context,
                                                                        ).pop(
                                                                          null,
                                                                        ),
                                                                      ),
                                                                    ),
                                                                    body:
                                                                        SizedBox(
                                                                      height: double
                                                                          .infinity,
                                                                      child:
                                                                          EmojiPicker(
                                                                        onEmojiSelected: (
                                                                          _,
                                                                          emoji,
                                                                        ) =>
                                                                            Navigator.of(
                                                                          context,
                                                                        ).pop(
                                                                          emoji
                                                                              .emoji,
                                                                        ),
                                                                        config:
                                                                            Config(
                                                                          locale:
                                                                              Localizations.localeOf(context),
                                                                          emojiViewConfig:
                                                                              const EmojiViewConfig(
                                                                            backgroundColor:
                                                                                Colors.transparent,
                                                                          ),
                                                                          bottomActionBarConfig:
                                                                              const BottomActionBarConfig(
                                                                            enabled:
                                                                                false,
                                                                          ),
                                                                          categoryViewConfig:
                                                                              CategoryViewConfig(
                                                                            initCategory:
                                                                                Category.SMILEYS,
                                                                            backspaceColor:
                                                                                theme.colorScheme.primary,
                                                                            iconColor:
                                                                                theme.colorScheme.primary.withAlpha(
                                                                              128,
                                                                            ),
                                                                            iconColorSelected:
                                                                                theme.colorScheme.primary,
                                                                            indicatorColor:
                                                                                theme.colorScheme.primary,
                                                                            backgroundColor:
                                                                                theme.colorScheme.surface,
                                                                          ),
                                                                          skinToneConfig:
                                                                              SkinToneConfig(
                                                                            dialogBackgroundColor:
                                                                                Color.lerp(
                                                                              theme.colorScheme.surface,
                                                                              theme.colorScheme.primaryContainer,
                                                                              0.75,
                                                                            )!,
                                                                            indicatorColor:
                                                                                theme.colorScheme.onSurface,
                                                                          ),
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                );
                                                                if (emoji ==
                                                                    null) {
                                                                  return;
                                                                }
                                                                if (sentReactions
                                                                    .contains(
                                                                  emoji,
                                                                )) {
                                                                  return;
                                                                }
                                                                onSelect(event);

                                                                await event.room
                                                                    .sendReaction(
                                                                  event.eventId,
                                                                  emoji,
                                                                );
                                                              },
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  )
                                                : const SizedBox.shrink(),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                  );
                },
              ),
              AnimatedSize(
                duration: FluffyThemes.durationFast,
                curve: FluffyThemes.curveStandard,
                alignment: Alignment.bottomCenter,
                child: !showReceiptsRow
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: EdgeInsets.only(
                          top: 4.0,
                          left: (ownMessage ? 0 : Avatar.defaultSize) + 12.0,
                          right: ownMessage ? 0 : 12.0,
                        ),
                        child: MessageReactions(event, timeline),
                      ),
              ),
              if (enterThread != null)
                AnimatedSize(
                  duration: FluffyThemes.durationFast,
                  curve: FluffyThemes.curveStandard,
                  alignment: Alignment.bottomCenter,
                  child: threadChildren.isEmpty
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(
                            top: 2.0,
                            bottom: 8.0,
                            left: Avatar.defaultSize + 8,
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: FluffyThemes.columnWidth * 1.5,
                            ),
                            child: TextButton.icon(
                              style: TextButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                foregroundColor:
                                    theme.colorScheme.onSecondaryContainer,
                                backgroundColor:
                                    theme.colorScheme.secondaryContainer,
                              ),
                              onPressed: () => enterThread(event.eventId),
                              icon: const Icon(Icons.message),
                              label: Text(
                                '${L10n.of(context).countReplies(threadChildren.length)} | ${threadChildren.first.calcLocalizedBodyFallback(
                                  MatrixLocals(L10n.of(context)),
                                  withSenderNamePrefix: true,
                                )}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                ),
              if (displayReadMarker)
                Row(
                  children: [
                    Expanded(
                      child: Divider(
                        color: theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 16.0,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        borderRadius:
                            BorderRadius.circular(AppConfig.borderRadius / 3),
                        color: theme.colorScheme.surface.withAlpha(128),
                      ),
                      child: Text(
                        L10n.of(context).readUpToHere,
                        style: TextStyle(
                          fontSize: 12 * AppSettings.fontSizeFactor.value,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Divider(
                        color: theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );

    // PC 端选择模式下，勾选框独立于消息位置，始终在最左边
    // 选择高亮和时间跨全宽显示
    if (longPressSelect && !event.redacted && PlatformInfos.isDesktop) {
      return Container(
        // 选择高亮背景跨全宽
        color: selected
            ? theme.colorScheme.secondaryContainer.withAlpha(128)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 时间居中显示（跨全宽）
            if (displayTime || selected)
              Padding(
                padding: displayTime
                    ? const EdgeInsets.symmetric(vertical: 8.0)
                    : EdgeInsets.zero,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Material(
                        borderRadius:
                            BorderRadius.circular(AppConfig.borderRadius * 2),
                        color: theme.colorScheme.surface.withAlpha(128),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8.0,
                            vertical: 2.0,
                          ),
                          child: Text(
                            event.originServerTs.localizedTime(context),
                            style: TextStyle(
                              fontSize: 12 * AppSettings.fontSizeFactor.value,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.secondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            // 消息行：勾选框 + 消息内容
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 勾选框始终在最左边
                Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: SizedBox(
                    width: Avatar.defaultSize,
                    height: 32,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      tooltip: L10n.of(context).select,
                      icon: Icon(
                        selected ? Icons.check_circle : Icons.circle_outlined,
                      ),
                      onPressed: () => onSelect(event),
                    ),
                  ),
                ),
                // 消息内容填充剩余空间
                Expanded(child: messageWidget),
              ],
            ),
          ],
        ),
      );
    }

    // PC 端非选择模式下，时间也居中显示
    if (PlatformInfos.isDesktop && (displayTime || selected)) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 时间居中显示（跨全宽）
          Padding(
            padding: displayTime
                ? const EdgeInsets.symmetric(vertical: 8.0)
                : EdgeInsets.zero,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Material(
                    borderRadius:
                        BorderRadius.circular(AppConfig.borderRadius * 2),
                    color: theme.colorScheme.surface.withAlpha(128),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8.0,
                        vertical: 2.0,
                      ),
                      child: Text(
                        event.originServerTs.localizedTime(context),
                        style: TextStyle(
                          fontSize: 12 * AppSettings.fontSizeFactor.value,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 消息内容
          messageWidget,
        ],
      );
    }

    return messageWidget;
  }
}

class BubbleBackground extends StatelessWidget {
  const BubbleBackground({
    super.key,
    required this.scrollController,
    required this.colors,
    required this.ignore,
    required this.child,
  });

  final ScrollController scrollController;
  final List<Color> colors;
  final bool ignore;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (ignore) return child;
    return CustomPaint(
      painter: BubblePainter(
        repaint: scrollController,
        colors: colors,
        context: context,
      ),
      child: child,
    );
  }
}

class BubblePainter extends CustomPainter {
  BubblePainter({
    required this.context,
    required this.colors,
    required super.repaint,
  });

  final BuildContext context;
  final List<Color> colors;
  ScrollableState? _scrollable;

  @override
  void paint(Canvas canvas, Size size) {
    final scrollable = _scrollable ??= Scrollable.of(context);
    final scrollableBox = scrollable.context.findRenderObject() as RenderBox;
    final scrollableRect = Offset.zero & scrollableBox.size;
    final bubbleBox = context.findRenderObject() as RenderBox;

    final origin =
        bubbleBox.localToGlobal(Offset.zero, ancestor: scrollableBox);
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        scrollableRect.topCenter,
        scrollableRect.bottomCenter,
        colors,
        [0.0, 1.0],
        TileMode.clamp,
        Matrix4.translationValues(-origin.dx, -origin.dy, 0.0).storage,
      );
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(BubblePainter oldDelegate) {
    final scrollable = Scrollable.of(context);
    final oldScrollable = _scrollable;
    _scrollable = scrollable;
    return scrollable.position != oldScrollable?.position;
  }
}
