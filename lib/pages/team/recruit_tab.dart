import 'dart:async';

import 'package:flutter/material.dart';
import 'package:psygo/config/themes.dart';
import 'package:psygo/l10n/l10n.dart';
import '../../models/agent_template.dart';
import '../../models/hire_result.dart';
import '../../repositories/agent_repository.dart';
import '../../repositories/agent_template_repository.dart';
import '../../services/agent_service.dart';
import '../../utils/retry_helper.dart';
import '../../utils/localized_exception_extension.dart';
import '../../widgets/custom_hire_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/hire_success_dialog.dart';
import '../../widgets/skeleton_card.dart';
import '../../widgets/template_card.dart';
import '../../widgets/hire_dialog.dart';

/// 招聘中心 Tab
/// 展示可雇佣的 Agent 模板
class RecruitTab extends StatefulWidget {
  /// Callback when user clicks "view employee" in SnackBar
  /// Triggers switch to Employees tab and refresh
  final VoidCallback? onEmployeeHired;

  /// Callback to refresh employee list in background
  /// Called automatically after successful hire
  final VoidCallback? onRefreshEmployees;

  const RecruitTab({
    super.key,
    this.onEmployeeHired,
    this.onRefreshEmployees,
  });

  @override
  State<RecruitTab> createState() => RecruitTabState();
}

