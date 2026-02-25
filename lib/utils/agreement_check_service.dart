import 'dart:async';

import 'package:flutter/material.dart';

import 'package:psygo/backend/api_client.dart';

/// 协议检查服务
/// 检查用户是否已接受最新版本的用户协议和隐私政策
class AgreementCheckService {
  final PsygoApiClient _apiClient;

  // 状态管理
  static bool _isDialogShowing = false;
  static bool _isInitialized = false;
  static const Duration _resumeDebounce = Duration(seconds: 3);

  // 保存引用
  static PsygoApiClient? _apiClient_;
  static BuildContext Function()? _getContext;
  static VoidCallback? _onForceLogout;
  static DateTime? _lastCheckTime;

  AgreementCheckService(this._apiClient);

  /// 启动后台检查（仅初始化，不启动轮询）
  static void startBackgroundCheck(
    PsygoApiClient apiClient,
    BuildContext Function() getContext,
    VoidCallback onForceLogout,
  ) {
    // 避免重复初始化
    if (_isInitialized) return;

    _apiClient_ = apiClient;
    _getContext = getContext;
    _onForceLogout = onForceLogout;
    _isInitialized = true;
  }

  /// 应用从后台恢复时调用
  static void onAppResumed() {
    _triggerCheckWithDebounce();
  }

  /// 带防抖的检查触发
  static void _triggerCheckWithDebounce() {
    final now = DateTime.now();
    if (_lastCheckTime != null &&
        now.difference(_lastCheckTime!) < _resumeDebounce) {
      return;
    }
    _lastCheckTime = now;
    _doBackgroundCheck();
  }

  /// 执行后台检查（静默）
  static Future<void> _doBackgroundCheck() async {
    if (_isDialogShowing) return;
    if (_apiClient_ == null || _getContext == null) return;

    final context = _getContext!();
    if (!context.mounted) return;

    // 检查当前 context 是否有 Navigator
    if (Navigator.maybeOf(context) == null) return;

    final service = AgreementCheckService(_apiClient_!);
    await service._silentCheck(context);
  }

  /// 停止后台检查
  static void stopBackgroundCheck() {
    _lastCheckTime = null;
    _apiClient_ = null;
    _getContext = null;
    _onForceLogout = null;
    _isInitialized = false;
  }

  /// 静默检查协议状态（后台恢复时调用）
  Future<void> _silentCheck(BuildContext context) async {
    try {
      final hasValidToken = await _apiClient.ensureValidToken();
      if (!hasValidToken) {
        debugPrint('[AgreementCheck] Skip check: no valid token');
        return;
      }
      final status = await _apiClient.getAgreementStatus();

      if (status.allAccepted) return;
      if (!context.mounted) return;

      // 用户未接受最新协议，显示提示并强制登出
      _showForceLogoutDialog(context);
    } catch (e) {
      // 静默失败，不处理（可能是网络问题）
      debugPrint('[AgreementCheck] Silent check failed: $e');
    }
  }

  /// 检查协议状态并处理（冷启动时调用）
  /// 返回 true 表示可以继续，false 表示需要强制登出
  Future<bool> checkAndHandle(BuildContext context) async {
    try {
      final hasValidToken = await _apiClient.ensureValidToken();
      if (!hasValidToken) {
        debugPrint('[AgreementCheck] Skip check: no valid token');
        return true;
      }
      final status = await _apiClient.getAgreementStatus();

      if (status.allAccepted) {
        return true;
      }

      if (!context.mounted) return false;

      // 用户未接受最新协议，显示提示并强制登出
      _showForceLogoutDialog(context);
      return false;
    } catch (e) {
      debugPrint('[AgreementCheck] Check failed: $e');
      // 检查失败时默认通过，避免误伤用户
      return true;
    }
  }

  /// 显示强制登出弹窗
  void _showForceLogoutDialog(BuildContext context) {
    if (_isDialogShowing) return;
    _isDialogShowing = true;

    final theme = Theme.of(context);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          Icons.policy_outlined,
          size: 48,
          color: theme.colorScheme.primary,
        ),
        title: const Text('协议更新'),
        content: const Text(
          '我们更新了用户协议或隐私政策，请重新登录并同意最新协议后继续使用。',
        ),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _isDialogShowing = false;
              // 触发强制登出
              _onForceLogout?.call();
            },
            child: const Text('重新登录'),
          ),
        ],
      ),
    ).then((_) {
      _isDialogShowing = false;
    });
  }
}
