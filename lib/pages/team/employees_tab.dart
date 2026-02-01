import 'dart:async';

import 'package:flutter/material.dart';

import 'package:psygo/config/themes.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/widgets/matrix.dart';
import 'package:go_router/go_router.dart';

import '../../models/agent.dart';
import '../../repositories/agent_repository.dart';
import '../../utils/retry_helper.dart';
import '../../widgets/employee_card.dart';
import '../../widgets/employee_detail_sheet.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/skeleton_card.dart';
import '../../widgets/trial_countdown_banner.dart';

/// 员工列表 Tab
/// 显示当前用户的所有 Agent（员工）
class EmployeesTab extends StatefulWidget {
  /// Callback to switch to recruit tab when employee list is empty
  final VoidCallback? onNavigateToRecruit;

  const EmployeesTab({super.key, this.onNavigateToRecruit});

  @override
  State<EmployeesTab> createState() => EmployeesTabState();
}

class EmployeesTabState extends State<EmployeesTab>
    with AutomaticKeepAliveClientMixin {
  final AgentRepository _repository = AgentRepository();
  final ScrollController _scrollController = ScrollController();

  List<Agent> _employees = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String? _error;
  int? _nextCursor;
  bool _hasMore = true;
  String? _trialExpiresAt;
  final Set<String> _deletingEmployees = <String>{};

  // 轮询定时器：用于检测员工 isReady 状态变化
  Timer? _readyPollingTimer;
  static const Duration _pollingInterval = Duration(seconds: 15);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadEmployees();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _stopReadyPolling();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _repository.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadEmployees() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final page = await RetryHelper.withRetry(
        operation: () => _repository.getUserAgents(),
        maxRetries: 2,
        retryDelayMs: 3000,
        onRetry: (attempt, error) {
          // 可选：显示重试提示
          debugPrint('Retrying employee list load, attempt $attempt');
        },
      );
      if (mounted) {
        setState(() {
          _employees = page.agents;
          _nextCursor = page.nextCursor;
          _hasMore = page.hasNextPage;
          _trialExpiresAt = page.trialExpiresAt;
          _isLoading = false;
        });
        // 检查是否需要启动/停止轮询
        _checkAndUpdatePolling();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  /// 检查是否有员工处于 isReady=false 状态，决定是否启动轮询
  void _checkAndUpdatePolling() {
    final hasUnreadyEmployees = _employees.any((e) => !e.isReady);

    if (hasUnreadyEmployees) {
      _startReadyPolling();
    } else {
      _stopReadyPolling();
    }
  }

  /// 启动轮询定时器（如果尚未启动）
  void _startReadyPolling() {
    if (_readyPollingTimer != null && _readyPollingTimer!.isActive) {
      return; // 已在轮询中
    }

    _readyPollingTimer = Timer.periodic(_pollingInterval, (_) {
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
    try {
      final page = await _repository.getUserAgents();
      if (mounted) {
        // 只更新已存在员工的 isReady 状态，保留分页数据
        final updatedMap = {for (final e in page.agents) e.agentId: e};
        setState(() {
          _employees = _employees.map((e) {
            final updated = updatedMap[e.agentId];
            // 如果在最新数据中找到了这个员工，用新数据替换（主要是更新 isReady）
            return updated ?? e;
          }).toList();
        });
        // 刷新后检查是否需要继续轮询
        _checkAndUpdatePolling();
      }
    } catch (e) {
      // 静默刷新失败不影响 UI
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore || _nextCursor == null) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      final page = await _repository.getUserAgents(cursor: _nextCursor);
      if (mounted) {
        setState(() {
          _employees.addAll(page.agents);
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

  /// 打开员工详情 Sheet（移动端）或对话框（PC端）
  void _onEmployeeTap(Agent employee) {
    if (_deletingEmployees.contains(employee.agentId)) {
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
              isDeleting: _deletingEmployees.contains(employee.agentId),
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
        backgroundColor: Colors.transparent,
        builder: (context) => EmployeeDetailSheet(
          employee: employee,
          onDelete: () => _deleteEmployee(employee),
          isDeleting: _deletingEmployees.contains(employee.agentId),
        ),
      );
    }
  }

  /// 长按显示快捷菜单
  void _onEmployeeLongPress(Agent employee, Offset tapPosition) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final isDeleting = _deletingEmployees.contains(employee.agentId);
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
        // 优化（删除）
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
            content: Text('${l10n.errorStartingChat}: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// 确认优化对话框
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

  /// 优化员工
  Future<void> _deleteEmployee(Agent employee) async {
    if (_deletingEmployees.contains(employee.agentId)) {
      return;
    }
    setState(() {
      _deletingEmployees.add(employee.agentId);
    });

    try {
      await _repository.deleteAgent(employee.agentId);
      if (mounted) {
        setState(() {
          _employees.removeWhere((e) => e.agentId == employee.agentId);
          _deletingEmployees.remove(employee.agentId);
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
      if (mounted) {
        setState(() {
          _deletingEmployees.remove(employee.agentId);
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${L10n.of(context).errorDeletingEmployee}: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
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

    // 错误状态 - 包裹在可滚动组件中以支持下拉刷新
    if (_error != null && _employees.isEmpty) {
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
    if (_employees.isEmpty) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: EmptyState(
            icon: Icons.people_outline,
            title: l10n.noEmployeesYet,
            subtitle: l10n.noEmployeesHint,
            actionLabel: l10n.hireFirstEmployee,
            onAction: () {
              // 切换到招聘 Tab
              widget.onNavigateToRecruit?.call();
            },
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
          int crossAxisCount = (availableWidth / minCardWidth).floor();
          crossAxisCount = crossAxisCount.clamp(2, 5);

          // 计算实际卡片宽度
          final cardWidth = availableWidth / crossAxisCount - 12; // 减去间距

          // 根据卡片宽度调整宽高比（数值越小，卡片越高）
          final aspectRatio = cardWidth > 350 ? 3.2 : (cardWidth > 300 ? 2.8 : 2.5);

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
              // 员工网格
              SliverPadding(
                padding: const EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 8,
                  bottom: 32,
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
                      if (index == _employees.length) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      final employee = _employees[index];
                      final isDeleting =
                          _deletingEmployees.contains(employee.agentId);
                      return GestureDetector(
                        // PC端使用右键触发快捷菜单
                        onSecondaryTapDown: (details) {
                          if (!isDeleting) {
                            _onEmployeeLongPress(
                              employee,
                              details.globalPosition,
                            );
                          }
                        },
                        child: EmployeeCard(
                          employee: employee,
                          isOffboarding: isDeleting,
                          onTap: isDeleting ? null : () => _onEmployeeTap(employee),
                        ),
                      );
                    },
                    childCount: _employees.length + (_isLoadingMore ? 1 : 0),
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
                if (index == _employees.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                final employee = _employees[index];
                final isDeleting =
                    _deletingEmployees.contains(employee.agentId);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: GestureDetector(
                    onLongPressStart: (details) {
                      if (!isDeleting) {
                        _onEmployeeLongPress(employee, details.globalPosition);
                      }
                    },
                    child: EmployeeCard(
                      employee: employee,
                      isOffboarding: isDeleting,
                      onTap: isDeleting ? null : () => _onEmployeeTap(employee),
                    ),
                  ),
                );
              },
              childCount: _employees.length + (_isLoadingMore ? 1 : 0),
            ),
          ),
        ),
      ],
    );
  }

}
