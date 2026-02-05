import 'package:flutter/material.dart';

import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/widgets/matrix.dart';
import 'package:go_router/go_router.dart';

import '../models/agent.dart';
import '../models/agent_style.dart';
import '../models/plugin.dart';
import '../repositories/agent_repository.dart';
import '../repositories/plugin_repository.dart';
import 'custom_network_image.dart';

/// 员工详情 Sheet（支持底部弹窗和居中对话框两种模式）
/// 展示员工详细信息，提供开始聊天、管理技能等操作
class EmployeeDetailSheet extends StatefulWidget {
  final Agent employee;
  final VoidCallback? onDelete;
  final bool isDialog;
  final bool isDeleting;

  const EmployeeDetailSheet({
    super.key,
    required this.employee,
    this.onDelete,
    this.isDialog = false,
    this.isDeleting = false,
  });

  @override
  State<EmployeeDetailSheet> createState() => _EmployeeDetailSheetState();
}

class _EmployeeDetailSheetState extends State<EmployeeDetailSheet> {
  final PluginRepository _pluginRepository = PluginRepository();
  final AgentRepository _agentRepository = AgentRepository();

  List<AgentPlugin> _plugins = [];
  bool _isLoadingPlugins = true;
  bool _isStartingChat = false;

  // 风格相关
  AvailableStyles? _availableStyles;
  bool _isLoadingStyles = true;
  String? _selectedCommunicationStyle;
  String? _selectedReportStyle;
  bool _isUpdatingStyle = false;

  @override
  void initState() {
    super.initState();
    _loadPlugins();
    _loadStyles();
  }

  @override
  void dispose() {
    _pluginRepository.dispose();
    _agentRepository.dispose();
    super.dispose();
  }

