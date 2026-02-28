import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/backend/api_client.dart';

import 'order_page.dart';

/// 钱包充值页面
/// 按照新 UI 设计重构
/// Credit 与人民币 1:1 兑换（1元 = 1分）
class WalletPage extends StatefulWidget {
  final bool showBackButton;

  const WalletPage({super.key, this.showBackButton = true});

  @override
  State<WalletPage> createState() => _WalletPageState();
}

class _WalletPageState extends State<WalletPage> {
  // 预设金额选项
  final List<double> _presetAmounts = [10, 50, 100, 200];

  // 选中的预设金额索引
  int _selectedPresetIndex = 1; // 默认选中 50

  // 自定义金额（元）
  double _customAmount = 10;

  // 用户余额（分）- 从后端获取
  int _balanceCredits = 0;

  // 自动刷新定时器（每5秒刷新余额）
  Timer? _refreshTimer;

  // 主题绿色
  static const Color _primaryGreen = Color(0xFF4CAF50);
  static const Color _lightGreen = Color(0xFFE8F5E9);

  @override
  void initState() {
    super.initState();
    _customAmount = _presetAmounts[_selectedPresetIndex];
    _loadUserBalance();
    // 启动定时器，每5秒自动刷新余额
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _loadUserBalance();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadUserBalance() async {
    if (!mounted) return;
    // 不显示加载指示器，静默刷新
    try {
      final apiClient = context.read<PsygoApiClient>();
      final userInfo = await apiClient.getUserInfo();
      if (!mounted) return;
      setState(() {
        _balanceCredits = userInfo.creditBalance;
      });
    } catch (e) {
      // 静默失败，不显示错误提示
      if (kDebugMode) {
        print('Failed to load balance: $e');
      }
    }
  }

  void _onPresetTap(int index) {
    setState(() {
      _selectedPresetIndex = index;
      _customAmount = _presetAmounts[index];
    });
  }

  void _onAmountIncrease() {
    setState(() {
      _customAmount += 10;
      _selectedPresetIndex = -1; // 取消预设选中
    });
  }

  void _onAmountDecrease() {
    if (_customAmount > 0.01) {
      setState(() {
        _customAmount = (_customAmount - 10).clamp(0.01, double.infinity);
        _selectedPresetIndex = -1; // 取消预设选中
      });
    }
  }

  Future<void> _onRecharge() async {
    final l10n = L10n.of(context);

    // 公测阶段提示弹窗
    await showDialog(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final isDark = theme.brightness == Brightness.dark;
        final accentSurface =
            _tint(colorScheme.surface, _lightGreen, isDark ? 0.2 : 0.7);
        var copied = false;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            insetPadding: const EdgeInsets.all(24),
            title: Row(
              children: [
                const Icon(Icons.info_outline, color: _primaryGreen, size: 28),
                const SizedBox(width: 12),
                Text(l10n.walletPublicBetaDialogTitle, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.walletPublicBetaDialogBody, style: const TextStyle(fontSize: 15, height: 1.5)),
                const SizedBox(height: 16),
                Text(
                  l10n.walletPublicBetaDialogContact,
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () {
                          Clipboard.setData(const ClipboardData(text: 'psygofeedback@163.com'));
                          setDialogState(() => copied = true);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: accentSurface,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.email_outlined, size: 18, color: _primaryGreen),
                              const SizedBox(width: 8),
                              const Flexible(
                                child: Text(
                                  'psygofeedback@163.com',
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: _primaryGreen),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                copied ? Icons.check : Icons.copy,
                                size: 14,
                                color: _primaryGreen,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (copied)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '✓ ${l10n.copiedToClipboard}',
                          style: const TextStyle(fontSize: 12, color: _primaryGreen),
                        ),
                      ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.appUpdateGotIt, style: const TextStyle(color: _primaryGreen, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        );
      },
    );
    return;

    // 以下代码暂时注销（公测阶段）
    // ignore: dead_code
    if (_customAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).walletEnterValidAmount),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // 跳转到订单页面
    final payResult = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => OrderPage(amount: _customAmount),
      ),
    );

    // 如果支付成功，刷新余额并显示提示
    if (payResult == true && mounted) {
      // 刷新余额
      await _loadUserBalance();
      // 显示成功提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L10n.of(context).orderPaymentSuccess),
            behavior: SnackBarBehavior.floating,
            backgroundColor: _primaryGreen,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Color _tint(Color base, Color tint, double amount) {
    return Color.lerp(base, tint, amount) ?? base;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final l10n = L10n.of(context);
    final appBarGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        colorScheme.surface,
        _tint(colorScheme.surface, _lightGreen, isDark ? 0.12 : 0.35),
      ],
    );

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: widget.showBackButton,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: appBarGradient,
          ),
        ),
        iconTheme: IconThemeData(color: colorScheme.onSurface),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    _primaryGreen,
                    Color(0xFF66BB6A),
                  ],
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: _primaryGreen.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Icons.account_balance_wallet_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              l10n.walletTitle,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 20,
                color: colorScheme.onSurface,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
        centerTitle: true,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 24),
            // 余额卡片
            _buildBalanceCard(theme, l10n),
            const SizedBox(height: 20),

            // 充值区域
            _buildRechargeCard(theme, l10n),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildBalanceCard(ThemeData theme, L10n l10n) {
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final baseSurface = colorScheme.surfaceContainerHigh;
    final textSecondary = colorScheme.onSurfaceVariant;
    final textMuted =
        colorScheme.onSurfaceVariant.withValues(alpha: isDark ? 0.75 : 0.85);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _tint(baseSurface, _lightGreen, isDark ? 0.08 : 0.7),
            _tint(baseSurface, _primaryGreen, isDark ? 0.12 : 0.2),
            _tint(baseSurface, _primaryGreen, isDark ? 0.18 : 0.3),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: _primaryGreen.withValues(alpha: isDark ? 0.25 : 0.15),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: _primaryGreen.withValues(alpha: isDark ? 0.2 : 0.15),
            blurRadius: 24,
            spreadRadius: 2,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: isDark ? 0.3 : 0.06),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部行：当前余额 + 实时更新
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _primaryGreen,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: _primaryGreen.withAlpha(120),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    l10n.walletBalance,
                    style: TextStyle(
                      color: textSecondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              GestureDetector(
                onTap: _loadUserBalance,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: isDark ? 0.55 : 0.8,
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.refresh_rounded,
                        size: 16,
                        color: _primaryGreen,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        l10n.walletRefresh,
                        style: const TextStyle(
                          color: _primaryGreen,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 余额数字 - 使用 AnimatedSwitcher 实现平滑切换
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.2),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: Row(
              key: ValueKey(_balanceCredits),
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  _balanceCredits.toString().replaceAllMapped(
                        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
                        (Match m) => '${m[1]},',
                      ),
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.w800,
                    color: colorScheme.onSurface,
                    height: 1,
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  l10n.walletCreditsUnit,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),

          // 人民币换算
          Text(
            '${l10n.walletEquivalent} ¥${(_balanceCredits / 100).toStringAsFixed(2)}',
            style: TextStyle(
              fontSize: 13,
              color: textMuted,
            ),
          ),
          const SizedBox(height: 12),

          // 提示信息
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHigh.withValues(
                alpha: isDark ? 0.6 : 0.8,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 14,
                  color: textMuted,
                ),
                const SizedBox(width: 4),
                Text(
                  l10n.walletExchangeRate,
                  style: TextStyle(
                    fontSize: 12,
                    color: textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRechargeCard(ThemeData theme, L10n l10n) {
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final textSecondary = colorScheme.onSurfaceVariant;
    final textMuted =
        colorScheme.onSurfaceVariant.withValues(alpha: isDark ? 0.75 : 0.85);
    final outline =
        colorScheme.outlineVariant.withValues(alpha: isDark ? 0.55 : 0.35);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.surfaceContainerHigh,
            colorScheme.surfaceContainerLow.withValues(alpha: isDark ? 0.8 : 0.6),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: outline,
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: _primaryGreen.withValues(alpha: isDark ? 0.12 : 0.08),
            blurRadius: 20,
            spreadRadius: 0,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: isDark ? 0.3 : 0.05),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _tint(
                    colorScheme.surface,
                    _lightGreen,
                    isDark ? 0.18 : 0.8,
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.bolt,
                      size: 16,
                      color: _primaryGreen,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      l10n.walletCustomRecharge,
                      style: const TextStyle(
                        color: _primaryGreen,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.walletFlexibleRecharge,
            style: TextStyle(
              fontSize: 13,
              color: textMuted,
            ),
          ),
          const SizedBox(height: 20),

          // 快捷金额标签
          Text(
            l10n.walletQuickAmount,
            style: TextStyle(
              fontSize: 13,
              color: textSecondary,
            ),
          ),
          const SizedBox(height: 10),

          // 快捷金额按钮
          Row(
            children: List.generate(_presetAmounts.length, (index) {
              final amount = _presetAmounts[index];
              final isSelected = _selectedPresetIndex == index;

              return Expanded(
                child: GestureDetector(
                  onTap: () => _onPresetTap(index),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    margin: EdgeInsets.only(
                      right: index < _presetAmounts.length - 1 ? 10 : 0,
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? _primaryGreen
                          : colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected ? _primaryGreen : outline,
                        width: isSelected ? 2 : 1,
                      ),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: _primaryGreen.withAlpha(60),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    child: Center(
                      child: Text(
                        amount < 1 ? '¥${amount.toStringAsFixed(2)}' : '¥${amount.toInt()}',
                        style: TextStyle(
                          color: isSelected ? Colors.white : colorScheme.onSurface,
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 20),

          // 自定义金额标签
          Text(
            l10n.walletCustomAmount,
            style: TextStyle(
              fontSize: 13,
              color: textSecondary,
            ),
          ),
          const SizedBox(height: 14),

          // 自定义金额输入（带 +/- 按钮）
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: outline,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                // 减少按钮
                _buildAmountButton(
                  icon: Icons.remove,
                  onTap: _onAmountDecrease,
                  enabled: _customAmount > 0.01,
                  theme: theme,
                ),
                // 金额显示
                Expanded(
                  child: Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '¥',
                          style: TextStyle(
                            fontSize: 16,
                            color: textSecondary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _customAmount < 1 ? _customAmount.toStringAsFixed(2) : _customAmount.toInt().toString(),
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // 增加按钮
                _buildAmountButton(
                  icon: Icons.add,
                  onTap: _onAmountIncrease,
                  enabled: true,
                  theme: theme,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 将获得积分提示
          Center(
            child: Text(
              '${l10n.walletWillGet} ${(_customAmount * 100).toInt()}${l10n.walletCreditsUnit}',
              style: TextStyle(
                fontSize: 13,
                color: _primaryGreen,
              ),
            ),
          ),
          const SizedBox(height: 28),

          // 充值按钮
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: _onRecharge,
              style: ElevatedButton.styleFrom(
                backgroundColor: _primaryGreen,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 0,
                shadowColor: _primaryGreen.withValues(alpha: isDark ? 0.3 : 0.35),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.bolt_rounded, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '${l10n.walletRechargeNow} ¥${_customAmount < 1 ? _customAmount.toStringAsFixed(2) : _customAmount.toInt()}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAmountButton({
    required IconData icon,
    required VoidCallback onTap,
    required bool enabled,
    required ThemeData theme,
  }) {
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: enabled
              ? colorScheme.surfaceContainerHighest
              : colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(
              alpha: enabled ? 0.6 : 0.4,
            ),
            width: 1,
          ),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: colorScheme.shadow.withValues(
                      alpha: isDark ? 0.3 : 0.08,
                    ),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Icon(
          icon,
          size: 22,
          color: enabled
              ? _primaryGreen
              : colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}
