import 'package:flutter/material.dart';

import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/utils/localized_exception_extension.dart';

import '../models/agent.dart';
import '../models/plugin.dart';
import '../repositories/agent_repository.dart';
import '../repositories/plugin_repository.dart';
import 'custom_network_image.dart';

/// 培训详情 Sheet（支持底部弹窗和居中对话框两种模式）
/// 展示插件详情和可培训的员工列表
class TrainingDetailSheet extends StatefulWidget {
  final Plugin plugin;
  final VoidCallback? onInstalled;
  final bool isDialog;

  const TrainingDetailSheet({
    super.key,
    required this.plugin,
    this.onInstalled,
    this.isDialog = false,
  });

  @override
  State<TrainingDetailSheet> createState() => _TrainingDetailSheetState();
}

class _TrainingDetailSheetState extends State<TrainingDetailSheet> {
  final AgentRepository _agentRepository = AgentRepository();
  final PluginRepository _pluginRepository = PluginRepository();

  List<Agent> _employees = [];
  Set<String> _installedAgentIds = {};
  bool _isLoading = true;
  String? _error;
  String? _installingAgentId;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _agentRepository.dispose();
    _pluginRepository.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // 加载员工列表
      final page = await _agentRepository.getUserAgents();
      final employees = page.agents;

      // 检查每个员工是否已安装此插件
      final installedIds = <String>{};
      for (final employee in employees) {
        if (!employee.isReady) continue;
        try {
          final plugins =
              await _pluginRepository.getAgentPlugins(employee.agentId);
          if (plugins
              .any((p) => p.pluginName == widget.plugin.name && p.isActive)) {
            installedIds.add(employee.agentId);
          }
        } catch (_) {
          // 忽略单个检查错误
        }
      }

