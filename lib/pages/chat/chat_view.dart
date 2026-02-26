import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:badges/badges.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:matrix/matrix.dart';

import 'package:psygo/config/setting_keys.dart';
import 'package:psygo/config/themes.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/models/agent.dart';
import 'package:psygo/pages/chat/chat.dart';
import 'package:psygo/pages/chat/chat_app_bar_list_tile.dart';
import 'package:psygo/pages/chat/chat_app_bar_title.dart';
import 'package:psygo/pages/chat/chat_event_list.dart';
import 'package:psygo/pages/chat/pinned_events.dart';
import 'package:psygo/pages/chat/reply_display.dart';
import 'package:psygo/repositories/agent_repository.dart';
import 'package:psygo/services/agent_service.dart';
import 'package:psygo/utils/account_config.dart';
import 'package:psygo/utils/localized_exception_extension.dart';
import 'package:psygo/widgets/chat_settings_popup_menu.dart';
import 'package:psygo/widgets/future_loading_dialog.dart';
import 'package:psygo/widgets/agent_web_entry_view.dart';
import 'package:psygo/widgets/matrix.dart';
import 'package:psygo/widgets/mxc_image.dart';
import 'package:psygo/widgets/unread_rooms_badge.dart';
import 'package:psygo/utils/platform_infos.dart';
import '../../utils/stream_extension.dart';
import 'chat_emoji_picker.dart';
import 'chat_input_row.dart';

enum _EventContextAction { info, report }

class ChatView extends StatelessWidget {
  final ChatController controller;

  const ChatView(this.controller, {super.key});

