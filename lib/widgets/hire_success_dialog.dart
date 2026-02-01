import 'package:flutter/material.dart';

import 'package:psygo/l10n/l10n.dart';

/// 雇佣成功对话框
/// 在用户成功雇佣员工后显示，提供更醒目的成功反馈
class HireSuccessDialog extends StatefulWidget {
  final String employeeName;
  final bool isFirstEmployee;
  final VoidCallback? onViewEmployee;
  final VoidCallback? onContinueHiring;

  const HireSuccessDialog({
    super.key,
    required this.employeeName,
    this.isFirstEmployee = false,
    this.onViewEmployee,
    this.onContinueHiring,
  });

  @override
  State<HireSuccessDialog> createState() => _HireSuccessDialogState();
}

class _HireSuccessDialogState extends State<HireSuccessDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.elasticOut,
      ),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
      ),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final displayName = widget.employeeName.trim();

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
      ),
      elevation: 0,
      backgroundColor: theme.colorScheme.surface,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: Opacity(
              opacity: _fadeAnimation.value,
              child: child,
            ),
          );
        },
        child: Container(
          constraints: const BoxConstraints(maxWidth: 360),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                theme.colorScheme.surface,
                theme.colorScheme.surfaceContainerLow,
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.green.withAlpha(30),
                blurRadius: 32,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 成功图标 - 带动画的勾选图标
                _buildSuccessIcon(theme),
                const SizedBox(height: 24),

                // 标题
                Text(
                  widget.isFirstEmployee
                      ? l10n.firstEmployeeHired
                      : l10n.hireSuccessTitle,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Colors.green.shade700,
                    letterSpacing: -0.3,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),

                if (displayName.isNotEmpty) ...[
                  _buildNameBadge(theme, displayName),
                  const SizedBox(height: 12),
                ],

                // 副标题
                Text(
                  l10n.hireSuccessGeneric,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),

                // 首次雇佣的特殊提示
                if (widget.isFirstEmployee) ...[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          theme.colorScheme.primaryContainer.withAlpha(60),
                          theme.colorScheme.primaryContainer.withAlpha(30),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: theme.colorScheme.primary.withAlpha(40),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withAlpha(30),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.tips_and_updates_rounded,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l10n.firstEmployeeHint,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // 入职中提示
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.orange.withAlpha(20),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.orange.withAlpha(50),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.orange.shade600,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        l10n.employeeOnboardingHint,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: Colors.orange.shade700,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 28),

                // 操作按钮
                Row(
                  children: [
                    // 继续招聘按钮
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                          widget.onContinueHiring?.call();
                        },
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
                          l10n.continueHiring,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),

                    // 查看员工按钮
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                          widget.onViewEmployee?.call();
                        },
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          backgroundColor: Colors.green.shade600,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.person_rounded, size: 18),
                            const SizedBox(width: 6),
                            Text(
                              l10n.viewEmployee,
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
      ),
    );
  }

  Widget _buildNameBadge(ThemeData theme, String name) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withAlpha(80),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: theme.colorScheme.primary.withAlpha(60),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.badge_rounded,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              name,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onPrimaryContainer,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessIcon(ThemeData theme) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 800),
      curve: Curves.elasticOut,
      builder: (context, value, child) {
        return Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.green.shade400,
                Colors.green.shade600,
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.green.withAlpha((50 * value).toInt()),
                blurRadius: 24 * value,
                spreadRadius: 4 * value,
              ),
            ],
          ),
          child: Transform.scale(
            scale: value,
            child: const Icon(
              Icons.check_rounded,
              size: 52,
              color: Colors.white,
            ),
          ),
        );
      },
    );
  }
}

/// 显示雇佣成功对话框的便捷方法
Future<void> showHireSuccessDialog({
  required BuildContext context,
  required String employeeName,
  bool isFirstEmployee = false,
  VoidCallback? onViewEmployee,
  VoidCallback? onContinueHiring,
}) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => HireSuccessDialog(
      employeeName: employeeName,
      isFirstEmployee: isFirstEmployee,
      onViewEmployee: onViewEmployee,
      onContinueHiring: onContinueHiring,
    ),
  );
}
