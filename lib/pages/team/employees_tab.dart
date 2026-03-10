import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:psygo/config/themes.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/utils/platform_infos.dart';
import 'package:psygo/widgets/matrix.dart';

import '../../models/agent.dart';
import '../../repositories/agent_repository.dart';
import '../../utils/localized_exception_extension.dart';
import '../../utils/retry_helper.dart';
import '../../widgets/employee_card.dart';
import '../../widgets/employee_detail_sheet.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/recruit_entry_guide_highlight.dart';
import '../../widgets/skeleton_card.dart';
import '../../widgets/trial_countdown_banner.dart';

/// 员工列表 Tab
/// 显示当前用户的所有 Agent（员工）
class EmployeesTab extends StatefulWidget {
  /// Callback to open the recruit flow from the employee list.
  final VoidCallback? onNavigateToRecruit;
  final bool showRecruitGuideHighlight;

  const EmployeesTab({
    super.key,
    this.onNavigateToRecruit,
    this.showRecruitGuideHighlight = false,
  });

  @override
  State<EmployeesTab> createState() => EmployeesTabState();
}

class EmployeesTabState extends State<EmployeesTab>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  // Persist offboarding state across tab/page rebuilds so the card style does
  // not revert when user navigates away and back during deletion.
  static final ValueNotifier<Set<String>> _offboardingEmployeeIdsNotifier =
      ValueNotifier<Set<String>>(<String>{});

  final AgentRepository _repository = AgentRepository();
  final ScrollController _scrollController = ScrollController();
  final Map<String, Agent> _pendingEmployeesById = <String, Agent>{};

  List<Agent> _employees = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String? _error;
  int? _nextCursor;
  bool _hasMore = true;
  String? _trialExpiresAt;
  int _replaceRequestSeq = 0;

  // 轮询定时器：用于检测员工 isReady 状态变化
  Timer? _readyPollingTimer;
  static const Duration _onboardingPollingInterval = Duration(seconds: 2);

  // 移动端刷新：进入页面/回到前台时主动刷新，并开启固定轮询
  Timer? _mobilePollingTimer;
  static const Duration _mobilePollingIntervalNormal = Duration(seconds: 15);
  static const Duration _mobilePollingIntervalOnboarding = Duration(seconds: 2);
  Duration _currentMobilePollingInterval = _mobilePollingIntervalNormal;
  bool _isTabVisible = false;
  bool _isAppInForeground = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _offboardingEmployeeIdsNotifier.addListener(_handleOffboardingStateChanged);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _isAppInForeground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _loadEmployees();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _offboardingEmployeeIdsNotifier
        .removeListener(_handleOffboardingStateChanged);
    _stopMobilePolling();
    _stopReadyPolling();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _repository.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isMobileRealtimeEnabled) return;

    final isForeground = state == AppLifecycleState.resumed;
    if (_isAppInForeground == isForeground) return;
    _isAppInForeground = isForeground;

    if (!_isAppInForeground) {
      _stopMobilePolling();
      return;
    }

    if (_isTabVisible) {
      unawaited(_refreshOnEnter());
      _startMobilePolling();
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  void _handleOffboardingStateChanged() {
    if (!mounted) return;
    setState(() {});
  }

  bool _isOffboarding(String agentId) {
    return _offboardingEmployeeIdsNotifier.value.contains(agentId);
  }

  void _setOffboardingState(String agentId, bool isOffboarding) {
    final next = Set<String>.from(_offboardingEmployeeIdsNotifier.value);
    final changed = isOffboarding ? next.add(agentId) : next.remove(agentId);
    if (!changed) return;
    _offboardingEmployeeIdsNotifier.value = next;
  }

  bool _isPendingPlaceholder(String agentId, Set<String> loadedEmployeeIds) {
    return _pendingEmployeesById.containsKey(agentId) &&
        !loadedEmployeeIds.contains(agentId);
  }

  List<Agent> _mergePendingAvatarIntoLoaded(List<Agent> loadedEmployees) {
    if (_pendingEmployeesById.isEmpty) return loadedEmployees;
    return loadedEmployees.map((employee) {
      final pending = _pendingEmployeesById[employee.agentId];
      if (pending == null) return employee;
      final hasLoadedAvatar = employee.avatarUrl?.trim().isNotEmpty == true;
      final pendingAvatar = pending.avatarUrl?.trim();
      if (hasLoadedAvatar || pendingAvatar == null || pendingAvatar.isEmpty) {
        return employee;
      }
      return employee.copyWith(avatarUrl: pending.avatarUrl);
    }).toList();
  }

  List<Agent> _buildDisplayedEmployees() {
    final mergedLoadedEmployees = _mergePendingAvatarIntoLoaded(_employees);
    if (_pendingEmployeesById.isEmpty) return mergedLoadedEmployees;
    final loadedIds = mergedLoadedEmployees.map((e) => e.agentId).toSet();
    final merged = <Agent>[
      ..._pendingEmployeesById.values.where(
        (pending) => !loadedIds.contains(pending.agentId),
      ),
      ...mergedLoadedEmployees,
    ];
    return merged;
  }

  void _reconcilePendingEmployees(Iterable<Agent> loadedEmployees) {
    if (_pendingEmployeesById.isEmpty) return;
    final loadedMap = {
      for (final employee in loadedEmployees) employee.agentId: employee,
    };
    _pendingEmployeesById.removeWhere((agentId, pending) {
      final loaded = loadedMap[agentId];
      if (loaded == null) return false;
      final hasLoadedAvatar = loaded.avatarUrl?.trim().isNotEmpty == true;
      final hasPendingAvatar = pending.avatarUrl?.trim().isNotEmpty == true;
      // Avatar already available from server, or pending card has no local avatar
      // to keep as fallback: pending placeholder can be dropped.
      return hasLoadedAvatar || !hasPendingAvatar;
    });
  }

  String _pendingNameFromDisplayName(String displayName) {
    final normalized = displayName.trim().toLowerCase();
    final slug = normalized
        .replaceAll(RegExp(r'[^a-z0-9-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return slug.isEmpty ? 'pending-agent' : slug;
  }

  Agent _buildPendingEmployee({
    required String agentId,
    required String displayName,
    String? avatarUrl,
  }) {
    final normalizedDisplayName =
        displayName.trim().isNotEmpty ? displayName.trim() : 'Employee';
    final normalizedAvatar = avatarUrl?.trim();
    return Agent(
      agentId: agentId,
      displayName: normalizedDisplayName,
      name: _pendingNameFromDisplayName(normalizedDisplayName),
      avatarUrl: normalizedAvatar?.isNotEmpty == true ? normalizedAvatar : null,
      isActive: true,
      isReady: false,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<void> _loadEmployees() async {
    final requestSeq = ++_replaceRequestSeq;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final page = await RetryHelper.withRetry(
        operation: () => _repository.getUserAgents(forceRefresh: true),
        maxRetries: 2,
        retryDelayMs: 3000,
        onRetry: (attempt, error) {
          // 可选：显示重试提示
          debugPrint('Retrying employee list load, attempt $attempt');
        },
      );
      if (!mounted || requestSeq != _replaceRequestSeq) return;
      final mergedAgents = _mergePendingAvatarIntoLoaded(page.agents);

      setState(() {
        _reconcilePendingEmployees(mergedAgents);
        _employees = mergedAgents;
        _nextCursor = page.nextCursor;
        _hasMore = page.hasNextPage;
        _trialExpiresAt = page.trialExpiresAt;
        _isLoading = false;
      });
      // 检查是否需要启动/停止轮询
      _checkAndUpdatePolling();
    } catch (e) {
      if (!mounted || requestSeq != _replaceRequestSeq) return;

      setState(() {
        _error = e.toLocalizedString(
          context,
          ExceptionContext.loadEmployeeList,
        );
        _isLoading = false;
      });
    }
  }

  /// 检查是否有员工处于 isReady=false 状态，决定是否启动轮询
  void _checkAndUpdatePolling() {
    final hasOnboardingEmployees = _hasOnboardingEmployeesForPolling();

    // 移动端使用固定轮询，不启用 isReady 轮询
    if (_isMobileRealtimeEnabled) {
      if (_isTabVisible && _isAppInForeground) {
        _startMobilePolling();
      } else {
        _stopMobilePolling();
      }
      _stopReadyPolling();
      return;
    }

    if (hasOnboardingEmployees) {
      _startReadyPolling();
    } else {
      _stopReadyPolling();
    }
  }

  bool _hasOnboardingEmployeesForPolling() {
    if (_employees.any((e) => !e.isReady)) {
      return true;
    }
    if (_pendingEmployeesById.isEmpty) {
      return false;
    }
    final loadedIds = _employees.map((e) => e.agentId).toSet();
    return _pendingEmployeesById.keys.any((id) => !loadedIds.contains(id));
  }

  /// 启动轮询定时器（如果尚未启动）
  void _startReadyPolling() {
    if (_readyPollingTimer != null && _readyPollingTimer!.isActive) {
      return; // 已在轮询中
    }

    _readyPollingTimer = Timer.periodic(_onboardingPollingInterval, (_) {
      if (mounted) {
        _refreshSilently();
      }
    });
  }

  /// 停止轮询定时器
  void _stopReadyPolling() {
    _readyPollingTimer?.cancel();
    _readyPollingTimer = null;
  }

  /// 静默刷新（不显示加载状态，用于轮询）
  /// 只更新现有员工的状态，不覆盖分页数据
  Future<void> _refreshSilently() async {
    final requestSeq = ++_replaceRequestSeq;
    try {
      final page = await _repository.getUserAgents(forceRefresh: true);
      if (!mounted || requestSeq != _replaceRequestSeq) return;
      final mergedAgents = _mergePendingAvatarIntoLoaded(page.agents);

      // 只更新已存在员工的 isReady 状态，保留分页数据
      final pendingIdsBeforeRefresh = _pendingEmployeesById.keys.toSet();
      final updatedMap = {for (final e in mergedAgents) e.agentId: e};
      setState(() {
        _reconcilePendingEmployees(mergedAgents);
        _employees = _employees.map((e) {
          final updated = updatedMap[e.agentId];
          // 如果在最新数据中找到了这个员工，用新数据替换（主要是更新 isReady）
          return updated ?? e;
        }).toList();
        if (pendingIdsBeforeRefresh.isNotEmpty) {
          final existingIds = _employees.map((e) => e.agentId).toSet();
          for (final pendingId in pendingIdsBeforeRefresh) {
            final loaded = updatedMap[pendingId];
            if (loaded != null && !existingIds.contains(pendingId)) {
              _employees.insert(0, loaded);
              existingIds.add(pendingId);
            }
          }
        }
      });
      // 刷新后检查是否需要继续轮询
      _checkAndUpdatePolling();
    } catch (e) {
      // 静默刷新失败不影响 UI
    }
  }

  bool get _isMobileRealtimeEnabled => PlatformInfos.isMobile;

  /// TeamPage 在 Tab 切换时调用：用于触发进入页面时刷新
  void onTabVisibilityChanged(bool visible) {
    if (_isTabVisible == visible) return;
    _isTabVisible = visible;

    if (!_isMobileRealtimeEnabled) return;

    if (_isTabVisible && _isAppInForeground) {
      unawaited(_refreshOnEnter());
      _startMobilePolling();
    } else {
      _stopMobilePolling();
    }
  }

  void _startMobilePolling() {
    if (!_isMobileRealtimeEnabled || !_isTabVisible || !_isAppInForeground) {
      return;
    }
    final targetInterval = _hasOnboardingEmployeesForPolling()
        ? _mobilePollingIntervalOnboarding
        : _mobilePollingIntervalNormal;
    if (_mobilePollingTimer != null && _mobilePollingTimer!.isActive) {
      if (_currentMobilePollingInterval == targetInterval) {
        return;
      }
      _mobilePollingTimer?.cancel();
      _mobilePollingTimer = null;
    }
    _currentMobilePollingInterval = targetInterval;
    _mobilePollingTimer = Timer.periodic(targetInterval, (_) {
      if (!mounted || !_isTabVisible || !_isAppInForeground) return;
      unawaited(_refreshOnEnter());
    });
  }

  void _stopMobilePolling() {
    _mobilePollingTimer?.cancel();
    _mobilePollingTimer = null;
    _currentMobilePollingInterval = _mobilePollingIntervalNormal;
  }

  /// 进入员工页时的主动刷新（不展示 loading 骨架）
  Future<void> _refreshOnEnter() async {
    if (_isLoading || _isLoadingMore) return;
    final requestSeq = ++_replaceRequestSeq;

    try {
      final page = await _repository.getUserAgents(forceRefresh: true);
      if (!mounted || requestSeq != _replaceRequestSeq) return;
      final mergedAgents = _mergePendingAvatarIntoLoaded(page.agents);

      setState(() {
        _reconcilePendingEmployees(mergedAgents);
        _employees = mergedAgents;
        _nextCursor = page.nextCursor;
        _hasMore = page.hasNextPage;
        _trialExpiresAt = page.trialExpiresAt;
        _error = null;
      });
      _checkAndUpdatePolling();
    } catch (_) {
      // 进入时静默刷新失败不打断页面使用
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore || _nextCursor == null) return;
    final replaceSeqAtStart = _replaceRequestSeq;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      final page = await _repository.getUserAgents(
        cursor: _nextCursor,
        forceRefresh: true,
      );
      final mergedAgents = _mergePendingAvatarIntoLoaded(page.agents);
      if (mounted) {
        if (replaceSeqAtStart != _replaceRequestSeq) {
          setState(() {
            _isLoadingMore = false;
          });
          return;
        }

        setState(() {
          _reconcilePendingEmployees(mergedAgents);
          _employees.addAll(mergedAgents);
          _nextCursor = page.nextCursor;
          _hasMore = page.hasNextPage;
          _isLoadingMore = false;
        });
        // 新加载的员工可能也有 isReady=false，检查是否需要启动轮询
        _checkAndUpdatePolling();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
        });
      }
    }
  }

  Future<void> _refresh() async {
    _nextCursor = null;
    _hasMore = true;
    await _loadEmployees();
  }

  /// Public method to refresh the employee list
  /// Called from parent when a new employee is hired
  Future<void> refreshEmployeeList() => _refresh();

  /// Public method to refresh employee list without loading skeleton.
  Future<void> refreshEmployeeListSilently() => _refreshOnEnter();

  /// Add an optimistic onboarding card right after hire request is submitted.
  void addPendingEmployee({
    required String displayName,
    required String agentId,
    String? avatarUrl,
  }) {
    if (!mounted) return;
    final normalizedId = agentId.trim();
    if (normalizedId.isEmpty) return;
    setState(() {
      _pendingEmployeesById[normalizedId] = _buildPendingEmployee(
        agentId: normalizedId,
        displayName: displayName,
        avatarUrl: avatarUrl,
      );
    });
    _checkAndUpdatePolling();
  }

  void removePendingEmployee(String agentId) {
    if (!mounted) return;
    final normalizedId = agentId.trim();
    if (normalizedId.isEmpty) return;
    final removed = _pendingEmployeesById.remove(normalizedId);
    if (removed == null) return;
    setState(() {});
    _checkAndUpdatePolling();
  }

  /// 打开员工详情 Sheet（移动端）或对话框（PC端）
  void _onEmployeeTap(Agent employee) {
    if (_isOffboarding(employee.agentId)) {
      final l10n = L10n.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.loadingPleaseWait),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final isDesktop = FluffyThemes.isColumnMode(context);

    if (isDesktop) {
      // PC端使用居中对话框，保持固定宽度480
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: EmployeeDetailSheet(
              employee: employee,
              onDelete: () => _deleteEmployee(employee),
              isDeleting: _isOffboarding(employee.agentId),
              isDialog: true,
            ),
          ),
        ),
      );
    } else {
      // 移动端使用底部弹窗
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        isDismissible: true,
        enableDrag: true,
        showDragHandle: false,
        backgroundColor: Colors.transparent,
        builder: (context) => EmployeeDetailSheet(
          employee: employee,
          onDelete: () => _deleteEmployee(employee),
          isDeleting: _isOffboarding(employee.agentId),
        ),
      );
    }
  }

  /// 长按显示快捷菜单
  void _onEmployeeLongPress(Agent employee, Offset tapPosition) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final isDeleting = _isOffboarding(employee.agentId);
    final chatEnabled = employee.isReady && !isDeleting;
    final detailsEnabled = !isDeleting;
    final deleteEnabled = !isDeleting;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        tapPosition.dx,
        tapPosition.dy,
        tapPosition.dx + 1,
        tapPosition.dy + 1,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      items: [
        // 开始聊天
        PopupMenuItem<String>(
          value: 'chat',
          enabled: chatEnabled,
          child: Row(
            children: [
              Icon(
                Icons.chat_outlined,
                size: 20,
                color: chatEnabled
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
              const SizedBox(width: 12),
              Text(
                l10n.startChat,
                style: TextStyle(
                  color: chatEnabled ? null : theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
        // 查看详情
        PopupMenuItem<String>(
          value: 'details',
          enabled: detailsEnabled,
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 20,
                color: detailsEnabled
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.outline,
              ),
              const SizedBox(width: 12),
              Text(
                l10n.viewDetails,
                style: TextStyle(
                  color: detailsEnabled ? null : theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        // 辞退（删除）
        PopupMenuItem<String>(
          value: 'delete',
          enabled: deleteEnabled,
          child: Row(
            children: [
              Icon(
                Icons.delete_outline,
                size: 20,
                color: deleteEnabled
                    ? theme.colorScheme.error
                    : theme.colorScheme.outline,
              ),
              const SizedBox(width: 12),
              Text(
                l10n.deleteEmployee,
                style: TextStyle(
                  color: deleteEnabled
                      ? theme.colorScheme.error
                      : theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;

      switch (value) {
        case 'chat':
          _startChatWithEmployee(employee);
          break;
        case 'details':
          _onEmployeeTap(employee);
          break;
        case 'delete':
          _confirmDeleteEmployee(employee);
          break;
      }
    });
  }

  /// 快速开始聊天
  Future<void> _startChatWithEmployee(Agent employee) async {
    final l10n = L10n.of(context);

    if (!employee.isReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.employeeOnboarding),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final matrixUserId = employee.matrixUserId;
    if (matrixUserId == null || matrixUserId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.employeeNoMatrixId),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      final client = Matrix.of(context).client;
      final existingDmRoomId = client.getDirectChatFromUserId(matrixUserId);

      if (existingDmRoomId != null) {
        if (mounted) {
          context.go('/rooms/$existingDmRoomId');
        }
        return;
      }

      // 创建新 DM
      final roomId = await client.startDirectChat(
        matrixUserId,
        enableEncryption: false,
      );

      if (mounted) {
        context.go('/rooms/$roomId');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorStartingChat),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// 确认辞退对话框
  Future<void> _confirmDeleteEmployee(Agent employee) async {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withAlpha(60),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.delete_outline_rounded,
                color: theme.colorScheme.error,
                size: 24,
              ),
            ),
            const SizedBox(width: 14),
            Text(
              l10n.deleteEmployee,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
          ],
        ),
        content: Text(
          l10n.deleteEmployeeConfirm(employee.displayName),
          style: TextStyle(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              l10n.cancel,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              l10n.confirm,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      _deleteEmployee(employee);
    }
  }

  /// 辞退员工
  Future<void> _deleteEmployee(Agent employee) async {
    if (_isOffboarding(employee.agentId)) {
      return;
    }
    _setOffboardingState(employee.agentId, true);
    final deleteRepository = AgentRepository();

    try {
      await deleteRepository.deleteAgent(employee.agentId);
      // Keep offboarding visual state after API success.
      // Some refresh paths may still show the employee briefly due to eventual
      // consistency; we must keep the card in offboarding style until it
      // disappears from the list.
      if (mounted) {
        setState(() {
          _employees.removeWhere((e) => e.agentId == employee.agentId);
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L10n.of(context).employeeDeleted),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      // When page is switched during deletion, this widget may be disposed and
      // request lifecycle can still finish later. Keep offboarding style sticky
      // for non-mounted states to avoid flicker back to normal card style.
      if (mounted) {
        _setOffboardingState(employee.agentId, false);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L10n.of(context).errorDeletingEmployee),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      deleteRepository.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return RefreshIndicator(
      onRefresh: _refresh,
      color: theme.colorScheme.primary,
      child: _buildBody(context, theme, l10n),
    );
  }

  Widget _buildBody(BuildContext context, ThemeData theme, L10n l10n) {
    // 加载状态
    if (_isLoading) {
      return ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: 5,
        itemBuilder: (context, index) => const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: SkeletonCard(height: 80),
        ),
      );
    }

    final displayedEmployees = _buildDisplayedEmployees();
    final loadedEmployeeIds = _employees.map((e) => e.agentId).toSet();

    // 错误状态 - 包裹在可滚动组件中以支持下拉刷新
    if (_error != null && displayedEmployees.isEmpty) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer.withAlpha(40),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.error_outline_rounded,
                    size: 48,
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  l10n.errorLoadingData,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _loadEmployees,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(
                    l10n.tryAgain,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 空状态 - 包裹在可滚动组件中以支持下拉刷新
    if (displayedEmployees.isEmpty) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: EmptyState(
            icon: Icons.people_outline,
            title: l10n.noEmployeesYet,
            subtitle: l10n.noEmployeesHint,
            actionLabel: widget.onNavigateToRecruit == null
                ? null
                : l10n.hireFirstEmployee,
            onAction: widget.onNavigateToRecruit,
          ),
        ),
      );
    }

    // 员工列表 - PC端使用响应式网格布局，移动端使用列表布局
    final isDesktop = FluffyThemes.isColumnMode(context);

    if (isDesktop) {
      // PC端：响应式网格布局，根据屏幕宽度自动调整列数
      return LayoutBuilder(
        builder: (context, constraints) {
          // 计算最佳列数：每列最小宽度 280，最大宽度 400
          const minCardWidth = 280.0;
          final availableWidth = constraints.maxWidth - 32; // 减去左右 padding

          // 计算列数（至少 2 列，最多 5 列）
          var crossAxisCount = (availableWidth / minCardWidth).floor();
          crossAxisCount = crossAxisCount.clamp(2, 5);

          // 计算实际卡片宽度
          final cardWidth = availableWidth / crossAxisCount - 12; // 减去间距

          // 根据卡片宽度调整宽高比（数值越小，卡片越高）
          final aspectRatio =
              cardWidth > 350 ? 3.2 : (cardWidth > 300 ? 2.8 : 2.5);

          final showFloatingRecruitButton = widget.onNavigateToRecruit != null;
          return Stack(
            children: [
              CustomScrollView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  // 试用期倒计时横幅
                  if (_trialExpiresAt != null)
                    SliverToBoxAdapter(
                      child: TrialCountdownBanner(
                        expiresAt: _trialExpiresAt!,
                        onExpired: _refresh,
                      ),
                    ),
                  // 员工网格
                  SliverPadding(
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: 8,
                      bottom: showFloatingRecruitButton ? 104 : 24,
                    ),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: aspectRatio,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          if (index == displayedEmployees.length) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }

                          final employee = displayedEmployees[index];
                          final isPendingPlaceholder = _isPendingPlaceholder(
                            employee.agentId,
                            loadedEmployeeIds,
                          );
                          final isDeleting = !isPendingPlaceholder &&
                              _isOffboarding(employee.agentId);
                          return GestureDetector(
                            // PC端使用右键触发快捷菜单
                            onSecondaryTapDown: (details) {
                              if (!isDeleting && !isPendingPlaceholder) {
                                _onEmployeeLongPress(
                                  employee,
                                  details.globalPosition,
                                );
                              }
                            },
                            child: EmployeeCard(
                              key: ValueKey(employee.agentId),
                              employee: employee,
                              isOffboarding: isDeleting,
                              onTap: (isDeleting || isPendingPlaceholder)
                                  ? null
                                  : () => _onEmployeeTap(employee),
                            ),
                          );
                        },
                        childCount: displayedEmployees.length +
                            (_isLoadingMore ? 1 : 0),
                      ),
                    ),
                  ),
                ],
              ),
              if (showFloatingRecruitButton)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 24,
                  child: IgnorePointer(
                    ignoring: false,
                    child: Center(
                      child: _buildRecruitButton(theme, l10n),
                    ),
                  ),
                ),
            ],
          );
        },
      );
    }

    // 移动端：列表布局
    return CustomScrollView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        // 试用期倒计时横幅
        if (_trialExpiresAt != null)
          SliverToBoxAdapter(
            child: TrialCountdownBanner(
              expiresAt: _trialExpiresAt!,
              onExpired: _refresh,
            ),
          ),
        // 员工列表
        SliverPadding(
          padding: const EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: 96,
          ),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                if (index == displayedEmployees.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                final employee = displayedEmployees[index];
                final isPendingPlaceholder = _isPendingPlaceholder(
                  employee.agentId,
                  loadedEmployeeIds,
                );
                final isDeleting =
                    !isPendingPlaceholder && _isOffboarding(employee.agentId);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: GestureDetector(
                    onLongPressStart: (details) {
                      if (!isDeleting && !isPendingPlaceholder) {
                        _onEmployeeLongPress(employee, details.globalPosition);
                      }
                    },
                    child: EmployeeCard(
                      key: ValueKey(employee.agentId),
                      employee: employee,
                      isOffboarding: isDeleting,
                      onTap: (isDeleting || isPendingPlaceholder)
                          ? null
                          : () => _onEmployeeTap(employee),
                    ),
                  ),
                );
              },
              childCount: displayedEmployees.length + (_isLoadingMore ? 1 : 0),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRecruitButton(ThemeData theme, L10n l10n) {
    final onNavigateToRecruit = widget.onNavigateToRecruit;
    if (onNavigateToRecruit == null) return const SizedBox.shrink();

    return RecruitEntryGuideHighlight(
      visible: widget.showRecruitGuideHighlight,
      title: l10n.customHire,
      description: l10n.customHireDescription,
      actionLabel: l10n.customHire,
      onAction: onNavigateToRecruit,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.primary,
              theme.colorScheme.tertiary,
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.primary.withValues(alpha: 0.3),
              blurRadius: 18,
              spreadRadius: 1,
              offset: const Offset(0, 6),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onNavigateToRecruit,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.add_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.customHire,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: Colors.white,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