  List<Widget> _appBarActions(BuildContext context) {
    if (controller.selectMode) {
      return [
        if (controller.canEditSelectedEvents)
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: L10n.of(context).edit,
            onPressed: controller.editSelectedEventAction,
          ),
        if (controller.selectedEvents.length == 1 &&
            controller.activeThreadId == null &&
            controller.room.canSendDefaultMessages)
          IconButton(
            icon: const Icon(Icons.message_outlined),
            tooltip: L10n.of(context).replyInThread,
            onPressed: () => controller
                .enterThread(controller.selectedEvents.single.eventId),
          ),
        if (controller.canPinSelectedEvents)
          IconButton(
            icon: const Icon(Icons.push_pin_outlined),
            onPressed: controller.pinEvent,
            tooltip: L10n.of(context).pinMessage,
          ),
        if (controller.canRedactSelectedEvents)
          IconButton(
            icon: const Icon(Icons.delete_outlined),
            tooltip: L10n.of(context).redactMessage,
            onPressed: controller.redactEventsAction,
          ),
        if (controller.selectedEvents.length == 1)
          PopupMenuButton<_EventContextAction>(
            useRootNavigator: true,
            onSelected: (action) {
              switch (action) {
                case _EventContextAction.info:
                  controller.showEventInfo();
                  controller.clearSelectedEvents();
                  break;
                case _EventContextAction.report:
                  controller.reportEventAction();
                  break;
              }
            },
            itemBuilder: (context) => [
              if (controller.canSaveSelectedEvent)
                PopupMenuItem(
                  onTap: () => controller.saveSelectedEvent(context),
                  value: null,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.download_outlined),
                      const SizedBox(width: 12),
                      Text(L10n.of(context).downloadFile),
                    ],
                  ),
                ),
              PopupMenuItem(
                value: _EventContextAction.info,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.info_outlined),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).messageInfo),
                  ],
                ),
              ),
              if (controller.selectedEvents.single.status.isSent)
                PopupMenuItem(
                  value: _EventContextAction.report,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.shield_outlined,
                        color: Colors.red,
                      ),
                      const SizedBox(width: 12),
                      Text(L10n.of(context).reportMessage),
                    ],
                  ),
                ),
            ],
          ),
      ];
    } else if (!controller.room.isArchived) {
      final directChatMatrixID = controller.room.directChatMatrixID;
      return [
        if (directChatMatrixID != null)
          ValueListenableBuilder<List<Agent>>(
            valueListenable: AgentService.instance.agentsNotifier,
            builder: (context, _, __) {
              final agent = AgentService.instance
                  .getAgentByMatrixUserId(directChatMatrixID);
              if (agent == null) return const SizedBox.shrink();

              return IconButton(
                tooltip: controller.webEntryOpen ? '返回聊天' : '打开 WebView',
                onPressed: controller.webEntryOpen || controller.webEntryLoading
                    ? controller.closeWebEntry
                    : (agent.webEntryEnabled
                        ? () => controller.openWebEntry()
                        : null),
                icon: controller.webEntryLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        controller.webEntryOpen
                            ? Icons.arrow_back
                            : Icons.web_outlined,
                      ),
              );
            },
          ),
        if (AppSettings.experimentalVoip.value &&
            Matrix.of(context).voipPlugin != null &&
            controller.room.isDirectChat)
          IconButton(
            onPressed: controller.onPhoneButtonTap,
            icon: const Icon(Icons.call_outlined),
            tooltip: L10n.of(context).placeCall,
          ),
        ChatSettingsPopupMenu(controller.room, true),
      ];
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (controller.room.membership == Membership.invite) {
      showFutureLoadingDialog(
        context: context,
        future: () => controller.room.join(),
        exceptionContext: ExceptionContext.joinRoom,
      );
    }
    final bottomSheetPadding = FluffyThemes.isColumnMode(context) ? 16.0 : 8.0;
    final scrollUpBannerEventId = controller.scrollUpBannerEventId;

    final accountConfig = Matrix.of(context).client.applicationAccountConfig;

    return PopScope(
      canPop: controller.selectedEvents.isEmpty &&
          !controller.showEmojiPicker &&
          controller.activeThreadId == null &&
          !controller.webEntryOpen &&
          !controller.webEntryLoading,
      onPopInvokedWithResult: (pop, _) async {
        if (pop) return;
        if (controller.webEntryOpen || controller.webEntryLoading) {
          controller.closeWebEntry();
        } else if (controller.selectedEvents.isNotEmpty) {
          controller.clearSelectedEvents();
        } else if (controller.showEmojiPicker) {
          controller.emojiPickerAction();
        } else if (controller.activeThreadId != null) {
          controller.closeThread();
        }
      },
      child: StreamBuilder(
        stream: controller.room.client.onRoomState.stream
            .where((update) => update.roomId == controller.room.id)
            .rateLimit(const Duration(seconds: 1)),
        builder: (context, snapshot) => FutureBuilder(
          future: controller.loadTimelineFuture,
          builder: (BuildContext context, snapshot) {
            var appbarBottomHeight = 0.0;
            final activeThreadId = controller.activeThreadId;
            if (activeThreadId != null) {
              appbarBottomHeight += ChatAppBarListTile.fixedHeight;
            }
            if (controller.room.pinnedEventIds.isNotEmpty &&
                activeThreadId == null) {
              appbarBottomHeight += ChatAppBarListTile.fixedHeight;
            }
            if (scrollUpBannerEventId != null && activeThreadId == null) {
              appbarBottomHeight += ChatAppBarListTile.fixedHeight;
            }
            return Scaffold(
              appBar: AppBar(
                actionsIconTheme: IconThemeData(
                  color: controller.selectedEvents.isEmpty
                      ? null
                      : theme.colorScheme.onTertiaryContainer,
                ),
                backgroundColor: controller.selectedEvents.isEmpty
                    ? controller.activeThreadId != null
                        ? theme.colorScheme.secondaryContainer
                        : null
                    : theme.colorScheme.tertiaryContainer,
                automaticallyImplyLeading: false,
                leading: controller.selectMode
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: controller.clearSelectedEvents,
                        tooltip: L10n.of(context).close,
                        color: theme.colorScheme.onTertiaryContainer,
                      )
                    : activeThreadId != null
                        ? IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: controller.closeThread,
                            tooltip: L10n.of(context).backToMainChat,
                            color: theme.colorScheme.onSecondaryContainer,
                          )
                        : FluffyThemes.isColumnMode(context)
                            ? null
                            : StreamBuilder<Object>(
                                stream: Matrix.of(context)
                                    .client
                                    .onSync
                                    .stream
                                    .where(
                                      (syncUpdate) => syncUpdate.hasRoomUpdate,
                                    ),
                                builder: (context, _) => UnreadRoomsBadge(
                                  filter: (r) => r.id != controller.roomId,
                                  badgePosition:
                                      BadgePosition.topEnd(end: 8, top: 4),
                                  child: const Center(child: BackButton()),
                                ),
                              ),
                titleSpacing: FluffyThemes.isColumnMode(context) ? 24 : 0,
                title: ChatAppBarTitle(controller),
                actions: _appBarActions(context),
                bottom: PreferredSize(
                  preferredSize: Size.fromHeight(appbarBottomHeight),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PinnedEvents(controller),
                      if (activeThreadId != null)
                        SizedBox(
                          height: ChatAppBarListTile.fixedHeight,
                          child: Center(
                            child: TextButton.icon(
                              onPressed: () =>
                                  controller.scrollToEventId(activeThreadId),
                              icon: const Icon(Icons.message),
                              label: Text(L10n.of(context).replyInThread),
                              style: TextButton.styleFrom(
                                foregroundColor:
                                    theme.colorScheme.onSecondaryContainer,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (scrollUpBannerEventId != null &&
                          activeThreadId == null)
                        ChatAppBarListTile(
                          leading: IconButton(
                            color: theme.colorScheme.onSurfaceVariant,
                            icon: const Icon(Icons.close),
                            tooltip: L10n.of(context).close,
                            onPressed: () {
                              controller.discardScrollUpBannerEventId();
                              controller.setReadMarker();
                            },
                          ),
                          title: L10n.of(context).jumpToLastReadMessage,
                          trailing: TextButton(
                            onPressed: () {
                              controller.scrollToEventId(
                                scrollUpBannerEventId,
                              );
                              controller.discardScrollUpBannerEventId();
                            },
                            child: Text(L10n.of(context).jump),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              floatingActionButtonLocation:
                  FloatingActionButtonLocation.miniCenterFloat,
              floatingActionButton: controller.showScrollDownButton &&
                      controller.selectedEvents.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 56.0),
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              theme.colorScheme.primaryContainer,
                              theme.colorScheme.secondaryContainer,
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.2),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: FloatingActionButton(
                          onPressed: controller.scrollDown,
                          heroTag: null,
                          mini: true,
                          backgroundColor: Colors.transparent,
                          foregroundColor: theme.colorScheme.primary,
                          elevation: 0,
                          child: const Icon(Icons.arrow_downward_rounded,
                              size: 20),
                        ),
                      ),
                    )
                  : null,
              body: DropTarget(
                onDragDone: controller.onDragDone,
                onDragEntered: controller.onDragEntered,
                onDragExited: controller.onDragExited,
                child: Stack(
                  children: <Widget>[
                    if (accountConfig.wallpaperUrl != null)
                      Opacity(
                        opacity: accountConfig.wallpaperOpacity ?? 0.5,
                        child: ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(
                            sigmaX: accountConfig.wallpaperBlur ?? 0.0,
                            sigmaY: accountConfig.wallpaperBlur ?? 0.0,
                          ),
                          child: MxcImage(
                            cacheKey: accountConfig.wallpaperUrl.toString(),
                            uri: accountConfig.wallpaperUrl,
                            fit: BoxFit.cover,
                            height: MediaQuery.sizeOf(context).height,
                            width: MediaQuery.sizeOf(context).width,
                            isThumbnail: false,
                            placeholder: (_) => Container(),
                          ),
                        ),
                      ),
                    SafeArea(
                      child: Column(
                        children: <Widget>[
                          Expanded(
                            child: controller.webEntryOpen &&
                                    controller.webEntryUrl != null
                                ? AgentWebEntryView(
                                    url: controller.webEntryUrl!)
                                : Stack(
                                    children: [
                                      GestureDetector(
                                        onTap:
                                            controller.clearSingleSelectedEvent,
                                        child: ChatEventList(
                                            controller: controller),
                                      ),
                                      // Scroll to last read position button
                                      if (controller
                                          .readMarkerEventId.isNotEmpty)
                                        Positioned(
                                          top: 8,
                                          right: 8,
                                          child: Material(
                                            color: theme
                                                .colorScheme.primaryContainer,
                                            borderRadius:
                                                BorderRadius.circular(20),
                                            child: InkWell(
                                              onTap:
                                                  controller.scrollToReadMarker,
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 12,
                                                  vertical: 8,
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      Icons.arrow_upward,
                                                      size: 16,
                                                      color: theme.colorScheme
                                                          .onPrimaryContainer,
                                                    ),
                                                    const SizedBox(width: 4),
                                                    const Text(
                                                      '新消息',
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                          ),
                          if (controller.showScrollDownButton)
                            Divider(
                              height: 1,
                              color: theme.dividerColor,
                            ),
                          if (controller.room.isExtinct)
                            Container(
                              margin: EdgeInsets.all(bottomSheetPadding),
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.chevron_right),
                                label: Text(L10n.of(context).enterNewChat),
                                onPressed: controller.goToNewRoomAction,
                              ),
                            )
                          else if (controller.room.canSendDefaultMessages &&
                              controller.room.membership == Membership.join)
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  margin: PlatformInfos.isDesktop
                                      ? EdgeInsets.only(
                                          top: bottomSheetPadding,
                                          left: 60.0,
                                          right: 60.0,
                                          bottom: 4, // 减小底部间距
                                        )
                                      : EdgeInsets.only(
                                          top: bottomSheetPadding,
                                          left: bottomSheetPadding,
                                          right: bottomSheetPadding,
                                          bottom: 4, // 减小底部间距
                                        ),
                                  constraints: PlatformInfos.isDesktop
                                      ? null // PC 端不限制宽度，动态适应
                                      : const BoxConstraints(
                                          maxWidth:
                                              FluffyThemes.maxTimelineWidth,
                                        ),
                                  alignment: PlatformInfos.isDesktop
                                      ? null // PC 端不居中
                                      : Alignment.center,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Material(
                                        clipBehavior: Clip.hardEdge,
                                        color:
                                            controller.selectedEvents.isNotEmpty
                                                ? theme.colorScheme
                                                    .tertiaryContainer
                                                : theme.colorScheme
                                                    .surfaceContainerHigh,
                                        borderRadius: const BorderRadius.all(
                                          Radius.circular(24),
                                        ),
                                        child: controller
                                                    .room.isAbandonedDMRoom ==
                                                true
                                            ? Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment
                                                        .spaceEvenly,
                                                children: [
                                                  TextButton.icon(
                                                    style: TextButton.styleFrom(
                                                      padding:
                                                          const EdgeInsets.all(
                                                        16,
                                                      ),
                                                      foregroundColor: theme
                                                          .colorScheme.error,
                                                    ),
                                                    icon: const Icon(
                                                      Icons.archive_outlined,
                                                    ),
                                                    onPressed:
                                                        controller.leaveChat,
                                                    label: Text(
                                                      L10n.of(context)
                                                          .declineInvitation,
                                                    ),
                                                  ),
                                                  TextButton.icon(
                                                    style: TextButton.styleFrom(
                                                      padding:
                                                          const EdgeInsets.all(
                                                        16,
                                                      ),
                                                    ),
                                                    icon: const Icon(
                                                      Icons.forum_outlined,
                                                    ),
                                                    onPressed:
                                                        controller.recreateChat,
                                                    label: Text(
                                                      L10n.of(context)
                                                          .reopenChat,
                                                    ),
                                                  ),
                                                ],
                                              )
                                            : Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  ReplyDisplay(controller),
                                                  ChatInputRow(controller),
                                                  ChatEmojiPicker(controller),
                                                ],
                                              ),
                                      ),
                                      // AI 内容免责声明（在 Material 外面，但在 Container margin 里面）
                                      _AiContentDisclaimer(
                                          room: controller.room),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    if (controller.dragging)
                      Container(
                        color: theme.scaffoldBackgroundColor.withAlpha(230),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.upload_outlined,
                          size: 100,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// AI 内容免责声明
/// 只要聊天中有员工就显示
class _AiContentDisclaimer extends StatefulWidget {
  final Room room;

  const _AiContentDisclaimer({required this.room});

  @override
  State<_AiContentDisclaimer> createState() => _AiContentDisclaimerState();
}

class _AiContentDisclaimerState extends State<_AiContentDisclaimer> {
  /// 员工信息（如果对方是员工）
  Agent? _employee;

  /// Agent 仓库
  final AgentRepository _repository = AgentRepository();

  @override
  void initState() {
    super.initState();
    _initEmployeeStatus();
  }

  @override
  void dispose() {
    _repository.dispose();
    super.dispose();
  }

  /// 初始化员工状态
  void _initEmployeeStatus() {
    final directChatMatrixID = widget.room.directChatMatrixID;

    if (directChatMatrixID == null) return;

    // 从缓存中快速查找（用于立即显示）
    final cachedEmployee =
        AgentService.instance.getAgentByMatrixUserId(directChatMatrixID);
    if (cachedEmployee != null) {
      setState(() => _employee = cachedEmployee);
    } else {
      // 缓存没有，直接调用 API 获取
      _fetchAndCheckEmployee(directChatMatrixID);
    }
  }

  /// 获取并检查是否是员工
  Future<void> _fetchAndCheckEmployee(String matrixUserId) async {
    try {
      final page = await _repository.getUserAgents(limit: 50);
      final agent =
          page.agents.where((a) => a.matrixUserId == matrixUserId).firstOrNull;
      if (mounted && agent != null) {
        setState(() => _employee = agent);
      }
    } catch (_) {
      // 出错时不显示
    }
  }

  @override
  Widget build(BuildContext context) {
    // 没有员工，不显示
    if (_employee == null) {
      return const SizedBox.shrink();
    }

    // 有员工，显示 AI 提示
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        L10n.of(context).aiContentDisclaimer,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 10,
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}
