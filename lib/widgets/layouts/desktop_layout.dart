import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:psygo/config/themes.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/models/hire_result.dart';
import 'package:psygo/pages/chat/chat.dart';
import 'package:psygo/pages/chat_list/chat_list.dart';
import 'package:psygo/pages/team/employees_tab.dart';
import 'package:psygo/pages/wallet/wallet_page.dart';
import 'package:psygo/repositories/agent_template_repository.dart';
import 'package:psygo/services/agent_service.dart';
import 'package:psygo/utils/fluffy_share.dart';
import 'package:psygo/utils/platform_infos.dart';
import 'package:psygo/utils/window_service.dart';
import 'package:psygo/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:psygo/widgets/avatar.dart';
import 'package:psygo/widgets/custom_hire_dialog.dart';
import 'package:psygo/widgets/future_loading_dialog.dart';
import 'package:psygo/widgets/hire_success_dialog.dart';
import 'package:psygo/widgets/layouts/empty_page.dart';
import 'package:psygo/widgets/matrix.dart';

/// PC 端主页索引
enum DesktopPageIndex {
  messages(0),
  employees(1);

  final int value;
  const DesktopPageIndex(this.value);
}

/// PC 端桌面布局 - 自定义顶部双入口导航（消息 / 员工）
/// 只用于桌面端，不影响移动端
class DesktopLayout extends StatefulWidget {
  final String? activeChat;
  final DesktopPageIndex initialPage;

  const DesktopLayout({
    super.key,
    this.activeChat,
    this.initialPage = DesktopPageIndex.messages,
  });

  /// 清除用户缓存（退出登录时调用）
  static void clearUserCache() {
    _DesktopLayoutState.clearUserCache();
  }

  @override
  State<DesktopLayout> createState() => _DesktopLayoutState();
}

class _DesktopLayoutState extends State<DesktopLayout> {
  // 保存消息列表宽度
  static double _chatListWidth = FluffyThemes.columnWidth;
  // 缓存未读计数
  static int _cachedUnreadCount = 0;
  // Profile 版本号（用于通知实例刷新缓存）
  static int _profileVersion = 0;

  /// 清除用户缓存（退出登录或更新头像时调用）
  static void clearUserCache() {
    debugPrint('[DesktopLayout] clearUserCache called');
    _cachedUnreadCount = 0;
    _profileVersion++; // 递增版本号，通知实例刷新
  }

  // Profile Future（实例变量，和设置页面一样的模式）
  Future<Profile>? _profileFuture;
  int _lastProfileVersion = 0; // 记录上次使用的版本号

  // 消息列表最小/最大宽度
  static const double _minChatListWidth = 280.0;
  static const double _maxChatListWidth = 500.0;

  late DesktopPageIndex _currentPage;
  int _unreadCount = 0;
  bool _isDraggingDivider = false;

  // 监听同步事件以更新未读计数
  StreamSubscription? _syncSubscription;