class RecruitTabState extends State<RecruitTab>
    with AutomaticKeepAliveClientMixin {
  final AgentTemplateRepository _repository = AgentTemplateRepository();
  final AgentRepository _agentRepository = AgentRepository();

  List<AgentTemplate> _templates = [];
  bool _isLoading = true;
  String? _error;
  int _employeeCount = 0; // 用于判断是否是第一位员工
  Timer? _postHirePollingTimer;
  int _postHirePollingAttempts = 0;
  static const int _maxPostHirePollingAttempts = 8;
  static const Duration _postHirePollingInterval = Duration(seconds: 5);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadTemplates();
    _loadEmployeeCount();
  }

  @override
  void dispose() {
    _stopPostHirePolling();
    _repository.dispose();
    _agentRepository.dispose();
    super.dispose();
  }

  Future<void> _loadEmployeeCount() async {
    try {
      final page = await _agentRepository.getUserAgents();
      if (mounted) {
        setState(() {
          _employeeCount = page.agents.length;
        });
      }
    } catch (_) {
      // 忽略错误，默认为0
    }
  }

  Future<void> _loadTemplates() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final templates = await RetryHelper.withRetry(
        operation: () => _repository.getActiveTemplates(),
        maxRetries: 2,
        retryDelayMs: 3000,
        onRetry: (attempt, error) {
          debugPrint('Retrying templates load, attempt $attempt');
        },
      );
      if (mounted) {
        setState(() {
          _templates = templates;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toLocalizedString(
            context,
            ExceptionContext.loadRecruitTemplates,
          );
          _isLoading = false;
        });
      }
    }
  }

  /// 公开的刷新方法，供外部调用
  Future<void> refresh() => _loadTemplates();

  Future<void> _onTemplateTap(AgentTemplate template) async {
    final result = await showDialog<HireResult>(
      context: context,
      builder: (context) => HireDialog(
        template: template,
        repository: _repository,
      ),
    );

    _handleHireResult(result);
  }

  Future<void> _onCustomHire() async {
    final isDesktop = FluffyThemes.isColumnMode(context);

    final result = isDesktop
        ? await showDialog<HireResult>(
            context: context,
            builder: (context) => Dialog(
              backgroundColor: Colors.transparent,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: CustomHireDialog(
                  repository: _repository,
                  isDialog: true,
                ),
              ),
            ),
          )
        : await showModalBottomSheet<HireResult>(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            isDismissible: true,
            enableDrag: true,
            builder: (context) => CustomHireDialog(
              repository: _repository,
            ),
          );

    _handleHireResult(result);
  }

  void _handleHireResult(HireResult? result) {
    if (result == null || !mounted) return;

    final isFirstEmployee = _employeeCount == 0;
    setState(() {
      _employeeCount++;
    });

    final displayName = result.displayName.trim();
    final employeeName = displayName.isNotEmpty ? displayName : 'Employee';

    _triggerPostHireRefresh();

    // 先显示成功反馈，入职动画会处理后续流程
    showHireSuccessDialog(
      context: context,
      employeeName: employeeName,
      isFirstEmployee: isFirstEmployee,
      onViewEmployee: () {
        widget.onEmployeeHired?.call();
      },
      onContinueHiring: () {
        // 留在当前页面，不做任何操作
      },
    );

    unawaited(_finalizeHire(result));
  }

  void _triggerPostHireRefresh() {
    widget.onRefreshEmployees?.call();
    unawaited(AgentService.instance.refresh());
    _startPostHirePolling();
  }

  void _startPostHirePolling() {
    _stopPostHirePolling();
    _postHirePollingAttempts = 0;
    _postHirePollingTimer = Timer.periodic(_postHirePollingInterval, (_) {
      if (!mounted) {
        _stopPostHirePolling();
        return;
      }
      _postHirePollingAttempts++;
      widget.onRefreshEmployees?.call();
      if (_postHirePollingAttempts >= _maxPostHirePollingAttempts) {
        _stopPostHirePolling();
      }
    });
  }

  void _stopPostHirePolling() {
    _postHirePollingTimer?.cancel();
    _postHirePollingTimer = null;
  }

  Future<void> _finalizeHire(HireResult result) async {
    try {
      await result.responseFuture;
      if (!mounted) return;
      _stopPostHirePolling();
      // 自动刷新员工列表（后台刷新，用户切回时能看到新员工）
      widget.onRefreshEmployees?.call();
      // 刷新 AgentService 缓存（聊天界面状态显示依赖此缓存）
      AgentService.instance.refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (_employeeCount > 0) {
          _employeeCount--;
        }
      });
      final message =
          e.toLocalizedString(context, ExceptionContext.hireEmployee);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: RefreshIndicator(
        onRefresh: _loadTemplates,
        color: theme.colorScheme.primary,
        child: _buildBody(context, theme, l10n),
      ),
      floatingActionButton: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.primary,
              theme.colorScheme.tertiary,
            ],
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.primary.withValues(alpha: 0.3),
              blurRadius: 20,
              spreadRadius: 2,
              offset: const Offset(0, 6),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _onCustomHire,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.add_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.customHire,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: Colors.white,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  Widget _buildBody(BuildContext context, ThemeData theme, L10n l10n) {
    final isDesktop = FluffyThemes.isColumnMode(context);

    // 加载状态
    if (_isLoading) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final crossAxisCount =
              _calculateCrossAxisCount(constraints.maxWidth, isDesktop);
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.75,
            ),
            itemCount: crossAxisCount * 2,
            itemBuilder: (context, index) =>
                const SkeletonGridItem(height: 220),
          );
        },
      );
    }

    // 错误状态 - 包裹在可滚动组件中以支持下拉刷新
    if (_error != null && _templates.isEmpty) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        theme.colorScheme.errorContainer.withAlpha(120),
                        theme.colorScheme.errorContainer.withAlpha(60),
                      ],
                    ),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.error.withAlpha(20),
                        blurRadius: 24,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Container(
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer.withAlpha(150),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.error_outline_rounded,
                        size: 36,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.errorLoadingData,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _loadTemplates,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
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
    if (_templates.isEmpty) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: EmptyState(
            icon: Icons.person_add_outlined,
            title: l10n.noTemplatesAvailable,
            subtitle: l10n.noTemplatesHint,
          ),
        ),
      );
    }

    // 模板列表 - 响应式网格布局
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount =
            _calculateCrossAxisCount(constraints.maxWidth, isDesktop);
        // 根据列数调整宽高比
        final aspectRatio =
            isDesktop ? (crossAxisCount >= 4 ? 0.68 : 0.72) : 0.72;

        return GridView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: 96, // 为底部导航栏留出空间
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: aspectRatio,
          ),
          itemCount: _templates.length,
          itemBuilder: (context, index) {
            final template = _templates[index];
            return TemplateCard(
              template: template,
              onTap: () => _onTemplateTap(template),
            );
          },
        );
      },
    );
  }

  /// 计算网格列数
  int _calculateCrossAxisCount(double width, bool isDesktop) {
    if (!isDesktop) return 2; // 移动端固定 2 列

    // PC端：根据宽度自适应列数
    const minCardWidth = 180.0;
    final availableWidth = width - 32; // 减去左右 padding
    int crossAxisCount = (availableWidth / minCardWidth).floor();
    return crossAxisCount.clamp(2, 6); // 2-6 列
  }
}
