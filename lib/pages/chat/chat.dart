import 'dart:async';
import 'dart:io';
import 'package:psygo/utils/resize_video.dart';
import 'package:psygo/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:collection/collection.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:universal_html/html.dart' as html;
import 'package:url_launcher/url_launcher.dart';

import 'package:psygo/config/setting_keys.dart';
import 'package:psygo/config/themes.dart';
import 'package:psygo/core/config.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/models/agent.dart';
import 'package:psygo/pages/chat/chat_view.dart';
import 'package:psygo/pages/chat/event_info_dialog.dart';
import 'package:psygo/pages/chat/start_poll_bottom_sheet.dart';
import 'package:psygo/pages/chat_details/chat_details.dart';
import 'package:psygo/repositories/agent_repository.dart';
import 'package:psygo/services/agent_service.dart';
import 'package:psygo/utils/adaptive_bottom_sheet.dart';
import 'package:psygo/utils/error_reporter.dart';
import 'package:psygo/utils/fluffy_share.dart';
import 'package:psygo/utils/file_selector.dart';
import 'package:psygo/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:psygo/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:psygo/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:psygo/utils/other_party_can_receive.dart';
import 'package:psygo/utils/platform_infos.dart';
import 'package:psygo/utils/show_scaffold_dialog.dart';
import 'package:psygo/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:psygo/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:psygo/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:psygo/widgets/future_loading_dialog.dart';
import 'package:psygo/widgets/matrix.dart';
import 'package:psygo/widgets/share_scaffold_dialog.dart';

import '../../utils/localized_exception_extension.dart';
import 'send_file_dialog.dart';
import 'send_location_dialog.dart';

class ChatPage extends StatelessWidget {
  final String roomId;
  final List<ShareItem>? shareItems;
  final String? eventId;

  const ChatPage({
    super.key,
    required this.roomId,
    this.eventId,
    this.shareItems,
  });

  @override
  Widget build(BuildContext context) {
    final room = Matrix.of(context).client.getRoomById(roomId);
    if (room == null) {
      return Scaffold(
        appBar: AppBar(title: Text(L10n.of(context).oopsSomethingWentWrong)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(L10n.of(context).youAreNoLongerParticipatingInThisChat),
          ),
        ),
      );
    }

    return ChatPageWithRoom(
      key: Key('chat_page_${roomId}_$eventId'),
      room: room,
      shareItems: shareItems,
      eventId: eventId,
    );
  }
}

class ChatPageWithRoom extends StatefulWidget {
  final Room room;
  final List<ShareItem>? shareItems;
  final String? eventId;

  const ChatPageWithRoom({
    super.key,
    required this.room,
    this.shareItems,
    this.eventId,
  });

  @override
  ChatController createState() => ChatController();
}

class PendingAttachment {
  PendingAttachment({
    required this.id,
    required this.file,
    String? caption,
  })  : captionController = TextEditingController(text: caption ?? ''),
        orderController = TextEditingController();

  final String id;
  final XFile file;
  final TextEditingController captionController;
  final TextEditingController orderController;

  void dispose() {
    captionController.dispose();
    orderController.dispose();
  }
}