  // 各页面的 Key，用于刷新
  final GlobalKey<EmployeesTabState> _employeesTabKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _currentPage = widget.activeChat != null
        ? DesktopPageIndex.messages
        : widget.initialPage;
    // 先使用缓存的未读计数
    _unreadCount = _cachedUnreadCount;
    // 延迟到 context 可用后初始化
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateUnreadCount();
      _setupSyncListener();
    });
  }

  void _setupSyncListener() {
    if (!mounted) return;
    try {
      final client = Matrix.of(context).clientOrNull;
      if (client == null) return;
      _syncSubscription = client.onSync.stream.listen((_) {
        _updateUnreadCount();
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _syncSubscription?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(DesktopLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeChat == null &&
        widget.initialPage != oldWidget.initialPage &&
        _currentPage != widget.initialPage) {
      setState(() => _currentPage = widget.initialPage);
      return;
    }
    // 当 activeChat 变化且当前不在消息页面时，自动切换到消息页面
    if (widget.activeChat != null &&
        widget.activeChat != oldWidget.activeChat &&
        _currentPage != DesktopPageIndex.messages) {
      setState(() => _currentPage = DesktopPageIndex.messages);
    }
  }

  void _updateUnreadCount() {
    if (!mounted) return;
    try {
      final client = Matrix.of(context).clientOrNull;
      if (client == null) return;
      var count = 0;
      for (final room in client.rooms) {
        if (room.isUnreadOrInvited) {
          count += room.notificationCount;
        }
      }
      // 更新缓存和状态
      _cachedUnreadCount = count;
      if (_unreadCount != count) {
        setState(() => _unreadCount = count);
      }
    } catch (_) {}
  }

  void _onPageSelected(int index) {
    final newPage = DesktopPageIndex.values[index];
    if (_currentPage != newPage) {
      setState(() => _currentPage = newPage);
      if (newPage != DesktopPageIndex.messages && widget.activeChat != null) {
        context.go('/rooms');
      }
    }
  }

  /// 刷新员工列表
  void _refreshEmployeeList() {
    _employeesTabKey.currentState?.refreshEmployeeList();
  }

  Future<void> _openRecruitMenu() async {
    final repository = AgentTemplateRepository();

    try {
      final result = await showDialog<HireResult>(
        context: context,
        builder: (_) => Dialog(
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: CustomHireDialog(
              repository: repository,
              isDialog: true,
            ),
          ),
        ),
      );

      if (!mounted || result == null) return;

      _refreshEmployeeList();
      unawaited(AgentService.instance.refresh());

      final displayName = result.displayName.trim();
      final employeeName = displayName.isNotEmpty ? displayName : 'Employee';

      showHireSuccessDialog(
        context: context,
        employeeName: employeeName,
        onViewEmployee: _refreshEmployeeList,
        onContinueHiring: () {
          if (!mounted) return;
          unawaited(_openRecruitMenu());
        },
      );

      await result.responseFuture;
      if (!mounted) return;
      _refreshEmployeeList();
      unawaited(AgentService.instance.refresh());
    } finally {
      repository.dispose();
    }
  }

  /// 菜单选项 - 完全按照 ClientChooserButton 的方式
  List<PopupMenuEntry<Object>> _buildMenuItems(BuildContext context) {
    final theme = Theme.of(context);

    Widget buildMenuItem(IconData icon, String text, Color? iconColor) {
      return Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: (iconColor ?? theme.colorScheme.primary).withAlpha(20),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              size: 20,
              color: iconColor ?? theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 14),
          Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }

    return <PopupMenuEntry<Object>>[
      PopupMenuItem(
        value: _SettingsAction.newGroup,
        child: buildMenuItem(
          Icons.group_add_rounded,
          L10n.of(context).createGroup,
          theme.colorScheme.tertiary,
        ),
      ),
      PopupMenuItem(
        value: _SettingsAction.setStatus,
        child: buildMenuItem(
          Icons.edit_rounded,
          L10n.of(context).setStatus,
          theme.colorScheme.secondary,
        ),
      ),
      PopupMenuItem(
        value: _SettingsAction.invite,
        child: buildMenuItem(
          Icons.adaptive.share_rounded,
          L10n.of(context).inviteContact,
          theme.colorScheme.primary,
        ),
      ),
      PopupMenuItem(
        value: _SettingsAction.settings,
        child: buildMenuItem(
          Icons.settings_rounded,
          L10n.of(context).settings,
          theme.colorScheme.onSurfaceVariant,
        ),
      ),
    ];
  }

  /// 菜单选择处理 - 完全按照 ClientChooserButton 的方式
  void _onMenuSelected(Object object) async {
    if (object is _SettingsAction) {
      switch (object) {
        case _SettingsAction.newGroup:
          context.go('/rooms/newgroup');
          break;
        case _SettingsAction.invite:
          FluffyShare.shareInviteLink(context);
          break;
        case _SettingsAction.settings:
          context.go('/rooms/settings');
          break;
        case _SettingsAction.setStatus:
          _handleSetStatus();
          break;
      }
    }
  }

  /// 处理设置状态
  Future<void> _handleSetStatus() async {
    final matrix = Matrix.of(context);
    final client = matrix.clientOrNull;
    if (client == null) return;
    final currentPresence = await client.fetchCurrentPresence(client.userID!);
    final input = await showTextInputDialog(
      useRootNavigator: false,
      context: context,
      title: L10n.of(context).setStatus,
      message: L10n.of(context).leaveEmptyToClearStatus,
      okLabel: L10n.of(context).ok,
      cancelLabel: L10n.of(context).cancel,
      hintText: L10n.of(context).statusExampleMessage,
      maxLines: 6,
      minLines: 1,
      maxLength: 255,
      initialText: currentPresence.statusMsg,
    );
    if (input == null) return;
    if (!mounted) return;
    await showFutureLoadingDialog(
      context: context,
      future: () => client.setPresence(
        client.userID!,
        PresenceType.online,
        statusMsg: input,
      ),
    );
  }

  /// 构建自适应宽度的 header - 使用 FutureBuilder 和设置页面一样的模式
  Widget _buildAdaptiveHeader() {
    final theme = Theme.of(context);
    final matrix = Matrix.of(context);
    final client = matrix.clientOrNull;
    // 客户端未初始化时显示占位符
    if (client == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        ),
      );
    }

    final userId = client.userID ?? '';
    // 检查版本号是否变化（设置页面更新头像后会递增版本号）
    if (_lastProfileVersion != _profileVersion) {
      _profileFuture = null;
      _lastProfileVersion = _profileVersion;
    }
    // 初始化 profileFuture（和设置页面一样的逻辑）
    _profileFuture ??= client.getProfileFromUserId(userId);

    return FutureBuilder<Profile>(
      future: _profileFuture,
      builder: (context, snapshot) {
        var localpart = '用户';
        if (userId.startsWith('@') && userId.contains(':')) {
          localpart = userId.substring(1, userId.indexOf(':'));
        }
        final profile = snapshot.data;
        final displayName = profile?.displayName ?? localpart;
        final avatarUrl = profile?.avatarUrl;

        // 预构建头像组件，避免动画期间重复创建
        final avatar = RepaintBoundary(
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  theme.colorScheme.primary.withAlpha(80),
                  theme.colorScheme.tertiary.withAlpha(60),
                ],
              ),
            ),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.surface,
              ),
              child: Avatar(
                mxContent: avatarUrl,
                name: displayName,
                size: 36,
              ),
            ),
          ),
        );

        // 使用 LayoutBuilder 自适应宽度
        return LayoutBuilder(
          builder: (context, constraints) {
            final showName = constraints.maxWidth > 150;
            return Center(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: showName ? 16 : 0,
                  vertical: 4,
                ),
                child: Material(
                  clipBehavior: Clip.hardEdge,
                  borderRadius: BorderRadius.circular(99),
                  color: Colors.transparent,
                  child: PopupMenuButton<Object>(
                    popUpAnimationStyle: AnimationStyle.noAnimation,
                    onSelected: _onMenuSelected,
                    itemBuilder: _buildMenuItems,
                    child: showName
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              avatar,
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  displayName,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ),
                            ],
                          )
                        : avatar,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildContent() {
    final theme = Theme.of(context);

    switch (_currentPage) {
      case DesktopPageIndex.messages:
        // 消息页面：聊天列表 + 聊天详情（双栏布局，可调整大小）
        return LayoutBuilder(
          builder: (context, constraints) {
            return MouseRegion(
              cursor: _isDraggingDivider
                  ? SystemMouseCursors.resizeColumn
                  : SystemMouseCursors.basic,
              child: Listener(
                onPointerMove: _isDraggingDivider
                    ? (event) {
                        // 计算新宽度：鼠标相对于内容区域左边的位置
                        final newWidth = event.localPosition.dx.clamp(
                          _minChatListWidth,
                          _maxChatListWidth,
                        );
                        if (newWidth != _chatListWidth) {
                          setState(() => _chatListWidth = newWidth);
                        }
                      }
                    : null,
                onPointerUp: _isDraggingDivider
                    ? (_) => setState(() => _isDraggingDivider = false)
                    : null,
                child: Row(
                  children: [
                    // 聊天列表（可调整宽度）
                    SizedBox(
                      width: _chatListWidth,
                      child: ChatList(
                        activeChat: widget.activeChat,
                        displayNavigationRail: false,
                      ),
                    ),
                    // 可拖拽分隔线
                    MouseRegion(
                      cursor: SystemMouseCursors.resizeColumn,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (_) {
                          setState(() => _isDraggingDivider = true);
                        },
                        child: Container(
                          width: 8,
                          color: Colors.transparent,
                          child: Center(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: _isDraggingDivider ? 4 : 1,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: _isDraggingDivider
                                      ? [
                                          theme.colorScheme.primary
                                              .withAlpha(100),
                                          theme.colorScheme.primary,
                                          theme.colorScheme.primary
                                              .withAlpha(100),
                                        ]
                                      : [
                                          theme.dividerColor.withAlpha(60),
                                          theme.dividerColor,
                                          theme.dividerColor.withAlpha(60),
                                        ],
                                ),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 聊天详情
                    Expanded(
                      child: widget.activeChat != null
                          ? ChatPage(roomId: widget.activeChat!)
                          : const EmptyPage(),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      case DesktopPageIndex.employees:
        // 员工页面：只保留列表主体
        return EmployeesTab(
          key: _employeesTabKey,
          onNavigateToRecruit: () => unawaited(_openRecruitMenu()),
        );
    }
  }

  Future<void> _openWalletDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: const SizedBox(
            width: 420,
            height: 680,
            child: WalletPage(showBackButton: false),
          ),
        ),
      ),
    );
  }

  Widget _buildTopNavigation(ThemeData theme, L10n l10n) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showProfileText = constraints.maxWidth > 1160;

        return WindowDragArea(
          child: Container(
            height: 82,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
              ),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.shadow.withValues(alpha: 0.08),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 13,
                  ),
                  child: Row(
                    children: [
                      const _PsygoBubbleLogo(
                        size: 34,
                      ),
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 1),
                        child: Text(
                          'Psygo',
                          maxLines: 1,
                          strutStyle: const StrutStyle(
                            height: 1.2,
                            forceStrutHeight: true,
                          ),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                            height: 1.2,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLow
                            .withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _TopNavigationButton(
                            icon: Icons.chat_bubble_outline_rounded,
                            selectedIcon: Icons.chat_bubble_rounded,
                            label: l10n.messages,
                            selected: _currentPage == DesktopPageIndex.messages,
                            badgeCount: _unreadCount,
                            onTap: () => _onPageSelected(
                              DesktopPageIndex.messages.value,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _TopNavigationButton(
                            icon: Icons.groups_outlined,
                            selectedIcon: Icons.groups_rounded,
                            label: l10n.teamPageTitle,
                            selected:
                                _currentPage == DesktopPageIndex.employees,
                            onTap: () => _onPageSelected(
                              DesktopPageIndex.employees.value,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.walletTitle,
                  onPressed: _openWalletDialog,
                  icon: const Icon(Icons.account_balance_wallet_rounded),
                  style: IconButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: showProfileText ? 224 : 56,
                  child: _buildAdaptiveHeader(),
                ),
                if (PlatformInfos.isDesktop) ...[
                  const SizedBox(width: 8),
                  Container(
                    width: 1,
                    height: 28,
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.4,
                    ),
                  ),
                  const SizedBox(width: 6),
                  WindowControlButtons(
                    iconColor: theme.colorScheme.onSurfaceVariant,
                    hoverColor: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.9),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.secondaryContainer.withValues(alpha: 0.38),
              theme.colorScheme.primaryContainer.withValues(alpha: 0.24),
              theme.colorScheme.surface,
            ],
            stops: const [0.0, 0.45, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 5),
                child: _buildTopNavigation(theme, l10n),
              ),
              Expanded(
                child: _buildContent(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PsygoBubbleLogo extends StatelessWidget {
  final double size;

  const _PsygoBubbleLogo({
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Image.asset(
      isDark ? 'assets/logo_dark.png' : 'assets/logo_transparent.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
    );
  }
}

class _TopNavigationButton extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final int badgeCount;
  final VoidCallback onTap;

  const _TopNavigationButton({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.14)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              children: [
                Icon(
                  selected ? selectedIcon : icon,
                  size: 18,
                  color: foreground,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? foreground : theme.colorScheme.onSurface,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
                if (badgeCount > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      badgeCount > 99 ? '99+' : '$badgeCount',
                      style: TextStyle(
                        color: theme.colorScheme.onError,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 设置菜单选项
enum _SettingsAction {
  newGroup,
  setStatus,
  invite,
  settings,
}
