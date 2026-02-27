import 'dart:math';

import 'package:flutter/material.dart';

import 'package:psygo/l10n/l10n.dart';

import '../core/api_client.dart';
import '../models/plugin.dart';
import '../models/hire_result.dart';
import '../repositories/agent_template_repository.dart';
import '../repositories/plugin_repository.dart';
import '../utils/localized_exception_extension.dart';
import 'custom_network_image.dart';
import 'dicebear_avatar_picker.dart';

/// 定制招聘向导（三步）
/// 第1步：基本信息（名称）
/// 第2步：选择插件（多选）
/// 第3步：配置插件（如有需要）
class CustomHireDialog extends StatefulWidget {
  final AgentTemplateRepository repository;
  final bool isDialog;

  const CustomHireDialog({
    super.key,
    required this.repository,
    this.isDialog = false,
  });

  @override
  State<CustomHireDialog> createState() => _CustomHireDialogState();
}

class _CustomHireDialogState extends State<CustomHireDialog> {
  // 当前步骤（0-基本信息, 1-选择插件, 2-配置插件）
  int _currentStep = 0;

  // 表单控制器
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocusNode = FocusNode();

  // 插件相关
  final PluginRepository _pluginRepository = PluginRepository();
  List<Plugin> _availablePlugins = [];
  Set<String> _selectedPlugins = {};
  Map<String, Map<String, TextEditingController>> _pluginConfigControllers = {};
  bool _isLoadingPlugins = false;
  String? _pluginError;

  // 提交状态
  bool _isSubmitting = false;
  String? _error;

  // 头像 URL
  String? _avatarUrl;

  // 名称长度限制
  static const int _maxNameLength = 20;