class ChatController extends State<ChatPageWithRoom>
    with WidgetsBindingObserver {
  Room get room => sendingClient.getRoomById(roomId) ?? widget.room;

  late Client sendingClient;

  Timeline? timeline;

  String? activeThreadId;

  late final String readMarkerEventId;

  String get roomId => widget.room.id;

  final AutoScrollController scrollController = AutoScrollController();

  late final FocusNode inputFocus;
  StreamSubscription<html.Event>? onFocusSub;

  Timer? typingCoolDown;
  Timer? typingTimeout;
  bool currentlyTyping = false;
  bool dragging = false;
  late final VoidCallback _agentServiceListener;

  // Agent Web entry (reverse-tunnel) state.
  final AgentRepository _webEntryRepository = AgentRepository();
  int _webEntryRequestId = 0;
  bool _webEntryOpen = false;
  bool _webEntryLoading = false;
  String? _webEntryUrl;

  bool get webEntryOpen => _webEntryOpen;
  bool get webEntryLoading => _webEntryLoading;
  String? get webEntryUrl => _webEntryUrl;

  Agent? get webEntryAgent {
    final directChatMatrixID = room.directChatMatrixID;
    return AgentService.instance.getAgentByMatrixUserId(directChatMatrixID);
  }

  bool get canOpenWebEntry => webEntryAgent?.webEntryEnabled == true;

  bool get _supportsInlineWebView {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  }

  void closeWebEntry() {
    // Invalidate any in-flight open request so it can't "re-open" later.
    _webEntryRequestId++;
    if (!_webEntryOpen && !_webEntryLoading && _webEntryUrl == null) return;
    setState(() {
      _webEntryOpen = false;
      _webEntryLoading = false;
      _webEntryUrl = null;
    });
  }

  Future<void> openWebEntry() async {
    final agent = webEntryAgent;
    if (agent == null) return;
    if (_webEntryLoading) return;
    final l10n = L10n.of(context);

    if (!agent.webEntryEnabled) {
      final l10n = L10n.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.chatWebEntryNotEnabled)),
      );
      return;
    }

    final requestId = ++_webEntryRequestId;
    setState(() => _webEntryLoading = true);

    try {
      final path = await _webEntryRepository.getWebEntryUrl(agent.agentId);
      if (!mounted || requestId != _webEntryRequestId) return;

      final base = PsygoConfig.baseUrl.replaceAll(RegExp(r'/+$'), '');
      final fullUrl = base + path;
      final uri = Uri.tryParse(fullUrl);
      if (uri == null) {
        throw Exception('Invalid web entry url');
      }

      if (!_supportsInlineWebView) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }

      setState(() {
        _webEntryUrl = fullUrl;
        _webEntryOpen = true;
      });
    } catch (_) {
      if (!mounted || requestId != _webEntryRequestId) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.chatOpenFailedRetryLater)),
      );
    } finally {
      if (mounted && requestId == _webEntryRequestId) {
        setState(() => _webEntryLoading = false);
      }
    }
  }

  void onDragEntered(_) => setState(() => dragging = true);

  void onDragExited(_) => setState(() => dragging = false);

  void onDragDone(DropDoneDetails details) async {
    setState(() => dragging = false);
    if (details.files.isEmpty) return;

    if (PlatformInfos.isDesktop) {
      addPendingAttachments(details.files);
      return;
    }

    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: details.files,
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  Future<bool> handlePasteFilesFromClipboard(BuildContext context) async {
    List<XFile> files;
    try {
      files = await _filesFromClipboard();
    } catch (_) {
      return false;
    }
    if (files.isEmpty) {
      return false;
    }
    if (PlatformInfos.isDesktop) {
      addPendingAttachments(files);
      return true;
    }
    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: files,
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
    return true;
  }

  Future<List<XFile>> _filesFromClipboard() async {
    for (final format in const [
      Clipboard.kTextPlain,
      'text/uri-list',
      'x-special/gnome-copied-files',
      'x-special/nautilus-clipboard',
      'application/x-gtk-file-list',
    ]) {
      ClipboardData? data;
      try {
        data = await Clipboard.getData(format);
      } catch (_) {
        data = null;
      }
      final files = _filesFromClipboardText(data?.text);
      if (files.isNotEmpty) {
        return files;
      }
    }
    return [];
  }

  List<XFile> _filesFromClipboardText(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return [];
    }
    final files = <XFile>[];
    final seen = <String>{};
    for (final entry in raw.split(RegExp(r'[\r\n]+'))) {
      final file = _fileFromClipboardEntry(entry);
      if (file == null) continue;
      if (seen.add(file.path)) {
        files.add(file);
      }
    }
    return files;
  }

  XFile? _fileFromClipboardEntry(String entry) {
    final trimmed = entry.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      return null;
    }

    String? path;
    if (trimmed.startsWith('file://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri != null) {
        path = uri.toFilePath(windows: Platform.isWindows);
      }
    } else if (Platform.isWindows) {
      if (RegExp(r'^[a-zA-Z]:[\\\\/]').hasMatch(trimmed)) {
        path = trimmed;
      }
    } else if (trimmed.startsWith('/')) {
      path = trimmed;
    }

    if (path == null) {
      return null;
    }
    final file = File(path);
    if (!file.existsSync()) {
      return null;
    }
    return XFile(file.path);
  }

  bool get canSaveSelectedEvent =>
      selectedEvents.length == 1 &&
      {
        MessageTypes.Video,
        MessageTypes.Image,
        MessageTypes.Sticker,
        MessageTypes.Audio,
        MessageTypes.File,
      }.contains(selectedEvents.single.messageType);

  void saveSelectedEvent(context) => selectedEvents.single.saveFile(context);

  List<Event> selectedEvents = [];

  final Set<String> unfolded = {};

  Event? replyEvent;

  Event? editEvent;

  bool _scrolledUp = false;

  bool get showScrollDownButton =>
      _scrolledUp || timeline?.allowNewEvent == false;

  /// Scroll to the read marker position ("读到此处")
  void scrollToReadMarker() {
    if (readMarkerEventId.isEmpty) return;
    scrollToEventId(readMarkerEventId, highlightEvent: false);
  }

  bool get selectMode => selectedEvents.isNotEmpty;

  final int _loadHistoryCount = 100;

  String pendingText = '';

  bool showEmojiPicker = false;

  String? get threadLastEventId {
    final threadId = activeThreadId;
    if (threadId == null) return null;
    return timeline?.events
        .filterByVisibleInGui(threadId: threadId)
        .firstOrNull
        ?.eventId;
  }

  void enterThread(String eventId) => setState(() {
        activeThreadId = eventId;
        selectedEvents.clear();
      });

  void closeThread() => setState(() {
        activeThreadId = null;
        selectedEvents.clear();
      });

  void recreateChat() async {
    final room = this.room;
    final userId = room.directChatMatrixID;
    if (userId == null) {
      throw Exception(
        'Try to recreate a room with is not a DM room. This should not be possible from the UI!',
      );
    }
    await showFutureLoadingDialog(
      context: context,
      future: () => room.invite(userId),
    );
  }

  void leaveChat() async {
    final success = await showFutureLoadingDialog(
      context: context,
      future: room.leave,
    );
    if (success.error != null) return;
    context.go('/rooms');
  }

  void requestHistory([_]) async {
    Logs().v('Requesting history...');
    await timeline?.requestHistory(historyCount: _loadHistoryCount);
  }

  void requestFuture() async {
    final timeline = this.timeline;
    if (timeline == null) return;
    Logs().v('Requesting future...');
    final mostRecentEventId = timeline.events.first.eventId;
    await timeline.requestFuture(historyCount: _loadHistoryCount);
    setReadMarker(eventId: mostRecentEventId);
  }

  void _updateScrollController() {
    if (!mounted) {
      return;
    }
    if (!scrollController.hasClients) return;
    if (timeline?.allowNewEvent == false ||
        scrollController.position.pixels > 0 && _scrolledUp == false) {
      setState(() => _scrolledUp = true);
    } else if (scrollController.position.pixels <= 0 && _scrolledUp == true) {
      setState(() => _scrolledUp = false);
      setReadMarker();
    }

    if (scrollController.position.pixels == 0 ||
        scrollController.position.pixels == 64) {
      requestFuture();
    }
  }

  void _loadDraft() async {
    final prefs = Matrix.of(context).store;
    final draft = prefs.getString('draft_$roomId');
    if (draft != null && draft.isNotEmpty) {
      sendController.text = draft;
    }
  }

  void _shareItems([_]) {
    final shareItems = widget.shareItems;
    if (shareItems == null || shareItems.isEmpty) return;
    if (!room.otherPartyCanReceiveMessages) {
      final theme = Theme.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: theme.colorScheme.errorContainer,
          closeIconColor: theme.colorScheme.onErrorContainer,
          content: Text(
            L10n.of(context).otherPartyNotLoggedIn,
            style: TextStyle(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          showCloseIcon: true,
        ),
      );
      return;
    }
    for (final item in shareItems) {
      if (item is FileShareItem) continue;
      if (item is TextShareItem) room.sendTextEvent(item.value);
      if (item is ContentShareItem) room.sendEvent(item.value);
    }
    final files = shareItems
        .whereType<FileShareItem>()
        .map((item) => item.value)
        .toList();
    if (files.isEmpty) return;
    showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: files,
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  KeyEventResult _customEnterKeyHandling(FocusNode node, KeyEvent evt) {
    if (!HardwareKeyboard.instance.isShiftPressed &&
        evt.logicalKey.keyLabel == 'Enter' &&
        AppSettings.sendOnEnter.value) {
      if (evt is KeyDownEvent) {
        send();
      }
      return KeyEventResult.handled;
    } else if (evt.logicalKey.keyLabel == 'Enter' && evt is KeyDownEvent) {
      final currentLineNum = sendController.text
              .substring(
                0,
                sendController.selection.baseOffset,
              )
              .split('\n')
              .length -
          1;
      final currentLine = sendController.text.split('\n')[currentLineNum];

      for (final pattern in [
        '- [ ] ',
        '- [x] ',
        '* [ ] ',
        '* [x] ',
        '- ',
        '* ',
        '+ ',
      ]) {
        if (currentLine.startsWith(pattern)) {
          if (currentLine == pattern) {
            return KeyEventResult.ignored;
          }
          sendController.text += '\n$pattern';
          return KeyEventResult.handled;
        }
      }

      return KeyEventResult.ignored;
    } else {
      return KeyEventResult.ignored;
    }
  }

  @override
  void initState() {
    inputFocus = FocusNode(onKeyEvent: _customEnterKeyHandling);

    _agentServiceListener = () {
      if (!mounted) return;
      setState(() {});
    };
    AgentService.instance.agentsNotifier.addListener(_agentServiceListener);

    scrollController.addListener(_updateScrollController);
    inputFocus.addListener(_inputFocusListener);

    _loadDraft();
    WidgetsBinding.instance.addPostFrameCallback(_shareItems);
    super.initState();
    _displayChatDetailsColumn = ValueNotifier(
      AppSettings.displayChatDetailsColumn.value,
    );

    sendingClient = Matrix.of(context).client;
    final lastEventThreadId =
        room.lastEvent?.relationshipType == RelationshipTypes.thread
            ? room.lastEvent?.relationshipEventId
            : null;
    readMarkerEventId =
        room.hasNewMessages ? lastEventThreadId ?? room.fullyRead : '';
    WidgetsBinding.instance.addObserver(this);
    _tryLoadTimeline();
    if (kIsWeb) {
      onFocusSub = html.window.onFocus.listen((_) => setReadMarker());
    }
  }

  final Set<String> expandedEventIds = {};

  void expandEventsFrom(Event event, bool expand) {
    final events = timeline!.events.filterByVisibleInGui(
      threadId: activeThreadId,
    );
    final start = events.indexOf(event);
    setState(() {
      for (var i = start; i < events.length; i++) {
        final event = events[i];
        if (!event.isCollapsedState) return;
        if (expand) {
          expandedEventIds.add(event.eventId);
        } else {
          expandedEventIds.remove(event.eventId);
        }
      }
    });
  }

  void _tryLoadTimeline() async {
    final initialEventId = widget.eventId;
    loadTimelineFuture = _getTimeline();
    try {
      await loadTimelineFuture;
      // We launched the chat with a given initial event ID:
      if (initialEventId != null) {
        scrollToEventId(initialEventId);
        return;
      }

      var readMarkerEventIndex = readMarkerEventId.isEmpty
          ? -1
          : timeline!.events
              .filterByVisibleInGui(
                exceptionEventId: readMarkerEventId,
                threadId: activeThreadId,
              )
              .indexWhere((e) => e.eventId == readMarkerEventId);

      // Read marker is existing but not found in first events. Try a single
      // requestHistory call before opening timeline on event context:
      if (readMarkerEventId.isNotEmpty && readMarkerEventIndex == -1) {
        await timeline?.requestHistory(historyCount: _loadHistoryCount);
        readMarkerEventIndex = timeline!.events
            .filterByVisibleInGui(
              exceptionEventId: readMarkerEventId,
              threadId: activeThreadId,
            )
            .indexWhere((e) => e.eventId == readMarkerEventId);
      }

      // PC 端直接滚动到最新消息，移动端保持原来的行为（滚动到未读标记位置）
      if (PlatformInfos.isDesktop) {
        // PC 端：延迟滚动到最新消息，确保 timeline 完全渲染
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted && scrollController.hasClients) {
            scrollController.jumpTo(0);
            setReadMarker();
          }
        });
      } else if (readMarkerEventIndex > 1) {
        Logs().v('Scroll up to visible event', readMarkerEventId);
        scrollToEventId(readMarkerEventId, highlightEvent: false);
        return;
      } else if (readMarkerEventId.isNotEmpty && readMarkerEventIndex == -1) {
        _showScrollUpMaterialBanner(readMarkerEventId);
      }

      // Mark room as read on first visit if requirements are fulfilled
      setReadMarker();

      if (!mounted) return;
    } catch (e, s) {
      if (!mounted) return;
      ErrorReporter(context, 'Unable to load timeline').onErrorCallback(e, s);
      rethrow;
    }
  }

  String? scrollUpBannerEventId;

  void discardScrollUpBannerEventId() => setState(() {
        scrollUpBannerEventId = null;
      });

  void _showScrollUpMaterialBanner(String eventId) => setState(() {
        scrollUpBannerEventId = eventId;
      });

  void updateView() {
    if (!mounted) return;
    setReadMarker();
    setState(() {});
  }

  Future<void>? loadTimelineFuture;

  int? animateInEventIndex;

  void onInsert(int i) {
    // setState will be called by updateView() anyway
    animateInEventIndex = i;
  }

  Future<void> _getTimeline({
    String? eventContextId,
  }) async {
    await Matrix.of(context).client.roomsLoading;
    await Matrix.of(context).client.accountDataLoading;
    if (eventContextId != null &&
        (!eventContextId.isValidMatrixId || eventContextId.sigil != '\$')) {
      eventContextId = null;
    }
    try {
      timeline?.cancelSubscriptions();
      timeline = await room.getTimeline(
        onUpdate: updateView,
        eventContextId: eventContextId,
        onInsert: onInsert,
      );
    } catch (e, s) {
      Logs().w('Unable to load timeline on event ID $eventContextId', e, s);
      if (!mounted) return;
      timeline = await room.getTimeline(
        onUpdate: updateView,
        onInsert: onInsert,
      );
      if (!mounted) return;
      if (e is TimeoutException || e is IOException) {
        _showScrollUpMaterialBanner(eventContextId!);
      }
    }
    timeline!.requestKeys(onlineKeyBackupOnly: false);
    if (room.markedUnread) room.markUnread(false);

    return;
  }

  String? scrollToEventIdMarker;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!mounted) return;
    setReadMarker();
  }

  Future<void>? _setReadMarkerFuture;

  void setReadMarker({String? eventId}) {
    if (eventId?.isValidMatrixId == false) return;
    if (_setReadMarkerFuture != null) return;
    if (_scrolledUp) return;
    if (scrollUpBannerEventId != null) return;

    if (eventId == null &&
        !room.isUnread &&
        !room.hasNewMessages &&
        room.notificationCount == 0) {
      return;
    }

    // Do not send read markers when app is not in foreground
    if (kIsWeb && !Matrix.of(context).webHasFocus) return;
    // Only check app lifecycle state on mobile, desktop doesn't need this check
    if (!kIsWeb &&
        !PlatformInfos.isDesktop &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }

    final timeline = this.timeline;
    if (timeline == null || timeline.events.isEmpty) return;

    Logs().d('Set read marker...', eventId);
    // ignore: unawaited_futures
    _setReadMarkerFuture = timeline
        .setReadMarker(
      eventId: eventId,
      public: AppSettings.sendPublicReadReceipts.value,
    )
        .then((_) {
      _setReadMarkerFuture = null;
    });
    if (eventId == null || eventId == timeline.room.lastEvent?.eventId) {
      Matrix.of(context).backgroundPush?.cancelNotification(roomId);
    }
  }

  @override
  void dispose() {
    AgentService.instance.agentsNotifier.removeListener(_agentServiceListener);
    _webEntryRepository.dispose();
    timeline?.cancelSubscriptions();
    timeline = null;
    inputFocus.removeListener(_inputFocusListener);
    onFocusSub?.cancel();
    _disposePendingAttachments();
    super.dispose();
  }

  TextEditingController sendController = TextEditingController();
  final List<PendingAttachment> _pendingAttachments = [];
  int _pendingAttachmentSerial = 0;
  bool pendingAttachmentsCompress = true;

  List<PendingAttachment> get pendingAttachments =>
      List.unmodifiable(_pendingAttachments);
  bool get hasPendingAttachments => _pendingAttachments.isNotEmpty;
  bool get hasCompressiblePendingAttachments =>
      _pendingAttachments.any(_isCompressibleAttachment);

  bool _isCompressibleAttachment(PendingAttachment attachment) {
    final path = attachment.file.path.isNotEmpty
        ? attachment.file.path
        : attachment.file.name;
    final mimeType = attachment.file.mimeType ?? lookupMimeType(path);
    if (mimeType == null) return false;
    return mimeType.startsWith('image') || mimeType.startsWith('video');
  }

  void _syncPendingAttachmentOrderControllers() {
    for (var i = 0; i < _pendingAttachments.length; i++) {
      _pendingAttachments[i].orderController.text = '${i + 1}';
    }
  }

  void _disposePendingAttachments() {
    for (final attachment in _pendingAttachments) {
      attachment.dispose();
    }
    _pendingAttachments.clear();
  }

  void addPendingAttachments(List<XFile> files) {
    if (!PlatformInfos.isDesktop || files.isEmpty) return;
    setState(() {
      for (final file in files) {
        _pendingAttachments.add(
          PendingAttachment(
            id: 'pending_${_pendingAttachmentSerial++}',
            file: file,
          ),
        );
      }
      _syncPendingAttachmentOrderControllers();
    });
  }

  void removePendingAttachment(PendingAttachment attachment) {
    if (!_pendingAttachments.contains(attachment)) return;
    setState(() {
      _pendingAttachments.remove(attachment);
      _syncPendingAttachmentOrderControllers();
    });
    attachment.dispose();
  }

  void reorderPendingAttachment(
    PendingAttachment attachment,
    String? rawIndex,
  ) {
    final currentIndex = _pendingAttachments.indexOf(attachment);
    if (currentIndex == -1) return;
    final parsedIndex = int.tryParse(rawIndex ?? '');
    if (parsedIndex == null) {
      setState(() => _syncPendingAttachmentOrderControllers());
      return;
    }
    final clamped = parsedIndex.clamp(1, _pendingAttachments.length) as int;
    final newIndex = clamped - 1;
    if (newIndex == currentIndex) {
      setState(() => _syncPendingAttachmentOrderControllers());
      return;
    }
    setState(() {
      _pendingAttachments.removeAt(currentIndex);
      _pendingAttachments.insert(newIndex, attachment);
      _syncPendingAttachmentOrderControllers();
    });
  }

  void setPendingAttachmentsCompress(bool value) {
    if (pendingAttachmentsCompress == value) return;
    setState(() => pendingAttachmentsCompress = value);
  }

  void handleKeyboardInsertedContent(KeyboardInsertedContent content) {
    final data = content.data;
    if (data == null) return;
    if (PlatformInfos.isDesktop) {
      final name = _fileNameFromInsertedContent(content.uri);
      addPendingAttachments(
        [XFile.fromData(data, name: name, mimeType: content.mimeType)],
      );
      return;
    }
    final file = MatrixFile(
      mimeType: content.mimeType,
      bytes: data,
      name: _fileNameFromInsertedContent(content.uri),
    );
    room.sendFileEvent(
      file,
      shrinkImageMaxDimension: 1600,
    );
  }

  String _fileNameFromInsertedContent(String uri) {
    if (uri.isEmpty) return 'attachment';
    final sanitized = uri.replaceAll('\\', '/');
    final parts = sanitized.split('/');
    for (var i = parts.length - 1; i >= 0; i--) {
      final part = parts[i].trim();
      if (part.isNotEmpty) return part;
    }
    return 'attachment';
  }

  void setSendingClient(Client c) {
    // first cancel typing with the old sending client
    if (currentlyTyping) {
      // no need to have the setting typing to false be blocking
      typingCoolDown?.cancel();
      typingCoolDown = null;
      room.setTyping(false);
      currentlyTyping = false;
    }
    // then cancel the old timeline
    // fixes bug with read reciepts and quick switching
    loadTimelineFuture = _getTimeline(eventContextId: room.fullyRead).onError(
      ErrorReporter(
        context,
        'Unable to load timeline after changing sending Client',
      ).onErrorCallback,
    );

    // then set the new sending client
    setState(() => sendingClient = c);
  }

  void setActiveClient(Client c) => setState(() {
        Matrix.of(context).setActiveClient(c);
      });

  Future<void> send() async {
    // If user sends a message while WebView is open, return to chat first.
    if (_webEntryOpen || _webEntryLoading) {
      closeWebEntry();
    }

    final trimmedText = sendController.text.trim();
    final hasPending =
        PlatformInfos.isDesktop && _pendingAttachments.isNotEmpty;
    if (!hasPending && trimmedText.isEmpty) return;

    if (hasPending) {
      final sent = await _sendPendingAttachments();
      if (!sent) return;
    }

    if (trimmedText.isEmpty) {
      return;
    }

    _storeInputTimeoutTimer?.cancel();
    final prefs = Matrix.of(context).store;
    prefs.remove('draft_$roomId');
    var parseCommands = true;

    final commandMatch = RegExp(r'^\/(\w+)').firstMatch(sendController.text);
    if (commandMatch != null &&
        !sendingClient.commands.keys.contains(commandMatch[1]!.toLowerCase())) {
      final l10n = L10n.of(context);
      final dialogResult = await showOkCancelAlertDialog(
        context: context,
        title: l10n.commandInvalid,
        message: l10n.commandMissing(commandMatch[0]!),
        okLabel: l10n.sendAsText,
        cancelLabel: l10n.cancel,
      );
      if (dialogResult == OkCancelResult.cancel) return;
      parseCommands = false;
    }

    // ignore: unawaited_futures
    room.sendTextEvent(
      sendController.text,
      inReplyTo: replyEvent,
      editEventId: editEvent?.eventId,
      parseCommands: parseCommands,
      threadRootEventId: activeThreadId,
    );
    sendController.value = TextEditingValue(
      text: pendingText,
      selection: const TextSelection.collapsed(offset: 0),
    );

    setState(() {
      sendController.text = pendingText;
      _inputTextIsEmpty = pendingText.isEmpty;
      replyEvent = null;
      editEvent = null;
      pendingText = '';
    });
  }

  static const int _minSizeToCompress = 20 * 1000;

  Future<bool> _sendPendingAttachments() async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final l10n = L10n.of(context);

    try {
      if (!room.otherPartyCanReceiveMessages) {
        throw OtherPartyCanNotReceiveMessages();
      }

      _showLoadingSnackBar(scaffoldMessenger, l10n.prepareSendingAttachment);
      final clientConfig = await room.client.getConfig();
      final maxUploadSize = clientConfig.mUploadSize ?? 100 * 1000 * 1000;

      final attachments = List<PendingAttachment>.from(_pendingAttachments);
      for (var i = 0; i < attachments.length; i++) {
        final attachment = attachments[i];
        final xfile = attachment.file;
        final length = await xfile.length();
        final mimeType = xfile.mimeType ??
            lookupMimeType(xfile.path.isNotEmpty ? xfile.path : xfile.name);

        if (length > maxUploadSize) {
          throw FileTooBigMatrixException(length, maxUploadSize);
        }

        MatrixFile file;
        MatrixImageFile? thumbnail;

        if (PlatformInfos.isMobile &&
            mimeType != null &&
            mimeType.startsWith('video')) {
          _showLoadingSnackBar(
              scaffoldMessenger, l10n.generatingVideoThumbnail);
          thumbnail = await xfile.getVideoThumbnail();
          _showLoadingSnackBar(scaffoldMessenger, l10n.compressVideo);
          file = await xfile.getVideoInfo(
            compress: length > _minSizeToCompress && pendingAttachmentsCompress,
          );
        } else {
          file = MatrixFile(
            bytes: await xfile.readAsBytes(),
            name: xfile.name,
            mimeType: mimeType,
          ).detectFileType;
        }

        if (file.bytes.length > maxUploadSize) {
          throw FileTooBigMatrixException(length, maxUploadSize);
        }

        if (attachments.length > 1) {
          _showLoadingSnackBar(
            scaffoldMessenger,
            l10n.sendingAttachmentCountOfCount(i + 1, attachments.length),
          );
        }

        final caption = attachment.captionController.text.trim();
        try {
          await room.sendFileEvent(
            file,
            thumbnail: thumbnail,
            shrinkImageMaxDimension: pendingAttachmentsCompress ? 1600 : null,
            extraContent: caption.isEmpty ? null : {'body': caption},
            threadRootEventId: activeThreadId,
            threadLastEventId: threadLastEventId,
          );
        } on MatrixException catch (e) {
          final retryAfterMs = e.retryAfterMs;
          if (e.error != MatrixError.M_LIMIT_EXCEEDED || retryAfterMs == null) {
            rethrow;
          }
          final retryAfterDuration =
              Duration(milliseconds: retryAfterMs + 1000);

          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(
                l10n.serverLimitReached(retryAfterDuration.inSeconds),
              ),
            ),
          );
          await Future.delayed(retryAfterDuration);

          _showLoadingSnackBar(scaffoldMessenger, l10n.sendingAttachment);

          await room.sendFileEvent(
            file,
            thumbnail: thumbnail,
            shrinkImageMaxDimension: pendingAttachmentsCompress ? 1600 : null,
            extraContent: caption.isEmpty ? null : {'body': caption},
            threadRootEventId: activeThreadId,
            threadLastEventId: threadLastEventId,
          );
        }

        removePendingAttachment(attachment);
      }

      scaffoldMessenger.clearSnackBars();
      return true;
    } catch (e) {
      scaffoldMessenger.clearSnackBars();
      _showAttachmentError(scaffoldMessenger, e);
      return false;
    }
  }

  void _showLoadingSnackBar(
    ScaffoldMessengerState scaffoldMessenger,
    String title,
  ) {
    scaffoldMessenger.clearSnackBars();
    scaffoldMessenger.showSnackBar(
      SnackBar(
        duration: const Duration(minutes: 5),
        dismissDirection: DismissDirection.none,
        content: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator.adaptive(
                strokeWidth: 2,
              ),
            ),
            const SizedBox(width: 16),
            Text(title),
          ],
        ),
      ),
    );
  }

  void _showAttachmentError(
    ScaffoldMessengerState scaffoldMessenger,
    Object error,
  ) {
    final theme = Theme.of(context);
    scaffoldMessenger.showSnackBar(
      SnackBar(
        backgroundColor: theme.colorScheme.errorContainer,
        closeIconColor: theme.colorScheme.onErrorContainer,
        content: Text(
          error.toLocalizedString(context),
          style: TextStyle(color: theme.colorScheme.onErrorContainer),
        ),
        duration: const Duration(seconds: 30),
        showCloseIcon: true,
      ),
    );
  }

  void sendFileAction({FileSelectorType type = FileSelectorType.any}) async {
    final files = await selectFiles(
      context,
      allowMultiple: true,
      type: type,
    );
    if (files.isEmpty) return;
    if (PlatformInfos.isDesktop) {
      addPendingAttachments(files);
      return;
    }
    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: files,
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  void sendImageFromClipBoard(Uint8List? image) async {
    if (image == null) return;
    if (PlatformInfos.isDesktop) {
      addPendingAttachments(
        [XFile.fromData(image, name: 'clipboard_image.png')],
      );
      return;
    }
    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: [XFile.fromData(image)],
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  void openCameraAction() async {
    // Make sure the textfield is unfocused before opening the camera
    FocusScope.of(context).requestFocus(FocusNode());
    final file = await ImagePicker().pickImage(source: ImageSource.camera);
    if (file == null) return;

    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: [file],
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  void openVideoCameraAction() async {
    // Make sure the textfield is unfocused before opening the camera
    FocusScope.of(context).requestFocus(FocusNode());
    final file = await ImagePicker().pickVideo(
      source: ImageSource.camera,
      maxDuration: const Duration(minutes: 1),
    );
    if (file == null) return;

    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: [file],
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  Future<void> onVoiceMessageSend(
    String path,
    int duration,
    List<int> waveform,
    String? fileName,
  ) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final audioFile = XFile(path);

    final bytesResult = await showFutureLoadingDialog(
      context: context,
      future: audioFile.readAsBytes,
    );
    final bytes = bytesResult.result;
    if (bytes == null) return;

    final file = MatrixAudioFile(
      bytes: bytes,
      name: fileName ?? audioFile.path,
    );

    setState(() {
      replyEvent = null;
    });
    room.sendFileEvent(
      file,
      inReplyTo: replyEvent,
      threadRootEventId: activeThreadId,
      extraContent: {
        'info': {
          ...file.info,
          'duration': duration,
        },
        'org.matrix.msc3245.voice': {},
        'org.matrix.msc1767.audio': {
          'duration': duration,
          'waveform': waveform,
        },
      },
    ).catchError((e) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(
            (e as Object).toLocalizedString(context),
          ),
        ),
      );
      return null;
    });
    return;
  }

  void hideEmojiPicker() {
    setState(() => showEmojiPicker = false);
  }

  void emojiPickerAction() {
    if (showEmojiPicker) {
      inputFocus.requestFocus();
    } else {
      inputFocus.unfocus();
    }
    setState(() => showEmojiPicker = !showEmojiPicker);
  }

  void _inputFocusListener() {
    if (showEmojiPicker && inputFocus.hasFocus) {
      setState(() => showEmojiPicker = false);
    }
  }

  void sendLocationAction() async {
    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendLocationDialog(room: room),
    );
  }

  String _getSelectedEventString() {
    var copyString = '';
    if (selectedEvents.length == 1) {
      return selectedEvents.first
          .getDisplayEvent(timeline!)
          .calcLocalizedBodyFallback(MatrixLocals(L10n.of(context)));
    }
    for (final event in selectedEvents) {
      if (copyString.isNotEmpty) copyString += '\n\n';
      copyString += event.getDisplayEvent(timeline!).calcLocalizedBodyFallback(
            MatrixLocals(L10n.of(context)),
            withSenderNamePrefix: true,
          );
    }
    return copyString;
  }

  void copyEventsAction() {
    Clipboard.setData(ClipboardData(text: _getSelectedEventString()));
    setState(() {
      showEmojiPicker = false;
      selectedEvents.clear();
    });
  }

  void shareEventsAction() async {
    final text = _getSelectedEventString();
    await FluffyShare.share(text, context);
    setState(() {
      showEmojiPicker = false;
      selectedEvents.clear();
    });
  }

  void reportEventAction() async {
    final event = selectedEvents.single;
    final score = await showModalActionPopup<int>(
      context: context,
      title: L10n.of(context).reportMessage,
      message: L10n.of(context).howOffensiveIsThisContent,
      cancelLabel: L10n.of(context).cancel,
      actions: [
        AdaptiveModalAction(
          value: -100,
          label: L10n.of(context).extremeOffensive,
        ),
        AdaptiveModalAction(
          value: -50,
          label: L10n.of(context).offensive,
        ),
        AdaptiveModalAction(
          value: 0,
          label: L10n.of(context).inoffensive,
        ),
      ],
    );
    if (score == null) return;
    final reason = await showTextInputDialog(
      context: context,
      title: L10n.of(context).whyDoYouWantToReportThis,
      okLabel: L10n.of(context).ok,
      cancelLabel: L10n.of(context).cancel,
      hintText: L10n.of(context).reason,
    );
    if (reason == null || reason.isEmpty) return;
    final result = await showFutureLoadingDialog(
      context: context,
      future: () => Matrix.of(context).client.reportEvent(
            event.roomId!,
            event.eventId,
            reason: reason,
            score: score,
          ),
    );
    if (result.error != null) return;
    setState(() {
      showEmojiPicker = false;
      selectedEvents.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.of(context).contentHasBeenReported)),
    );
  }

  void deleteErrorEventsAction() async {
    try {
      if (selectedEvents.any((event) => event.status != EventStatus.error)) {
        throw Exception(
          'Tried to delete failed to send events but one event is not failed to sent',
        );
      }
      for (final event in selectedEvents) {
        await event.cancelSend();
      }
      setState(selectedEvents.clear);
    } catch (e, s) {
      ErrorReporter(
        context,
        'Error while delete error events action',
      ).onErrorCallback(e, s);
    }
  }

  void redactEventsAction() async {
    final reasonInput = selectedEvents.any((event) => event.status.isSent)
        ? await showTextInputDialog(
            context: context,
            title: L10n.of(context).redactMessage,
            message: L10n.of(context).redactMessageDescription,
            isDestructive: true,
            hintText: L10n.of(context).optionalRedactReason,
            maxLength: 255,
            maxLines: 3,
            minLines: 1,
            okLabel: L10n.of(context).remove,
            cancelLabel: L10n.of(context).cancel,
          )
        : null;
    if (reasonInput == null) return;
    final reason = reasonInput.isEmpty ? null : reasonInput;
    await showFutureLoadingDialog(
      context: context,
      futureWithProgress: (onProgress) async {
        final count = selectedEvents.length;
        for (final (i, event) in selectedEvents.indexed) {
          onProgress(i / count);
          if (event.status.isSent) {
            if (event.canRedact) {
              await event.redactEvent(reason: reason);
            } else {
              final client = currentRoomBundle.firstWhereOrNull(
                (cl) => selectedEvents.first.senderId == cl.userID,
              );
              if (client == null) {
                return;
              }
              final room = client.getRoomById(roomId)!;
              await Event.fromJson(event.toJson(), room).redactEvent(
                reason: reason,
              );
            }
          } else {
            await event.cancelSend();
          }
        }
      },
    );
    setState(() {
      showEmojiPicker = false;
      selectedEvents.clear();
    });
  }

  List<Client> get currentRoomBundle {
    final clients = Matrix.of(context).currentBundle;
    clients.removeWhere((c) => c.getRoomById(roomId) == null);
    return clients;
  }

  bool get canRedactSelectedEvents {
    if (isArchived) return false;
    final clients = Matrix.of(context).currentBundle;
    for (final event in selectedEvents) {
      if (!event.status.isSent) return false;
      if (event.canRedact == false &&
          !(clients.any((cl) => event.senderId == cl.userID))) {
        return false;
      }
    }
    return true;
  }

  bool get canPinSelectedEvents {
    if (isArchived ||
        !room.canChangeStateEvent(EventTypes.RoomPinnedEvents) ||
        selectedEvents.length != 1 ||
        !selectedEvents.single.status.isSent ||
        activeThreadId != null) {
      return false;
    }
    return true;
  }

  bool get canEditSelectedEvents {
    if (isArchived ||
        selectedEvents.length != 1 ||
        !selectedEvents.first.status.isSent) {
      return false;
    }
    return currentRoomBundle
        .any((cl) => selectedEvents.first.senderId == cl.userID);
  }

  void forwardEventsAction() async {
    if (selectedEvents.isEmpty) return;
    final timeline = this.timeline;
    if (timeline == null) return;

    final forwardEvents = List<Event>.from(selectedEvents)
        .map((event) => event.getDisplayEvent(timeline))
        .toList();

    await showScaffoldDialog(
      context: context,
      builder: (context) => ShareScaffoldDialog(
        items: forwardEvents
            .map((event) => ContentShareItem(event.content))
            .toList(),
      ),
    );
    if (!mounted) return;
    setState(() => selectedEvents.clear());
  }

  void sendAgainAction() {
    final event = selectedEvents.first;
    if (event.status.isError) {
      event.sendAgain();
    }
    final allEditEvents = event
        .aggregatedEvents(timeline!, RelationshipTypes.edit)
        .where((e) => e.status.isError);
    for (final e in allEditEvents) {
      e.sendAgain();
    }
    setState(() => selectedEvents.clear());
  }

  void replyAction({Event? replyTo}) {
    setState(() {
      replyEvent = replyTo ?? selectedEvents.first;
      selectedEvents.clear();
    });
    inputFocus.requestFocus();
  }

  void scrollToEventId(
    String eventId, {
    bool highlightEvent = true,
  }) async {
    final foundEvent =
        timeline!.events.firstWhereOrNull((event) => event.eventId == eventId);

    final eventIndex = foundEvent == null
        ? -1
        : timeline!.events
            .filterByVisibleInGui(
              exceptionEventId: eventId,
              threadId: activeThreadId,
            )
            .indexOf(foundEvent);

    if (eventIndex == -1) {
      setState(() {
        timeline = null;
        _scrolledUp = false;
        loadTimelineFuture = _getTimeline(eventContextId: eventId).onError(
          ErrorReporter(context, 'Unable to load timeline after scroll to ID')
              .onErrorCallback,
        );
      });
      await loadTimelineFuture;
      WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
        scrollToEventId(eventId);
      });
      return;
    }
    if (highlightEvent) {
      setState(() {
        scrollToEventIdMarker = eventId;
      });
    }
    await scrollController.scrollToIndex(
      eventIndex + 1,
      duration: FluffyThemes.durationFast,
      preferPosition: AutoScrollPosition.middle,
    );
    _updateScrollController();
  }

  void scrollDown() async {
    if (!timeline!.allowNewEvent) {
      setState(() {
        timeline = null;
        _scrolledUp = false;
        loadTimelineFuture = _getTimeline().onError(
          ErrorReporter(context, 'Unable to load timeline after scroll down')
              .onErrorCallback,
        );
      });
      await loadTimelineFuture;
    }
    scrollController.jumpTo(0);
  }

  void onEmojiSelected(_, Emoji? emoji) {
    typeEmoji(emoji);
    onInputBarChanged(sendController.text);
  }

  void typeEmoji(Emoji? emoji) {
    if (emoji == null) return;
    final text = sendController.text;
    final selection = sendController.selection;
    final newText = sendController.text.isEmpty
        ? emoji.emoji
        : text.replaceRange(selection.start, selection.end, emoji.emoji);
    sendController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        // don't forget an UTF-8 combined emoji might have a length > 1
        offset: selection.baseOffset + emoji.emoji.length,
      ),
    );
  }

  void emojiPickerBackspace() {
    sendController
      ..text = sendController.text.characters.skipLast(1).toString()
      ..selection = TextSelection.fromPosition(
        TextPosition(offset: sendController.text.length),
      );
  }

  void clearSelectedEvents() => setState(() {
        selectedEvents.clear();
        showEmojiPicker = false;
      });

  void clearSingleSelectedEvent() {
    if (selectedEvents.length <= 1) {
      clearSelectedEvents();
    }
  }

  void editSelectedEventAction() {
    final client = currentRoomBundle.firstWhereOrNull(
      (cl) => selectedEvents.first.senderId == cl.userID,
    );
    if (client == null) {
      return;
    }
    setSendingClient(client);
    setState(() {
      pendingText = sendController.text;
      editEvent = selectedEvents.first;
      sendController.text =
          editEvent!.getDisplayEvent(timeline!).calcLocalizedBodyFallback(
                MatrixLocals(L10n.of(context)),
                withSenderNamePrefix: false,
                hideReply: true,
              );
      selectedEvents.clear();
    });
    inputFocus.requestFocus();
  }

  void goToNewRoomAction() async {
    final newRoomId = room
        .getState(EventTypes.RoomTombstone)!
        .parsedTombstoneContent
        .replacementRoom;
    final result = await showFutureLoadingDialog(
      context: context,
      future: () => room.client.joinRoom(
        room
            .getState(EventTypes.RoomTombstone)!
            .parsedTombstoneContent
            .replacementRoom,
        via: [newRoomId.domain!],
      ),
    );
    if (result.error != null) return;
    if (!mounted) return;
    context.go('/rooms/${result.result!}');

    await showFutureLoadingDialog(
      context: context,
      future: room.leave,
    );
  }

  void onSelectMessage(Event event) {
    if (!event.redacted) {
      if (selectedEvents.contains(event)) {
        setState(
          () => selectedEvents.remove(event),
        );
      } else {
        setState(
          () => selectedEvents.add(event),
        );
      }
      selectedEvents.sort(
        (a, b) => a.originServerTs.compareTo(b.originServerTs),
      );
    }
  }

  int? findChildIndexCallback(Key key, Map<String, int> thisEventsKeyMap) {
    // this method is called very often. As such, it has to be optimized for speed.
    if (key is! ValueKey) {
      return null;
    }
    final eventId = key.value;
    if (eventId is! String) {
      return null;
    }
    // first fetch the last index the event was at
    final index = thisEventsKeyMap[eventId];
    if (index == null) {
      return null;
    }
    // we need to +1 as 0 is the typing thing at the bottom
    return index + 1;
  }

  void onInputBarSubmitted(_) {
    send();
    FocusScope.of(context).requestFocus(inputFocus);
  }

  void onAddPopupMenuButtonSelected(AddPopupMenuActions choice) {
    room.client.getConfig();

    switch (choice) {
      case AddPopupMenuActions.image:
        sendFileAction(type: FileSelectorType.images);
        return;
      case AddPopupMenuActions.video:
        sendFileAction(type: FileSelectorType.videos);
        return;
      case AddPopupMenuActions.file:
        sendFileAction();
        return;
      case AddPopupMenuActions.poll:
        showAdaptiveBottomSheet(
          context: context,
          builder: (context) => StartPollBottomSheet(room: room),
        );
        return;
      case AddPopupMenuActions.photoCamera:
        openCameraAction();
        return;
      case AddPopupMenuActions.videoCamera:
        openVideoCameraAction();
        return;
      case AddPopupMenuActions.location:
        sendLocationAction();
        return;
    }
  }

  unpinEvent(String eventId) async {
    final response = await showOkCancelAlertDialog(
      context: context,
      title: L10n.of(context).unpin,
      message: L10n.of(context).confirmEventUnpin,
      okLabel: L10n.of(context).unpin,
      cancelLabel: L10n.of(context).cancel,
    );
    if (response == OkCancelResult.ok) {
      final events = room.pinnedEventIds
        ..removeWhere((oldEvent) => oldEvent == eventId);
      showFutureLoadingDialog(
        context: context,
        future: () => room.setPinnedEvents(events),
      );
    }
  }

  void pinEvent() {
    final pinnedEventIds = room.pinnedEventIds;
    final selectedEventIds = selectedEvents.map((e) => e.eventId).toSet();
    final unpin = selectedEventIds.length == 1 &&
        pinnedEventIds.contains(selectedEventIds.single);
    if (unpin) {
      pinnedEventIds.removeWhere(selectedEventIds.contains);
    } else {
      pinnedEventIds.addAll(selectedEventIds);
    }
    showFutureLoadingDialog(
      context: context,
      future: () => room.setPinnedEvents(pinnedEventIds),
    );
  }

  Timer? _storeInputTimeoutTimer;
  static const Duration _storeInputTimeout = Duration(milliseconds: 500);

  void onInputBarChanged(String text) {
    if (_inputTextIsEmpty != text.isEmpty) {
      setState(() {
        _inputTextIsEmpty = text.isEmpty;
      });
    }

    _storeInputTimeoutTimer?.cancel();
    _storeInputTimeoutTimer = Timer(_storeInputTimeout, () async {
      final prefs = Matrix.of(context).store;
      await prefs.setString('draft_$roomId', text);
    });
    if (AppSettings.sendTypingNotifications.value) {
      typingCoolDown?.cancel();
      typingCoolDown = Timer(const Duration(seconds: 2), () {
        typingCoolDown = null;
        currentlyTyping = false;
        room.setTyping(false);
      });
      typingTimeout ??= Timer(const Duration(seconds: 30), () {
        typingTimeout = null;
        currentlyTyping = false;
      });
      if (!currentlyTyping) {
        currentlyTyping = true;
        room.setTyping(
          true,
          timeout: const Duration(seconds: 30).inMilliseconds,
        );
      }
    }
  }

  bool _inputTextIsEmpty = true;

  bool get isArchived =>
      {Membership.leave, Membership.ban}.contains(room.membership);

  void showEventInfo([Event? event]) =>
      (event ?? selectedEvents.single).showInfoDialog(context);

  void onPhoneButtonTap() async {
    // VoIP required Android SDK 21
    if (PlatformInfos.isAndroid) {
      DeviceInfoPlugin().androidInfo.then((value) {
        if (value.version.sdkInt < 21) {
          Navigator.pop(context);
          showOkAlertDialog(
            context: context,
            title: L10n.of(context).unsupportedAndroidVersion,
            message: L10n.of(context).unsupportedAndroidVersionLong,
            okLabel: L10n.of(context).close,
          );
        }
      });
    }
    final callType = await showModalActionPopup<CallType>(
      context: context,
      title: L10n.of(context).warning,
      message: L10n.of(context).videoCallsBetaWarning,
      cancelLabel: L10n.of(context).cancel,
      actions: [
        AdaptiveModalAction(
          label: L10n.of(context).voiceCall,
          icon: const Icon(Icons.phone_outlined),
          value: CallType.kVoice,
        ),
        AdaptiveModalAction(
          label: L10n.of(context).videoCall,
          icon: const Icon(Icons.video_call_outlined),
          value: CallType.kVideo,
        ),
      ],
    );
    if (callType == null) return;

    final voipPlugin = Matrix.of(context).voipPlugin;
    try {
      await voipPlugin!.voip.inviteToCall(room, callType);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toLocalizedString(context))),
      );
    }
  }

  void cancelReplyEventAction() => setState(() {
        if (editEvent != null) {
          sendController.text = pendingText;
          pendingText = '';
        }
        replyEvent = null;
        editEvent = null;
      });

  late final ValueNotifier<bool> _displayChatDetailsColumn;

  void toggleDisplayChatDetailsColumn() async {
    await AppSettings.displayChatDetailsColumn.setItem(
      !_displayChatDetailsColumn.value,
    );
    _displayChatDetailsColumn.value = !_displayChatDetailsColumn.value;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: ChatView(this),
        ),
        ValueListenableBuilder(
          valueListenable: _displayChatDetailsColumn,
          builder: (context, displayChatDetailsColumn, _) =>
              !FluffyThemes.isThreeColumnMode(context) ||
                      room.membership != Membership.join ||
                      !displayChatDetailsColumn
                  ? const SizedBox(
                      height: double.infinity,
                      width: 0,
                    )
                  : Container(
                      width: FluffyThemes.columnWidth,
                      clipBehavior: Clip.hardEdge,
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            width: 1,
                            color: theme.dividerColor,
                          ),
                        ),
                      ),
                      child: ChatDetails(
                        roomId: roomId,
                        embeddedCloseButton: IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: toggleDisplayChatDetailsColumn,
                        ),
                      ),
                    ),
        ),
      ],
    );
  }
}

enum AddPopupMenuActions {
  image,
  video,
  file,
  poll,
  photoCamera,
  videoCamera,
  location,
}