  Future<void> _loadPlugins() async {
    if (!widget.employee.isReady) {
      setState(() => _isLoadingPlugins = false);
      return;
    }

    try {
      final plugins =
          await _pluginRepository.getAgentPlugins(widget.employee.agentId);
      if (mounted) {
        setState(() {
          _plugins = plugins.where((p) => p.isActive).toList();
          _isLoadingPlugins = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingPlugins = false);
      }
    }
  }

  Future<void> _loadStyles() async {
    try {
      final styles = await _agentRepository.getAvailableStyles();
      if (mounted) {
        setState(() {
          _availableStyles = styles;
          _isLoadingStyles = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingStyles = false);
      }
    }
  }

  Future<void> _updateStyle({
    String? communicationStyle,
    String? reportStyle,
  }) async {
    if (_isUpdatingStyle) return;

    setState(() => _isUpdatingStyle = true);

    try {
      await _agentRepository.updateAgentStyle(
        widget.employee.agentId,
        communicationStyle: communicationStyle,
        reportStyle: reportStyle,
      );

      if (mounted) {
        setState(() {
          if (communicationStyle != null) {
            _selectedCommunicationStyle = communicationStyle;
          }
          if (reportStyle != null) {
            _selectedReportStyle = reportStyle;
          }
          _isUpdatingStyle = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L10n.of(context).styleUpdated),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isUpdatingStyle = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L10n.of(context).updateFailed),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _startChat() async {
    final employee = widget.employee;
    final l10n = L10n.of(context);

    // 检查是否就绪
    if (!employee.isReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.employeeOnboarding),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // 检查 Matrix User ID
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

    // 验证格式
    if (!matrixUserId.startsWith('@') || !matrixUserId.contains(':')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.invalidMatrixUserId),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isStartingChat = true);

    try {
      final client = Matrix.of(context).client;

      // 阶段1：查找现有 DM
      final existingDmRoomId = client.getDirectChatFromUserId(matrixUserId);
      if (existingDmRoomId != null) {
        if (mounted) {
          Navigator.of(context).pop(); // 先关闭 sheet
          context.go('/rooms/$existingDmRoomId');
        }
        return;
      }

      // 阶段2：创建新 DM
      final roomId = await client.startDirectChat(
        matrixUserId,
        enableEncryption: false,
      );

      if (mounted) {
        Navigator.of(context).pop(); // 先关闭 sheet
        context.go('/rooms/$roomId');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isStartingChat = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_getReadableErrorMessage(e)),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  String _getReadableErrorMessage(dynamic e) {
    final errorString = e.toString().toLowerCase();
    final l10n = L10n.of(context);

    if (errorString.contains('socket') ||
        errorString.contains('connection') ||
        errorString.contains('network') ||
        errorString.contains('timeout')) {
      return l10n.networkError;
    }

    if (errorString.contains('not found') ||
        errorString.contains('m_not_found') ||
        errorString.contains('unknown user')) {
      return l10n.userNotFound;
    }

    if (errorString.contains('forbidden') ||
        errorString.contains('m_forbidden') ||
        errorString.contains('permission')) {
      return l10n.permissionDenied;
    }

    if (errorString.contains('500') ||
        errorString.contains('server') ||
        errorString.contains('internal')) {
      return l10n.serverError;
    }

    return '${l10n.errorStartingChat}: ${e.toString().split('\n').first}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final employee = widget.employee;

    final contentWidgets = [
      // 头像和基本信息
      Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            // 大头像
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    theme.colorScheme.primaryContainer,
                    theme.colorScheme.primaryContainer.withAlpha(180),
                  ],
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.primary.withAlpha(30),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: employee.avatarUrl != null &&
                      employee.avatarUrl!.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: CustomNetworkImage(
                        employee.avatarUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            _buildAvatarFallback(theme),
                      ),
                    )
                  : _buildAvatarFallback(theme),
            ),
            const SizedBox(height: 20),

            // 名称
            Text(
              employee.displayName,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 6),

            // Matrix ID
            if (employee.matrixUserId != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  employee.matrixUserId!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 12),

            // 状态徽章
            _buildStatusBadge(theme, l10n),

            // 合同到期时间
            if (employee.contractExpiresAt != null) ...[
              const SizedBox(height: 14),
              _buildContractInfo(theme, l10n),
            ],

            // 最后活跃时间
            if (employee.lastActiveAt != null) ...[
              const SizedBox(height: 10),
              _buildLastActiveInfo(theme, l10n),
            ],
          ],
        ),
      ),

      Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        height: 1,
        color: theme.colorScheme.outlineVariant.withAlpha(60),
      ),

      // 操作按钮
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Row(
          children: [
            // 开始聊天按钮
            Expanded(
              child: FilledButton.icon(
                onPressed:
                    employee.isReady && !_isStartingChat ? _startChat : null,
                icon: _isStartingChat
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.chat_rounded, size: 20),
                label: Text(
                  l10n.startChat,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),

      // 已掌握技能列表
      if (employee.isReady) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer.withAlpha(80),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.school_rounded,
                  size: 16,
                  color: theme.colorScheme.secondary,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                l10n.skills,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        _buildSkillsList(theme, l10n),
      ],

      // 沟通和汇报风格设置（临时隐藏）
      /*
      if (employee.isReady && _availableStyles != null) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withAlpha(80),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.tune_rounded,
                  size: 16,
                  color: theme.colorScheme.tertiary,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                l10n.workStyle,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        _buildStyleSelectors(theme, l10n),
      ],
      */

      // 优化按钮（删除）
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: widget.isDeleting ? null : () => _confirmDelete(context),
            icon: widget.isDeleting
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.error,
                    ),
                  )
                : Icon(
                    Icons.delete_outline_rounded,
                    color: theme.colorScheme.error,
                    size: 18,
                  ),
            label: Text(
              widget.isDeleting
                  ? '${l10n.deleteEmployee}...'
                  : l10n.deleteEmployee,
              style: TextStyle(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              side: BorderSide(
                color: theme.colorScheme.error.withAlpha(80),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      ),

      // 安全区域（仅底部弹窗模式）
      if (!widget.isDialog)
        SizedBox(height: MediaQuery.of(context).padding.bottom),
    ];

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: widget.isDialog
            ? BorderRadius.circular(24)
            : const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 拖动指示器（仅底部弹窗模式显示）
          if (!widget.isDialog)
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

          // 内容区域（都可滚动，对话框模式隐藏滚动条）
          Flexible(
            child: ScrollConfiguration(
              behavior: widget.isDialog
                  ? ScrollConfiguration.of(context).copyWith(scrollbars: false)
                  : ScrollConfiguration.of(context),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: contentWidgets,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarFallback(ThemeData theme) {
    return Center(
      child: Text(
        widget.employee.displayName.isNotEmpty
            ? widget.employee.displayName[0].toUpperCase()
            : '?',
        style: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildStatusBadge(ThemeData theme, L10n l10n) {
    final employee = widget.employee;

    if (widget.isDeleting) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${l10n.deleteEmployee}...',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    if (!employee.isReady) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.orange,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              l10n.employeeOnboarding,
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.orange,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    final status = employee.computedWorkStatus;
    final statusColor = _getWorkStatusColor(status);
    final statusText = _getWorkStatusText(l10n, status);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            statusText,
            style: theme.textTheme.labelMedium?.copyWith(
              color: statusColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _getWorkStatusText(L10n l10n, String status) {
    switch (status) {
      case 'working':
        return '💼 ${l10n.employeeWorking}';
      case 'slacking':
        return '🐟 ${l10n.employeeSlacking}';
      default:
        return '😴 ${l10n.employeeSleeping}';
    }
  }

  Color _getWorkStatusColor(String status) {
    switch (status) {
      case 'working':
        return Colors.green;
      case 'slacking':
        return Colors.blue;
      default:
        return Colors.blueGrey;
    }
  }

  Widget _buildSkillsList(ThemeData theme, L10n l10n) {
    if (_isLoadingPlugins) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_plugins.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.noSkillsYet,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _plugins.map<Widget>((plugin) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              plugin.pluginName,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildContractInfo(ThemeData theme, L10n l10n) {
    final contractExpires = widget.employee.contractExpiresAt;
    if (contractExpires == null) return const SizedBox.shrink();

    // 解析 ISO 8601 时间
    DateTime? expiryDate;
    try {
      expiryDate = DateTime.parse(contractExpires);
    } catch (_) {
      return const SizedBox.shrink();
    }

    final now = DateTime.now();
    final daysRemaining = expiryDate.difference(now).inDays;

    // 判断是否即将到期（少于30天）
    final isExpiringSoon = daysRemaining >= 0 && daysRemaining <= 30;
    final isExpired = daysRemaining < 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isExpired
            ? theme.colorScheme.errorContainer.withValues(alpha: 0.3)
            : isExpiringSoon
                ? Colors.orange.withValues(alpha: 0.15)
                : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isExpired ? Icons.error_outline : Icons.calendar_today_outlined,
            size: 16,
            color: isExpired
                ? theme.colorScheme.error
                : isExpiringSoon
                    ? Colors.orange
                    : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Text(
            isExpired
                ? l10n.contractExpired
                : isExpiringSoon
                    ? l10n.contractExpiringSoon(daysRemaining)
                    : l10n.contractExpiresOn(_formatDate(expiryDate)),
            style: theme.textTheme.labelMedium?.copyWith(
              color: isExpired
                  ? theme.colorScheme.error
                  : isExpiringSoon
                      ? Colors.orange
                      : theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLastActiveInfo(ThemeData theme, L10n l10n) {
    final lastActive = widget.employee.lastActiveAt;
    if (lastActive == null) return const SizedBox.shrink();

    DateTime? lastActiveDate;
    try {
      lastActiveDate = DateTime.parse(lastActive);
    } catch (_) {
      return const SizedBox.shrink();
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.access_time,
          size: 14,
          color: theme.colorScheme.outline,
        ),
        const SizedBox(width: 6),
        Text(
          l10n.lastActiveSummary(_formatRelativeTime(lastActiveDate)),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String _formatRelativeTime(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays > 0) {
      return '${difference.inDays} ${L10n.of(context).daysAgo}';
    } else if (difference.inHours > 0) {
      return '${difference.inHours} ${L10n.of(context).hoursAgo}';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes} ${L10n.of(context).minutesAgo}';
    } else {
      return L10n.of(context).justNow;
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final l10n = L10n.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteEmployee),
        content: Text(
          l10n.deleteEmployeeConfirm(widget.employee.displayName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      Navigator.of(context).pop(); // 关闭 sheet
      widget.onDelete?.call();
    }
  }

  Widget _buildStyleSelectors(ThemeData theme, L10n l10n) {
    if (_availableStyles == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 沟通风格
          Text(
            l10n.communicationStyle,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          ..._availableStyles!.communicationStyles.map((style) {
            final isSelected = _selectedCommunicationStyle == style.key;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                onTap: _isUpdatingStyle
                    ? null
                    : () => _updateStyle(communicationStyle: style.key),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? theme.colorScheme.primaryContainer.withAlpha(100)
                        : theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Row(
                    children: [
                      if (isSelected)
                        Icon(
                          Icons.check_circle,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                      if (isSelected) const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          style.title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: isSelected
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.colorScheme.onSurfaceVariant,
                            fontWeight:
                                isSelected ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 16),
          // 汇报风格
          Text(
            l10n.reportStyle,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          ..._availableStyles!.reportStyles.map((style) {
            final isSelected = _selectedReportStyle == style.key;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                onTap: _isUpdatingStyle
                    ? null
                    : () => _updateStyle(reportStyle: style.key),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? theme.colorScheme.primaryContainer.withAlpha(100)
                        : theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Row(
                    children: [
                      if (isSelected)
                        Icon(
                          Icons.check_circle,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                      if (isSelected) const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          style.title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: isSelected
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.colorScheme.onSurfaceVariant,
                            fontWeight:
                                isSelected ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