  // 验证状态
  bool get _isNameValid =>
      _nameController.text.trim().isNotEmpty &&
      !_isNameNumericOnly &&
      !_isNameTooLong;
  bool get _isNameNumericOnly =>
      _nameController.text.isNotEmpty &&
      _nameController.text
          .trim()
          .split('')
          .every((c) => '0123456789'.contains(c));
  bool get _isNameTooLong =>
      _nameController.text.trim().length > _maxNameLength;
  @override
  void initState() {
    super.initState();
    // 初始化随机头像
    _initRandomAvatar();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nameFocusNode.requestFocus();
    });
  }

  void _initRandomAvatar() {
    final random = Random();
    final styles = [
      'avataaars',
      'bottts',
      'fun-emoji',
      'adventurer',
      'adventurer-neutral',
      'big-smile',
      'lorelei',
      'notionists',
      'open-peeps',
      'personas',
      'pixel-art',
      'thumbs',
    ];
    final style = styles[random.nextInt(styles.length)];
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final seed =
        List.generate(8, (_) => chars[random.nextInt(chars.length)]).join();
    _avatarUrl = 'https://api.dicebear.com/9.x/$style/png?seed=$seed&size=256';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocusNode.dispose();
    _pluginRepository.dispose();
    // 清理所有配置控制器
    for (final controllers in _pluginConfigControllers.values) {
      for (final controller in controllers.values) {
        controller.dispose();
      }
    }
    super.dispose();
  }

  /// 加载可用插件列表
  Future<void> _loadPlugins() async {
    setState(() {
      _isLoadingPlugins = true;
      _pluginError = null;
    });

    try {
      final plugins = await _pluginRepository.getPluginsWithStats();
      if (mounted) {
        setState(() {
          _availablePlugins = plugins;
          _isLoadingPlugins = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _pluginError = e.toLocalizedString(
            context,
            ExceptionContext.customHireEmployee,
          );
          _isLoadingPlugins = false;
        });
      }
    }
  }

  /// 切换到下一步
  void _nextStep() {
    if (_currentStep == 0) {
      // 验证名称
      if (!_isNameValid) {
        setState(() {
          if (_nameController.text.trim().isEmpty) {
            _error = L10n.of(context).employeeNameRequired;
          } else if (_isNameNumericOnly) {
            _error = L10n.of(context).employeeNameCannotBeNumeric;
          } else if (_isNameTooLong) {
            _error = L10n.of(context).employeeNameTooLong;
          }
        });
        return;
      }
      setState(() => _error = null);
      // 加载插件列表
      _loadPlugins();
    }

    if (_currentStep < 2) {
      setState(() => _currentStep++);
    }
  }

  /// 返回上一步
  void _previousStep() {
    if (_currentStep > 0) {
      setState(() {
        _currentStep--;
        _error = null;
      });
    }
  }

  /// 切换插件选中状态
  void _togglePlugin(Plugin plugin) {
    setState(() {
      if (_selectedPlugins.contains(plugin.name)) {
        _selectedPlugins.remove(plugin.name);
        // 清理配置控制器
        _pluginConfigControllers[plugin.name]
            ?.values
            .forEach((c) => c.dispose());
        _pluginConfigControllers.remove(plugin.name);
      } else {
        _selectedPlugins.add(plugin.name);
        // 初始化配置控制器
        if (_hasValidConfigSchema(plugin)) {
          _initConfigControllers(plugin);
        }
      }
    });
  }

  /// 检查插件是否有有效的配置 Schema
  ///
  /// 支持两种格式：
  /// 1. 标准 JSON Schema: {"properties": {"field": {...}}}
  /// 2. 简化格式（后端实际使用）: {"field": {"type": "string", ...}}
  bool _hasValidConfigSchema(Plugin plugin) {
    final schema = plugin.configSchema;
    if (schema == null || schema.isEmpty) return false;

    // 尝试标准 JSON Schema 格式
    final properties = schema['properties'];
    if (properties is Map && properties.isNotEmpty) return true;

    // 后端简化格式：schema 本身就是字段定义
    // 检查是否有任何字段定义（值是 Map 且包含 type 字段）
    for (final entry in schema.entries) {
      if (entry.value is Map && (entry.value as Map)['type'] != null) {
        return true;
      }
    }
    return false;
  }

  /// 获取配置字段（兼容两种 schema 格式）
  Map<String, dynamic> _getSchemaProperties(Map<String, dynamic> schema) {
    // 标准 JSON Schema 格式
    final properties = schema['properties'];
    if (properties is Map && properties.isNotEmpty) {
      return properties.cast<String, dynamic>();
    }

    // 后端简化格式：过滤出有效的字段定义
    final result = <String, dynamic>{};
    for (final entry in schema.entries) {
      // 跳过 JSON Schema 元字段
      if (['type', 'required', '\$schema', 'title', 'description']
          .contains(entry.key)) {
        continue;
      }
      if (entry.value is Map && (entry.value as Map)['type'] != null) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  /// 获取必填字段列表（兼容两种 schema 格式）
  List<String> _getRequiredFields(
      Map<String, dynamic> schema, Map<String, dynamic> properties) {
    // 标准 JSON Schema 格式：顶层 required 数组
    final required = schema['required'];
    if (required is List) {
      return required.cast<String>();
    }

    // 后端简化格式：每个字段内部的 required 属性
    final result = <String>[];
    for (final entry in properties.entries) {
      final fieldSchema = entry.value as Map<String, dynamic>;
      if (fieldSchema['required'] == true) {
        result.add(entry.key);
      }
    }
    return result;
  }

  /// 初始化插件配置控制器
  void _initConfigControllers(Plugin plugin) {
    final schema = plugin.configSchema;
    if (schema == null) return;

    final properties = _getSchemaProperties(schema);
    final controllers = <String, TextEditingController>{};

    for (final key in properties.keys) {
      controllers[key] = TextEditingController();
    }

    _pluginConfigControllers[plugin.name] = controllers;
  }

  /// 获取需要配置的插件
  List<Plugin> get _pluginsNeedingConfig {
    return _availablePlugins
        .where((p) =>
            _selectedPlugins.contains(p.name) && _hasValidConfigSchema(p))
        .toList();
  }

  /// 收集插件配置
  Map<String, dynamic> _collectPluginConfig(String pluginName) {
    final controllers = _pluginConfigControllers[pluginName];
    if (controllers == null) return {};

    final config = <String, dynamic>{};
    for (final entry in controllers.entries) {
      final value = entry.value.text.trim();
      if (value.isNotEmpty) {
        config[entry.key] = value;
      }
    }
    return config;
  }

  /// 提交创建
  Future<void> _onSubmit() async {
    if (_isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    // 构建插件配置列表
    final plugins = _selectedPlugins.map((name) {
      return PluginConfig(
        pluginName: name,
        config: _collectPluginConfig(name),
      );
    }).toList();

    // 调用创建接口（异步），先返回 UI 结果让入职动画接管
    try {
      final response = await widget.repository.createCustomAgentWithPlugins(
        name: _nameController.text.trim(),
        plugins: plugins.isNotEmpty ? plugins : null,
        avatarUrl: _avatarUrl,
      );
      if (!mounted) return;
      Navigator.of(context).pop(HireResult(
        responseFuture: Future.value(response),
        displayName: _nameController.text.trim(),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _formatError(e);
        _isSubmitting = false;
      });
    }
  }

  String _formatError(Object error) {
    if (error is ApiException) {
      return error.message;
    }
    return error.toLocalizedString(
        context, ExceptionContext.customHireEmployee);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    if (widget.isDialog) {
      return _buildDialogContent(theme, l10n);
    }

    return GestureDetector(
      onTap: () {}, // 阻止点击传递到背景
      child: DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        snap: true,
        snapSizes: const [0.9],
        builder: (context, scrollController) {
          return Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              children: [
                // 顶部拖拽指示器 - 可拖拽区域
                Container(
                  width: double.infinity,
                  color: Colors.transparent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                // 标题栏
                _buildHeader(theme, l10n),
                // 步骤指示器
                _buildStepIndicator(theme, l10n),
                // 内容区域
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    children: [
                      _buildContent(theme, l10n),
                    ],
                  ),
                ),
                // 错误提示
                if (_error != null) _buildErrorBanner(theme),
                // 底部按钮
                _buildActions(theme, l10n),
              ],
            ),
          );
        },
      ),
    );
  }

  /// PC 端 Dialog 样式
  Widget _buildDialogContent(ThemeData theme, L10n l10n) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 640),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏
          _buildHeader(theme, l10n),
          // 步骤指示器
          _buildStepIndicator(theme, l10n),
          // 内容区域
          Flexible(
            child: ScrollConfiguration(
              behavior:
                  ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: _buildContent(theme, l10n),
              ),
            ),
          ),
          // 错误提示
          if (_error != null) _buildErrorBanner(theme),
          // 底部按钮
          _buildActions(theme, l10n),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, L10n l10n) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Row(
        children: [
          // 左侧图标
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              Icons.person_add_alt_1_rounded,
              color: theme.colorScheme.primary,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          // 标题和副标题
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.customHire,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.customHireDescription,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepIndicator(ThemeData theme, L10n l10n) {
    final steps = [
      (l10n.basicInfo, Icons.badge_outlined),
      (l10n.selectPlugins, Icons.extension_outlined),
      (l10n.configurePlugins, Icons.tune_outlined),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: List.generate(steps.length * 2 - 1, (index) {
          if (index.isOdd) {
            // 连接线
            final stepIndex = index ~/ 2;
            final isCompleted = stepIndex < _currentStep;
            return Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: isCompleted
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            );
          }

          // 步骤圆点
          final stepIndex = index ~/ 2;
          final isCompleted = stepIndex < _currentStep;
          final isCurrent = stepIndex == _currentStep;
          final (label, icon) = steps[stepIndex];

          return GestureDetector(
            onTap: isCompleted
                ? () => setState(() => _currentStep = stepIndex)
                : null,
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: isCurrent ? 44 : 36,
                  height: isCurrent ? 44 : 36,
                  decoration: BoxDecoration(
                    color: isCompleted || isCurrent
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                    boxShadow: isCurrent
                        ? [
                            BoxShadow(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.3),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: Center(
                    child: isCompleted
                        ? Icon(
                            Icons.check_rounded,
                            size: 18,
                            color: theme.colorScheme.onPrimary,
                          )
                        : Icon(
                            icon,
                            size: isCurrent ? 22 : 18,
                            color: isCurrent
                                ? theme.colorScheme.onPrimary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: isCurrent
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildContent(ThemeData theme, L10n l10n) {
    switch (_currentStep) {
      case 0:
        return _buildBasicInfoStep(theme, l10n);
      case 1:
        return _buildPluginSelectionStep(theme, l10n);
      case 2:
        return _buildPluginConfigStep(theme, l10n);
      default:
        return const SizedBox.shrink();
    }
  }

  /// 第1步：基本信息
  Widget _buildBasicInfoStep(ThemeData theme, L10n l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 头像选择
        Center(
          child: DiceBearAvatarPicker(
            initialAvatarUrl: _avatarUrl,
            onAvatarChanged: (url) {
              setState(() {
                _avatarUrl = url;
              });
            },
            size: 88,
          ),
        ),
        const SizedBox(height: 20),

        // 员工名称
        _buildInputField(
          theme: theme,
          controller: _nameController,
          focusNode: _nameFocusNode,
          label: l10n.employeeName,
          hint: l10n.enterEmployeeName,
          icon: Icons.badge_outlined,
          isError: _isNameNumericOnly || _isNameTooLong,
          errorText: _isNameNumericOnly
              ? l10n.employeeNameCannotBeNumeric
              : (_isNameTooLong ? l10n.employeeNameTooLong : null),
          enabled: !_isSubmitting,
          onChanged: (_) => setState(() {}),
          maxLength: _maxNameLength,
          showCounter: true,
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  /// 第2步：选择插件
  Widget _buildPluginSelectionStep(ThemeData theme, L10n l10n) {
    if (_isLoadingPlugins) {
      return SizedBox(
        height: 200,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.loadingPlugins,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_pluginError != null) {
      return _buildErrorState(theme, l10n, _loadPlugins);
    }

    if (_availablePlugins.isEmpty) {
      return _buildEmptyPluginsState(theme, l10n);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 说明文字
        _buildInfoCard(
          theme: theme,
          icon: Icons.auto_awesome_outlined,
          text: l10n.selectPluginsHint,
          color: theme.colorScheme.primaryContainer,
        ),
        const SizedBox(height: 16),

        // 插件列表
        ...(_availablePlugins
            .map((plugin) => _buildPluginItem(plugin, theme, l10n))),

        // 跳过提示
        if (_selectedPlugins.isEmpty) ...[
          const SizedBox(height: 12),
          Text(
            l10n.skipPluginSelectionHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }

  Widget _buildPluginItem(Plugin plugin, ThemeData theme, L10n l10n) {
    final isSelected = _selectedPlugins.contains(plugin.name);
    final needsConfig = _hasValidConfigSchema(plugin);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      margin: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: isSelected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: () => _togglePlugin(plugin),
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSelected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                width: isSelected ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                // 选择指示器
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                      width: 2,
                    ),
                  ),
                  child: isSelected
                      ? Icon(
                          Icons.check_rounded,
                          size: 14,
                          color: theme.colorScheme.onPrimary,
                        )
                      : null,
                ),
                const SizedBox(width: 12),

                // 插件图标
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: plugin.iconUrl.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: CustomNetworkImage(
                            plugin.iconUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                _buildPluginIconFallback(theme),
                          ),
                        )
                      : _buildPluginIconFallback(theme),
                ),
                const SizedBox(width: 12),

                // 插件信息
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              plugin.name,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (needsConfig) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.tertiaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                l10n.requiresConfiguration,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onTertiaryContainer,
                                  fontSize: 9,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (plugin.description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          plugin.description,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPluginIconFallback(ThemeData theme) {
    return Center(
      child: Icon(
        Icons.extension_rounded,
        size: 22,
        color: theme.colorScheme.secondary,
      ),
    );
  }

  /// 第3步：配置插件
  Widget _buildPluginConfigStep(ThemeData theme, L10n l10n) {
    final pluginsToConfig = _pluginsNeedingConfig;

    if (pluginsToConfig.isEmpty) {
      return SizedBox(
        height: 200,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color:
                      theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.check_circle_outline_rounded,
                  size: 40,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.noConfigurationNeeded,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.readyToCreate,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildInfoCard(
          theme: theme,
          icon: Icons.tune_outlined,
          text: l10n.configurePluginsHint,
          color: theme.colorScheme.secondaryContainer,
        ),
        const SizedBox(height: 16),
        ...(pluginsToConfig.map(
          (plugin) => _buildPluginConfigForm(plugin, theme, l10n),
        )),
      ],
    );
  }

  Widget _buildPluginConfigForm(Plugin plugin, ThemeData theme, L10n l10n) {
    final schema = plugin.configSchema ?? {};
    final properties = _getSchemaProperties(schema);
    // 获取 required 字段列表（兼容两种格式）
    final requiredFields = _getRequiredFields(schema, properties);
    final controllers = _pluginConfigControllers[plugin.name] ?? {};

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 插件标题
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.extension_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Text(
                  plugin.name,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          // 配置字段
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: properties.entries.map((entry) {
                final fieldName = entry.key;
                final fieldSchema = entry.value as Map<String, dynamic>;
                final isRequired = requiredFields.contains(fieldName);
                final fieldType = fieldSchema['type'] as String? ?? 'string';
                final description = fieldSchema['description'] as String?;
                final title = fieldSchema['title'] as String? ??
                    _formatFieldName(fieldName);
                final controller = controllers[fieldName];

                if (controller == null) return const SizedBox.shrink();

                // 布尔类型
                if (fieldType == 'boolean') {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SwitchListTile(
                      title: Text(title),
                      subtitle: description != null ? Text(description) : null,
                      value: controller.text == 'true',
                      onChanged: (value) {
                        setState(() {
                          controller.text = value.toString();
                        });
                      },
                      contentPadding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  );
                }

                // 字符串/数字类型
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextField(
                    controller: controller,
                    decoration: InputDecoration(
                      labelText: isRequired ? '$title *' : title,
                      hintText: description ?? 'Enter $title',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surface,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                    ),
                    keyboardType:
                        fieldType == 'number' || fieldType == 'integer'
                            ? TextInputType.number
                            : TextInputType.text,
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ===== Helper Widgets =====

  Widget _buildInputField({
    required ThemeData theme,
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    FocusNode? focusNode,
    int minLines = 1,
    int maxLines = 1,
    bool enabled = true,
    bool isError = false,
    String? errorText,
    bool isOptional = false,
    ValueChanged<String>? onChanged,
    int? maxLength,
    bool showCounter = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标签行
        Row(
          children: [
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (isOptional) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  L10n.of(context).optional,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        // 输入框
        TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: Icon(icon, size: 22),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(
                color: isError
                    ? theme.colorScheme.error
                    : theme.colorScheme.outlineVariant,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(
                color: isError
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
                width: 2,
              ),
            ),
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.3),
            alignLabelWithHint: minLines > 1,
            contentPadding: EdgeInsets.symmetric(
              horizontal: 16,
              vertical: minLines > 1 ? 16 : 14,
            ),
            counterText: showCounter && maxLength != null
                ? '${controller.text.length}/$maxLength'
                : null,
            counterStyle: TextStyle(
              color: controller.text.length > (maxLength ?? 0)
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          minLines: minLines,
          maxLines: maxLines,
          enabled: enabled,
          onChanged: onChanged,
        ),
        // 错误提示
        if (errorText != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 14,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 4),
              Text(
                errorText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildInfoCard({
    required ThemeData theme,
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(ThemeData theme, L10n l10n, VoidCallback onRetry) {
    return SizedBox(
      height: 200,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: theme.colorScheme.error.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.errorLoadingData,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: onRetry,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.refresh_rounded, size: 18),
                  const SizedBox(width: 8),
                  Text(l10n.tryAgain),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyPluginsState(ThemeData theme, L10n l10n) {
    return SizedBox(
      height: 200,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.extension_off_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.noPluginsAvailable,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.skipPluginSelectionHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  String _formatFieldName(String name) {
    // snake_case to Title Case
    return name
        .split('_')
        .map(
          (word) => word.isNotEmpty
              ? '${word[0].toUpperCase()}${word.substring(1)}'
              : '',
        )
        .join(' ');
  }

  Widget _buildErrorBanner(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 20,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _error = null),
            icon: Icon(
              Icons.close_rounded,
              size: 18,
              color: theme.colorScheme.error,
            ),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(ThemeData theme, L10n l10n) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: widget.isDialog
            ? const BorderRadius.vertical(bottom: Radius.circular(24))
            : null,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          // 返回/取消按钮
          Expanded(
            child: OutlinedButton(
              onPressed: _isSubmitting
                  ? null
                  : (_currentStep > 0
                      ? _previousStep
                      : () => Navigator.pop(context)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                side: BorderSide(
                  color: theme.colorScheme.outline.withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                _currentStep > 0 ? l10n.back : l10n.cancel,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(width: 14),
          // 下一步/创建按钮
          Expanded(
            flex: _currentStep == 2 ? 2 : 1,
            child: FilledButton(
              onPressed: _isSubmitting
                  ? null
                  : (_currentStep < 2 ? _nextStep : _onSubmit),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: _isSubmitting
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: theme.colorScheme.onPrimary,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _currentStep < 2 ? l10n.next : l10n.createEmployee,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          _currentStep < 2
                              ? Icons.arrow_forward_rounded
                              : Icons.add_rounded,
                          size: 20,
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
