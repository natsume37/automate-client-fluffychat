import 'dart:math';
import 'package:flutter/material.dart';
import 'package:psygo/l10n/l10n.dart';
import '../core/api_client.dart';
import '../models/hire_result.dart';
import '../repositories/agent_template_repository.dart';
import '../utils/localized_exception_extension.dart';
import 'dicebear_avatar_picker.dart';

/// 招聘（单步创建）
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
  // 表单控制器
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocusNode = FocusNode();

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
    super.dispose();
  }

  /// 提交创建
  Future<void> _onSubmit() async {
    if (_isSubmitting) return;

    // 直接创建前保留名称校验（与原步骤1一致）
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
      _nameFocusNode.requestFocus();
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    // 调用创建接口（异步），先返回 UI 结果让入职动画接管
    try {
      final response = await widget.repository.createCustomAgentWithPlugins(
        name: _nameController.text.trim(),
        plugins: null,
        avatarUrl: _avatarUrl,
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        HireResult(
          responseFuture: Future.value(response),
          displayName: _nameController.text.trim(),
        ),
      );
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
      context,
      ExceptionContext.customHireEmployee,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    return PopScope(
      canPop: !_isSubmitting,
      child: AbsorbPointer(
        absorbing: _isSubmitting,
        child: widget.isDialog
            ? _buildDialogContent(theme, l10n)
            : GestureDetector(
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
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(28)),
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
                          // 内容区域
                          Expanded(
                            child: ListView(
                              controller: scrollController,
                              padding:
                                  const EdgeInsets.fromLTRB(24, 16, 24, 24),
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
              ),
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
          // 内容区域
          Flexible(
            child: ScrollConfiguration(
              behavior:
                  ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
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
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
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

  Widget _buildContent(ThemeData theme, L10n l10n) {
    return _buildBasicInfoStep(theme, l10n);
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
        const SizedBox(height: 14),
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
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
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
              onPressed: _isSubmitting ? null : () => Navigator.pop(context),
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
                l10n.cancel,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(width: 14),
          // 创建按钮（直接提交）
          Expanded(
            child: FilledButton(
              onPressed: _isSubmitting ? null : _onSubmit,
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
                          l10n.createEmployee,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.add_rounded, size: 20),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
