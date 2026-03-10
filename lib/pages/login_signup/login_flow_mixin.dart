/// 登录流程公共逻辑 Mixin
/// 一键登录和验证码登录共用：Matrix 登录、登录后跳转
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:psygo/widgets/matrix.dart';
import 'package:psygo/widgets/fluffy_chat_app.dart';
import 'package:psygo/backend/backend.dart';
import 'package:psygo/core/config.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/utils/client_manager.dart';
import 'package:psygo/utils/localized_exception_extension.dart';
import 'package:psygo/utils/platform_infos.dart';
import 'package:psygo/utils/permission_service.dart';
import 'package:psygo/utils/post_login_navigation.dart';
import 'package:psygo/utils/window_service.dart';

/// 登录流程公共逻辑
/// 使用方式：class MyController extends State<MyWidget> with LoginFlowMixin
mixin LoginFlowMixin<T extends StatefulWidget> on State<T> {
  /// 子类必须提供 backend 实例
  PsygoApiClient get backend;

  /// 子类必须提供设置错误信息的方法
  void setLoginError(String? error);

  /// 子类必须提供设置 loading 状态的方法
  void setLoading(bool loading);

  /// 处理登录成功后的跳转逻辑
  /// [authResponse] - 登录成功后的响应
  /// 返回 true 表示成功，false 表示出错
  Future<bool> handlePostLogin(AuthResponse authResponse) async {
    if (!mounted) return false;

    debugPrint('=== 登录成功，尝试登录 Matrix ===');
    return await loginMatrixAndRedirect();
  }

  /// 登录 Matrix 并跳转到主页
  Future<bool> loginMatrixAndRedirect() async {
    final matrixAccessToken = backend.auth.matrixAccessToken;
    final matrixUserId = backend.auth.matrixUserId;

    if (matrixAccessToken == null || matrixUserId == null) {
      debugPrint('Matrix access token 缺失，无法登录 Matrix');
      // 清除登录状态
      await _clearAuthState();
      if (mounted) {
        setLoginError(L10n.of(context).authMatrixCredentialsMissing);
        setLoading(false);
      }
      return false;
    }

    try {
      final matrix = Matrix.of(context);
      final store = await SharedPreferences.getInstance();

      // 使用用户专属 client。登录链路优先复用内存对象，避免重复 initWithRestore。
      final client = await ClientManager.getOrCreateLoginClientForUser(
        matrixUserId,
        store,
        inMemoryClients: matrix.widget.clients,
      );

      // 确保 client 在 clients 列表中
      if (!matrix.widget.clients.contains(client)) {
        matrix.widget.clients.add(client);
      }

      // 检查是否需要重新登录：未登录 或 userID 不匹配（切换账号的情况）
      final needsLogin = !client.isLogged() || client.userID != matrixUserId;
      if (!needsLogin) {
        // 已登录且 userID 匹配，直接使用
        matrix.setActiveClient(client);
        if (PlatformInfos.isDesktop) {
          await WindowService.switchToMainWindow();
        }
        final destination = await resolvePostLoginDestination();
        PsygoApp.router.go(destination);
        return true;
      }

      // 如果已登录但 userID 不匹配，先退出旧账号
      if (client.isLogged() && client.userID != matrixUserId) {
        try {
          await client.logout();
        } catch (_) {}
      }

      // 清除旧内存状态
      await client.clear();

      // 使用固定 homeserver，直接 init，避免额外探测请求带来的登录卡顿。
      final homeserverUrl = Uri.parse(PsygoConfig.matrixHomeserver);

      // 使用后端返回的 access_token 直接初始化，无需密码登录
      await client.init(
        newToken: matrixAccessToken,
        newUserID: matrixUserId,
        newHomeserver: homeserverUrl,
        newDeviceName: PlatformInfos.clientName,
        // Do not block UI on first sync/load; background sync continues after init.
        waitForFirstSync: false,
        waitUntilLoadCompletedLoaded: false,
      );
      debugPrint('Matrix 登录成功');

      // 设置当前客户端为活跃客户端（确保侧边栏显示正确的头像）
      matrix.setActiveClient(client);

      // PC端：切换到主窗口模式
      if (PlatformInfos.isDesktop) {
        await WindowService.switchToMainWindow();
      }

      // 登录成功后异步请求推送权限（不阻塞跳转）
      if (PlatformInfos.isMobile) {
        Future.delayed(const Duration(seconds: 1), () {
          PermissionService.instance.requestPushPermissions();
        });
      }

      // 导航到主页面（无员工时进入员工列表）
      final destination = await resolvePostLoginDestination();
      debugPrint('[LoginFlow] Matrix login success, navigating to $destination');
      PsygoApp.router.go(destination);
      return true;
    } catch (e, stackTrace) {
      debugPrint('Matrix 登录失败: $e');
      debugPrintStack(
        label: '[LoginFlow] Matrix login stack',
        stackTrace: stackTrace,
      );
      // 清除登录状态和 Matrix 客户端
      await _clearAuthState();
      if (mounted) {
        final message = e.toLocalizedString(
          context,
          ExceptionContext.matrixLogin,
        );
        setLoginError(message);
        setLoading(false);
      }
      return false;
    }
  }

  /// 清除登录状态（登录失败/退出登录时调用）
  /// 同时清除 Automate 认证状态和 Matrix 客户端状态
  Future<void> _clearAuthState() async {
    debugPrint('[LoginFlow] Clearing auth state...');

    // 1. 清除 Automate 认证状态
    await backend.auth.markLoggedOut();

    // 2. 退出 Matrix 客户端
    // 注意：client.logout() 会触发 onLoginStateChanged，自动执行：
    // - 清除图片缓存 (MxcImage.clearCache)
    // - 清除用户缓存 (DesktopLayout.clearUserCache)
    // - 从 store 移除 clientName
    if (mounted) {
      try {
        final matrix = Matrix.of(context);
        final clients = List.from(matrix.widget.clients);
        for (final client in clients) {
          try {
            if (client.isLogged()) {
              await client.logout();
              debugPrint('[LoginFlow] Matrix client logged out');
            }
          } catch (e) {
            debugPrint('[LoginFlow] Matrix client logout error: $e');
          }
        }
      } catch (e) {
        debugPrint('[LoginFlow] Could not access Matrix: $e');
      }
    }

    debugPrint('[LoginFlow] Auth state cleared');
  }
}
