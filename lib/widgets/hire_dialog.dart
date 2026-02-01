import 'package:flutter/material.dart';

import 'package:psygo/l10n/l10n.dart';

import '../models/agent_template.dart';
import '../models/hire_result.dart';
import '../repositories/agent_template_repository.dart';
import 'custom_network_image.dart';

/// 雇佣对话框
/// 用户点击模板后弹出，输入员工名称并确认雇佣
class HireDialog extends StatefulWidget {
  final AgentTemplate template;
  final AgentTemplateRepository repository;

  const HireDialog({
    super.key,
    required this.template,
    required this.repository,
  });

  @override
  State<HireDialog> createState() => _HireDialogState();
}

class _HireDialogState extends State<HireDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _invitationCodeController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  bool _isLoading = false;
  String? _error;

  // 名称长度限制
  static const int _maxNameLength = 20;

  // 验证状态
  bool get _isNameTooLong => _nameController.text.trim().length > _maxNameLength;

  @override
  void initState() {
    super.initState();
    // 默认使用模板名称作为员工名（超长时截断）
    final templateName = widget.template.name;
    _nameController.text = templateName.length > _maxNameLength
        ? templateName.substring(0, _maxNameLength)
        : templateName;
    // 自动选中文本
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _nameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _nameController.text.length,
      );
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _invitationCodeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _onConfirm() async {
    final name = _nameController.text.trim();
    final invitationCode = _invitationCodeController.text.trim();

    if (name.isEmpty) {
      setState(() {
        _error = L10n.of(context).employeeNameRequired;
      });
      return;
    }

    if (_isNameTooLong) {
      setState(() {
        _error = L10n.of(context).employeeNameTooLong;
      });
      return;
    }

    if (invitationCode.isEmpty) {
      setState(() {
        _error = L10n.of(context).invitationCodeRequired;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // 调用统一创建接口，返回 UnifiedCreateAgentResponse
      final response = await widget.repository.hireFromTemplate(
        widget.template.id,
        name,
        invitationCode: invitationCode,
      );
      if (mounted) {
        // 返回响应对象，调用方可以获取 agentId、matrixUserId 等
        Navigator.of(context).pop(HireResult(
          response: response,
          displayName: name,
        ));
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
      ),
      elevation: 0,
      backgroundColor: theme.colorScheme.surface,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 380),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.shadow.withAlpha(20),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题
              Text(
                l10n.hireEmployee,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),

              // 模板信息预览
              _buildTemplatePreview(theme),
              const SizedBox(height: 24),

              // 员工名称输入
              TextField(
                controller: _nameController,
                focusNode: _focusNode,
                decoration: InputDecoration(
                  labelText: l10n.employeeName,
                  hintText: l10n.enterEmployeeName,
                  prefixIcon: Icon(
                    Icons.badge_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: _isNameTooLong
                          ? theme.colorScheme.error
                          : theme.colorScheme.outlineVariant.withAlpha(80),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: _isNameTooLong
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                      width: 2,
                    ),
                  ),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerLow,
                  counterText: '${_nameController.text.length}/$_maxNameLength',
                  counterStyle: TextStyle(
                    color: _isNameTooLong
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                  errorText: _isNameTooLong ? l10n.employeeNameTooLong : null,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 16,
                  ),
                ),
                textInputAction: TextInputAction.next,
                enabled: !_isLoading,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),

              // 邀请码输入
              TextField(
                controller: _invitationCodeController,
                decoration: InputDecoration(
                  labelText: l10n.invitationCode,
                  hintText: l10n.enterInvitationCode,
                  prefixIcon: Icon(
                    Icons.vpn_key_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: theme.colorScheme.outlineVariant.withAlpha(80),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: theme.colorScheme.primary,
                      width: 2,
                    ),
                  ),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerLow,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 16,
                  ),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _onConfirm(),
                enabled: !_isLoading,
              ),

              // 错误提示
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer.withAlpha(40),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: theme.colorScheme.error.withAlpha(40),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.error.withAlpha(30),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.error_outline_rounded,
                          size: 16,
                          color: theme.colorScheme.error,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _error!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 28),

              // 操作按钮
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isLoading ? null : () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        side: BorderSide(
                          color: theme.colorScheme.outline.withAlpha(100),
                        ),
                      ),
                      child: Text(
                        l10n.cancel,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: FilledButton(
                      onPressed: _isLoading ? null : _onConfirm,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: _isLoading
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: theme.colorScheme.onPrimary,
                              ),
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.person_add_rounded, size: 18),
                                const SizedBox(width: 6),
                                Text(
                                  l10n.confirmHire,
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
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

  Widget _buildTemplatePreview(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primaryContainer.withAlpha(50),
            theme.colorScheme.primaryContainer.withAlpha(25),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.primary.withAlpha(30),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          // 头像
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  theme.colorScheme.primaryContainer,
                  theme.colorScheme.primaryContainer.withAlpha(180),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withAlpha(30),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: widget.template.avatarUrl != null &&
                    widget.template.avatarUrl!.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: CustomNetworkImage(
                      widget.template.avatarUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildAvatarFallback(theme),
                    ),
                  )
                : _buildAvatarFallback(theme),
          ),
          const SizedBox(width: 16),

          // 信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.template.name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Text(
                  widget.template.subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.3,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarFallback(ThemeData theme) {
    return Center(
      child: Icon(
        Icons.smart_toy_rounded,
        size: 30,
        color: theme.colorScheme.primary,
      ),
    );
  }
}