      if (mounted) {
        setState(() {
          _employees = employees;
          _installedAgentIds = installedIds;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toLocalizedString(
            context,
            ExceptionContext.loadTrainingDetail,
          );
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _installForAgent(Agent agent) async {
    if (_installingAgentId != null) return;

    // 检查是否需要配置
    if (widget.plugin.requiresConfig) {
      final config = await _showConfigDialog();
      if (config == null) return; // 用户取消
      await _doInstall(agent, config);
    } else {
      await _doInstall(agent, null);
    }
  }

  Future<Map<String, dynamic>?> _showConfigDialog() async {
    final configSchema = widget.plugin.configSchema;
    if (configSchema == null || configSchema.isEmpty) {
      return {};
    }

    // 获取配置字段（兼容两种 schema 格式）
    final properties = _getSchemaProperties(configSchema);
    if (properties.isEmpty) {
      return {};
    }

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _ConfigDialog(
        pluginName: widget.plugin.name,
        schema: configSchema,
        properties: properties,
      ),
    );

    return result;
  }

  /// 获取配置字段（兼容两种 schema 格式）
  /// 1. 标准 JSON Schema: {"properties": {"field": {...}}}
  /// 2. 简化格式（后端实际使用）: {"field": {"type": "string", ...}}
  Map<String, dynamic> _getSchemaProperties(Map<String, dynamic> schema) {
    // 尝试标准 JSON Schema 格式
    final properties = schema['properties'];
    if (properties is Map && properties.isNotEmpty) {
      return properties.cast<String, dynamic>();
    }

    // 后端简化格式：过滤出有效的字段定义
    final result = <String, dynamic>{};
    for (final entry in schema.entries) {
      // 跳过 JSON Schema 的元数据字段
      if (['type', 'required', '\$schema', 'title', 'description']
          .contains(entry.key)) {
        continue;
      }
      // 检查是否是有效的字段定义（必须有 type 属性）
      if (entry.value is Map && (entry.value as Map)['type'] != null) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  Future<void> _doInstall(Agent agent, Map<String, dynamic>? config) async {
    setState(() {
      _installingAgentId = agent.agentId;
    });

    try {
      await _pluginRepository.installPlugin(
        agent.agentId,
        widget.plugin.name,
        config: config,
      );

      if (mounted) {
        setState(() {
          _installedAgentIds.add(agent.agentId);
          _installingAgentId = null;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L10n.of(context).trainingStarted(agent.displayName)),
            behavior: SnackBarBehavior.floating,
          ),
        );

        widget.onInstalled?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _installingAgentId = null;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L10n.of(context).trainingFailed),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

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

          // 插件信息头部
          _buildHeader(theme, l10n),

          const Divider(height: 1),

          // 员工列表（使用固定高度，对话框模式隐藏滚动条）
          Flexible(
            child: ScrollConfiguration(
              behavior: widget.isDialog
                  ? ScrollConfiguration.of(context).copyWith(scrollbars: false)
                  : ScrollConfiguration.of(context),
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.5,
                child: _buildEmployeeList(theme, l10n),
              ),
            ),
          ),

          // 安全区域（仅底部弹窗模式）
          if (!widget.isDialog)
            SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, L10n l10n) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primaryContainer.withAlpha(80),
            theme.colorScheme.secondaryContainer.withAlpha(60),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.primary.withAlpha(30),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          // 图标
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  theme.colorScheme.primary.withAlpha(30),
                  theme.colorScheme.tertiary.withAlpha(20),
                ],
              ),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withAlpha(25),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: widget.plugin.iconUrl.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: CustomNetworkImage(
                      widget.plugin.iconUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildIconFallback(theme),
                    ),
                  )
                : _buildIconFallback(theme),
          ),
          const SizedBox(width: 16),

          // 信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.plugin.name,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.plugin.description,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                // 统计信息 - 胶囊样式
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withAlpha(25),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.school_rounded,
                        size: 14,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        l10n.trainedEmployees(widget.plugin.installedCount),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIconFallback(ThemeData theme) {
    return Center(
      child: Icon(
        Icons.extension_outlined,
        size: 32,
        color: theme.colorScheme.secondary,
      ),
    );
  }

  Widget _buildEmployeeList(
    ThemeData theme,
    L10n l10n,
  ) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    theme.colorScheme.errorContainer.withAlpha(100),
                    theme.colorScheme.errorContainer.withAlpha(50),
                  ],
                ),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer.withAlpha(120),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.error_outline_rounded,
                    size: 28,
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.errorLoadingData,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _loadData,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(l10n.tryAgain),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 过滤出就绪的员工
    final readyEmployees = _employees.where((e) => e.isReady).toList();

    if (readyEmployees.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    theme.colorScheme.surfaceContainerHighest.withAlpha(150),
                    theme.colorScheme.surfaceContainerHighest.withAlpha(80),
                  ],
                ),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withAlpha(180),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.people_outline_rounded,
                    size: 30,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.noEmployeesForTraining,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.hireEmployeeFirst,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    // 分为已培训和未培训两组
    final trained = readyEmployees
        .where((e) => _installedAgentIds.contains(e.agentId))
        .toList();
    final untrained = readyEmployees
        .where((e) => !_installedAgentIds.contains(e.agentId))
        .toList();

    return ListView(
      padding: const EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: 96,
      ),
      children: [
        // 未培训员工（可操作）
        if (untrained.isNotEmpty) ...[
          _buildSectionHeader(theme, l10n.untrainedEmployees, untrained.length),
          ...untrained.map((e) => _buildEmployeeItem(theme, l10n, e, false)),
        ],

        // 已培训员工（只读）
        if (trained.isNotEmpty) ...[
          const SizedBox(height: 16),
          _buildSectionHeader(
              theme, l10n.trainedEmployeesSection, trained.length),
          ...trained.map((e) => _buildEmployeeItem(theme, l10n, e, true)),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title, int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 8),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmployeeItem(
    ThemeData theme,
    L10n l10n,
    Agent employee,
    bool isTrained,
  ) {
    final isInstalling = _installingAgentId == employee.agentId;

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isTrained
              ? theme.colorScheme.primary.withValues(alpha: 0.3)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: _buildEmployeeAvatar(theme, employee),
        title: Text(
          employee.displayName,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        trailing: isTrained
            ? Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check, size: 14, color: Colors.green),
                    const SizedBox(width: 4),
                    Text(
                      l10n.trained,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.green,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              )
            : isInstalling
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : FilledButton.tonal(
                    onPressed: () => _installForAgent(employee),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      l10n.train,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
      ),
    );
  }

  Widget _buildEmployeeAvatar(ThemeData theme, Agent employee) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(10),
      ),
      child: employee.avatarUrl != null && employee.avatarUrl!.isNotEmpty
          ? ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CustomNetworkImage(
                employee.avatarUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    _buildAvatarFallback(theme, employee),
              ),
            )
          : _buildAvatarFallback(theme, employee),
    );
  }

  Widget _buildAvatarFallback(ThemeData theme, Agent employee) {
    return Center(
      child: Text(
        employee.displayName.isNotEmpty
            ? employee.displayName[0].toUpperCase()
            : '?',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// 配置表单对话框
class _ConfigDialog extends StatefulWidget {
  final String pluginName;
  final Map<String, dynamic> schema;
  final Map<String, dynamic> properties;

  const _ConfigDialog({
    required this.pluginName,
    required this.schema,
    required this.properties,
  });

  @override
  State<_ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<_ConfigDialog> {
  late Map<String, TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    // 为每个配置字段创建 TextEditingController
    _controllers = {};
    for (final key in widget.properties.keys) {
      _controllers[key] = TextEditingController();
    }
  }

  @override
  void dispose() {
    // 正确的时机释放所有 controller
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 获取必填字段列表（兼容两种 schema 格式）
  List<String> _getRequiredFields() {
    // 标准 JSON Schema 格式：顶层 required 数组
    final requiredList = widget.schema['required'];
    if (requiredList is List) {
      return requiredList.cast<String>();
    }

    // 后端简化格式：每个字段内部的 required 属性
    final result = <String>[];
    for (final entry in widget.properties.entries) {
      final fieldSchema = entry.value as Map<String, dynamic>;
      if (fieldSchema['required'] == true) {
        result.add(entry.key);
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final requiredFields = _getRequiredFields();

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.configurePlugin(widget.pluginName),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 20),

              // 配置字段
              ...widget.properties.entries.map((entry) {
                final key = entry.key;
                final prop = entry.value as Map<String, dynamic>;
                final isRequired = requiredFields.contains(key);
                final title = prop['title'] as String? ?? key;
                final description = prop['description'] as String?;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: TextField(
                    controller: _controllers[key],
                    decoration: InputDecoration(
                      labelText: isRequired ? '$title *' : title,
                      helperText: description,
                      helperMaxLines: 2,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.3),
                    ),
                  ),
                );
              }),

              const SizedBox(height: 8),

              // 按钮
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(l10n.cancel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        final config = <String, dynamic>{};
                        for (final entry in _controllers.entries) {
                          final value = entry.value.text.trim();
                          if (value.isNotEmpty) {
                            config[entry.key] = value;
                          }
                        }
                        Navigator.pop(context, config);
                      },
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(l10n.confirm),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
