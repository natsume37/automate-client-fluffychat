import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';

import 'package:psygo/backend/backend.dart';
import 'package:psygo/services/one_click_login.dart';
import 'package:psygo/core/config.dart';
import 'package:psygo/config/routes.dart';
import 'package:psygo/config/setting_keys.dart';
import 'package:psygo/config/themes.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/utils/platform_infos.dart';
import 'package:psygo/utils/post_login_navigation.dart';
import 'package:psygo/utils/permission_service.dart';
import 'package:psygo/utils/window_service.dart';
import 'package:psygo/widgets/app_lock.dart';
import 'package:psygo/widgets/theme_builder.dart';
import 'package:psygo/utils/app_update_service.dart';
import 'package:psygo/utils/agreement_check_service.dart';
import 'package:psygo/utils/client_manager.dart';
import '../utils/custom_scroll_behaviour.dart';
import 'matrix.dart';

class PsygoApp extends StatelessWidget {
  final Widget? testWidget;
  final List<Client> clients;
  final String? pincode;
  final SharedPreferences store;

  const PsygoApp({
    super.key,
    this.testWidget,
    required this.clients,
    required this.store,
    this.pincode,
  });

  /// getInitialLink may rereturn the value multiple times if this view is
  /// opened multiple times for example if the user logs out after they logged
  /// in with qr code or magic link.
  static bool gotInitialLink = false;

  // Router must be outside of build method so that hot reload does not reset
  // the current path.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static final GoRouter router = GoRouter(
    routes: AppRoutes.routes,
    debugLogDiagnostics: true,
    navigatorKey: navigatorKey,
  );

  @override
  Widget build(BuildContext context) {
    return ThemeBuilder(
      builder: (context, themeMode, primaryColor) => MaterialApp.router(
        title: AppSettings.applicationName.value,
        themeMode: themeMode,
        theme: FluffyThemes.buildTheme(context, Brightness.light, primaryColor),
        darkTheme:
            FluffyThemes.buildTheme(context, Brightness.dark, primaryColor),
        scrollBehavior: CustomScrollBehavior(),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        routerConfig: router,
        builder: (context, child) => ChangeNotifierProvider(
          create: (_) => PsygoAuthState()..load(),
          child: Builder(
            builder: (context) {
              final auth = context.read<PsygoAuthState>();
              return Provider<PsygoApiClient>(
                create: (_) => PsygoApiClient(auth),
                child: AppLockWidget(
                  pincode: pincode,
                  clients: clients,
                  child: Matrix(
                    clients: clients,
                    store: store,
                    child: _AutomateAuthGate(
                      clients: clients,
                      store: store,
                      child: testWidget ?? child,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Professional AuthGate with token refresh and direct one-click login
///
/// Flow:
/// 1. App launch -> check stored token
/// 2. Token valid -> proceed to main app
/// 3. Token expired + refresh token -> try refresh
/// 4. No valid token -> directly show Aliyun auth popup (no intermediate page)
/// 5. After login success -> login Matrix -> proceed to main app
class _AutomateAuthGate extends StatefulWidget {
  final Widget? child;
  final List<Client> clients;
  final SharedPreferences store;

  const _AutomateAuthGate({
    this.child,
    required this.clients,
    required this.store,
  });

  @override
  State<_AutomateAuthGate> createState() => _AutomateAuthGateState();
}

enum _AuthState {
  checking, // Checking stored token
  refreshing, // Refreshing expired token
  authenticating, // Performing one-click login
  authenticated, // Successfully authenticated
  needsLogin, // Needs login, show login page
  error, // Error occurred
}

class _AutomateAuthGateState extends State<_AutomateAuthGate>
    with WidgetsBindingObserver {
  _AuthState _state = _AuthState.checking;
  String? _errorMessage;
  bool _hasTriedAuth = false;
  bool _needsRetryAfterStaleCredentials = false;
  bool _hasRetriedMatrixLogin =
      false; // Track if we already retried Matrix login
  int _resumeRetryCount =
      0; // Track resume retry attempts to avoid infinite loops
  static const int _maxResumeRetries = 3; // Max retries on resume
  bool _authCheckInProgress = false;
  bool _authCheckQueued = false;
  static const Set<String> _oneClickFallbackCodes = {
    '600002', // Auth page failed to present
    '600004', // Operator config fetch failed
    '600005', // Device not secure
    '600007', // No SIM detected
    '600008', // Cellular network not available
    '600009', // Unknown operator
    '600010', // Unknown error
    '600011', // Get token failed
    '600012', // Pre-login failed
    '600013', // Operator maintenance (unavailable)
    '600014', // Operator maintenance (rate limit)
    '600015', // Token request timeout
    '600017', // App info decode failed
    '600021', // Carrier changed
    '600025', // Environment check failed
    '600026', // Pre-login called while auth page open
  };
  bool _blockedByForceUpdate = false; // Track if blocked by force update
  bool _isLoggingOut = false; // 防止登出过程中重复触发一键登录
  bool _pendingOneClickLogin = false; // 延迟触发一键登录（等待 app 回到前台）
  bool _forceManualLogin = false; // 一键登录不可用时，直接进入手动登录入口
  bool _hasResolvedPostLoginDestination = false;
  bool _isResolvingPostLoginDestination = false;

  // Sync error tracking
  StreamSubscription? _syncStatusSubscription;
  String? _syncMonitoringClientName;
  int _consecutiveSyncErrors = 0;
  static const int _maxConsecutiveSyncErrors = 5; // 连续5次同步失败后登出

  // 保存 auth 引用，避免在 dispose 中访问 context
  PsygoAuthState? _authState;

  // Aliyun SDK secret key
  // 通过 --dart-define=ALIYUN_SECRET_KEY=your-secret-key 指定
  static const _secretKey = String.fromEnvironment(
    'ALIYUN_SECRET_KEY',
    defaultValue: '',
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 取消同步状态监听
    _syncStatusSubscription?.cancel();
    _syncMonitoringClientName = null;
    // 移除认证状态监听（使用保存的引用，避免访问 context）
    _authState?.removeListener(_onAuthStateChanged);
    _authState = null;
    // 停止后台检查服务
    AppUpdateService.stopBackgroundCheck();
    AgreementCheckService.stopBackgroundCheck();
    super.dispose();
  }

  /// 认证状态变化回调
  void _onAuthStateChanged() {
    if (!mounted) return;

    final auth = context.read<PsygoAuthState>();
    debugPrint('[AuthGate] Auth state changed: isLoggedIn=${auth.isLoggedIn}');

    if (auth.isLoggedIn && _forceManualLogin) {
      _forceManualLogin = false;
    }

    // 登出时重置状态并清除 Matrix
    if (!auth.isLoggedIn && _state == _AuthState.authenticated) {
      debugPrint(
          '[AuthGate] User logged out via auth state change, clearing all auth state');

      // 取消同步状态监听
      _syncStatusSubscription?.cancel();
      _syncStatusSubscription = null;
      _syncMonitoringClientName = null;

      // 清除所有认证状态（包括 Matrix）并跳转到登录页
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _clearAllAuthStateAndRedirectToLogin();
      });
      return;
    }

    // 登录成功时更新状态
    if (auth.isLoggedIn && _state != _AuthState.authenticated) {
      // 检查 Matrix 是否也已登录
      try {
        final matrix = Matrix.of(context);
        Client? loggedInClient = matrix.clientOrNull;
        if (loggedInClient == null || !loggedInClient.isLogged()) {
          for (final client in matrix.widget.clients) {
            if (client.isLogged()) {
              loggedInClient = client;
              break;
            }
          }
        }
        if (loggedInClient != null && loggedInClient.isLogged()) {
          debugPrint(
              '[AuthGate] User logged in with Matrix, updating state to authenticated');
          matrix.setActiveClient(loggedInClient);
          setState(() => _state = _AuthState.authenticated);
          _startAgreementCheckService();
          // 启动同步状态监听，检测持续连接失败
          _startSyncStatusMonitoring(loggedInClient);
          unawaited(_ensurePostLoginDestination());
        } else {
          // Matrix 还没登录完成，稍后再检查
          debugPrint(
              '[AuthGate] Psygo logged in but Matrix not yet, will check again');
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) _onAuthStateChanged();
          });
        }
      } catch (e) {
        debugPrint('[AuthGate] Could not check Matrix state: $e');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 监听认证状态变化（保存引用以便在 dispose 中使用）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _authState = context.read<PsygoAuthState>();
      _authState?.addListener(_onAuthStateChanged);
    });

    // iOS FIX: Delay auth check to give system services time to initialize
    // On cold start, carrier/network services need time to become available
    // before Aliyun SDK can initialize properly
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Wait 1 second after first frame to let iOS services initialize
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) {
          _checkAuthStateSafe();
        }
      });
    });
  }

  /// 应用启动时初始化更新检查
  Future<void> _initUpdateCheck() async {
    try {
      final api = context.read<PsygoApiClient>();

      // 获取可用的 context（优先使用 Navigator context，否则使用当前 widget context）
      BuildContext? getNavigatorContext() {
        return PsygoApp.navigatorKey.currentContext;
      }

      // 获取最佳可用 context
      // Navigator context 可能在登录完成后才可用，所以先用当前 context
      BuildContext getAvailableContext() {
        return getNavigatorContext() ?? context;
      }

      // 启动后台检查服务
      AppUpdateService.startBackgroundCheck(api, getAvailableContext);

      // 不再等待 Navigator，直接使用当前 context 执行检查
      // 当前 context 在 MaterialApp.builder 内，可以正常显示 Dialog
      if (!mounted) return;

      // 立即执行一次检查
      final updateService = AppUpdateService(api);
      final canContinue = await updateService.checkAndPrompt(context);

      // 处理强制更新阻止
      if (!canContinue && mounted) {
        setState(() {
          _blockedByForceUpdate = true;
        });
      }
    } catch (e) {
      debugPrint('[AppUpdate] Init update check failed: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // 当应用从后台恢复时
    if (state == AppLifecycleState.resumed) {
      debugPrint(
          '[AuthGate] App resumed from background, state=$_state, pendingOneClickLogin=$_pendingOneClickLogin, hasTriedAuth=$_hasTriedAuth');

      // 应用恢复时检查更新（先检查 App 更新，再检查协议）
      AppUpdateService.onAppResumed();
      // 协议检查（仅已登录用户）
      if (_state == _AuthState.authenticated) {
        AgreementCheckService.onAppResumed();
      }

      if (_forceManualLogin) {
        debugPrint(
            '[AuthGate] Manual login mode active, skipping auto one-click retry');
        return;
      }

      // 如果有延迟的一键登录请求，现在执行
      if (_pendingOneClickLogin) {
        debugPrint(
            '[AuthGate] Executing pending one-click login after app resumed');
        _pendingOneClickLogin = false;
        // 稍微延迟一下确保 app 完全恢复
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _checkAuthStateSafe();
        });
        return;
      }

      // 如果在 checking 状态且已尝试过登录，说明一键登录授权页可能被系统关闭了
      // 需要重新触发登录流程
      if (_state == _AuthState.checking &&
          _hasTriedAuth &&
          PlatformInfos.isMobile) {
        debugPrint(
            '[AuthGate] Auth page might have been dismissed, retrying one-click login');
        setState(() {
          _hasTriedAuth = false;
        });
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _checkAuthStateSafe();
        });
        return;
      }

      // iOS FIX: Handle permission approval during auth check
      // When user slowly approves network permissions, SDK initialization may timeout
      // Auto-retry when app resumes after permission approval (with retry limit)
      if (_state == _AuthState.error && _resumeRetryCount < _maxResumeRetries) {
        debugPrint(
            '[AuthGate] In error state, retrying auth check after resume (attempt ${_resumeRetryCount + 1}/$_maxResumeRetries)');
        _resumeRetryCount++;

        setState(() {
          _hasTriedAuth = false;
          _hasRetriedMatrixLogin = false;
          _state = _AuthState.checking;
        });

        // Wait a bit for network to be fully ready
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) _checkAuthStateSafe();
        });
      } else if (_resumeRetryCount >= _maxResumeRetries &&
          _state == _AuthState.error) {
        debugPrint(
            '[AuthGate] Max resume retries reached, showing persistent error');
      }
    }
  }

  Future<void> _checkAuthStateSafe() async {
    if (_forceManualLogin) {
      debugPrint('[AuthGate] Manual login mode active, skipping auth check');
      return;
    }

    if (_authCheckInProgress) {
      _authCheckQueued = true;
      debugPrint(
          '[AuthGate] Auth check already in progress, queued one follow-up run');
      return;
    }

    _authCheckInProgress = true;
    try {
      await _checkAuthState();
    } catch (e, s) {
      debugPrint('[AuthGate] Unhandled error in auth check: $e');
      debugPrint('$s');
      if (!mounted) return;

      // If we still have retry attempts, stay in checking state (don't show error)
      // User will see loading screen instead of error flash
      if (_resumeRetryCount < _maxResumeRetries) {
        debugPrint(
            '[AuthGate] Error occurred but retries available, staying in checking state');
        // Keep state as checking, will be retried on next resume
        return;
      }

      // No more retries, show error
      setState(() {
        _state = _AuthState.error;
        _errorMessage = L10n.of(context).authStateCheckFailed;
      });
    } finally {
      _authCheckInProgress = false;
      final shouldRunQueuedCheck = _authCheckQueued && mounted;
      _authCheckQueued = false;
      if (shouldRunQueuedCheck) {
        Future.microtask(() {
          if (mounted) {
            _checkAuthStateSafe();
          }
        });
      }
    }
  }

  Future<void> _checkAuthState() async {
    if (_forceManualLogin) {
      debugPrint('[AuthGate] Manual login mode active, skipping auth check');
      return;
    }

    final auth = context.read<PsygoAuthState>();
    final api = context.read<PsygoApiClient>();

    // Ensure auth state is loaded from storage before checking
    // This is critical because PsygoAuthState()..load() in Provider.create
    // does not wait for load() to complete (cascade operator returns immediately)
    await auth.load();

    debugPrint('[AuthGate] Checking auth state...');

    // 在检查登录状态之前先检查更新（只在首次检查时执行）
    if (!_hasTriedAuth) {
      await _initUpdateCheck();
      if (_blockedByForceUpdate) return; // 被强制更新阻止，不继续
    }

    // iOS CRITICAL FIX: Handle retry after stale credentials detected
    if (_needsRetryAfterStaleCredentials) {
      debugPrint(
          '[AuthGate] Retrying after stale credentials, directly triggering one-click login...');
      _needsRetryAfterStaleCredentials = false;

      // On mobile only, directly trigger one-click login
      if (PlatformInfos.isMobile && !_hasTriedAuth) {
        _hasTriedAuth = true;
        await _performDirectLogin();
      } else {
        _redirectToLoginPage();
      }
      return;
    }

    // 1. Check if already logged in with valid token
    if (auth.isLoggedIn && auth.hasValidToken) {
      debugPrint('[AuthGate] Automate token is valid');

      // Check if Matrix is already logged in
      final matrix = Matrix.of(context);
      final isMatrixLoggedIn = matrix.widget.clients.any((c) => c.isLogged());

      if (isMatrixLoggedIn) {
        // Both automate and Matrix are logged in, proceed to app
        debugPrint('[AuthGate] Matrix also logged in, proceeding to app');
        // PC端：切换到主窗口模式
        if (PlatformInfos.isDesktop) {
          await WindowService.switchToMainWindow();
        }
        setState(() => _state = _AuthState.authenticated);

        // 启动同步状态监听，检测持续连接失败
        _startSyncStatusMonitoring(matrix.client);
        if (PlatformInfos.isMobile) {
          unawaited(matrix.ensureAliyunPushRegistered(matrix.client));
        }

        // 启动协议检查后台服务
        _startAgreementCheckService();
        await _ensurePostLoginDestination();
        return;
      }

      // Automate logged in but Matrix not logged in - login Matrix
      debugPrint('[AuthGate] Automate logged in, logging into Matrix');
      await _loginMatrixAndProceed();
      return;
    }

    // 2. Token expired but have refresh token -> try to refresh
    if (auth.isLoggedIn && auth.refreshToken != null) {
      debugPrint('[AuthGate] Token expired, attempting refresh...');
      setState(() => _state = _AuthState.refreshing);

      final success = await api.refreshAccessToken();
      if (success) {
        debugPrint('[AuthGate] Token refreshed successfully');
        // PC端：切换到主窗口模式
        if (PlatformInfos.isDesktop) {
          await WindowService.switchToMainWindow();
        }
        final matrix = Matrix.of(context);
        final isMatrixLoggedIn = matrix.widget.clients.any((c) => c.isLogged());

        if (isMatrixLoggedIn) {
          setState(() => _state = _AuthState.authenticated);
          _startAgreementCheckService();
          _startSyncStatusMonitoring(matrix.client);
          if (PlatformInfos.isMobile) {
            unawaited(matrix.ensureAliyunPushRegistered(matrix.client));
          }
          await _ensurePostLoginDestination();
          return;
        }

        await _loginMatrixAndProceed();
        return;
      }
      debugPrint('[AuthGate] Token refresh failed');
    }

    // 3. No valid token -> need to authenticate
    debugPrint('[AuthGate] No valid token, need authentication');

    // 如果 Matrix 还在登录状态，先登出（避免无效的同步循环）
    try {
      final matrix = Matrix.of(context);
      // 复制列表避免并发修改错误
      final clients = List.from(matrix.widget.clients);
      for (final client in clients) {
        if (client.isLogged()) {
          debugPrint('[AuthGate] Logging out stale Matrix client');
          try {
            // 先尝试正常登出
            await client.logout();
          } catch (e) {
            debugPrint('[AuthGate] Matrix logout error: $e');
            // 网络失败时强制清除本地状态
            try {
              await client.clear();
            } catch (clearError) {
              debugPrint('[AuthGate] Matrix clear error: $clearError');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[AuthGate] Could not access Matrix: $e');
    }

    // On web or desktop, redirect to login page (one-click login SDK not supported)
    // One-click login SDK only works on mobile (Android/iOS)
    if (kIsWeb || PlatformInfos.isDesktop) {
      _redirectToLoginPage();
      return;
    }

    // On mobile only, directly trigger one-click login
    if (!_hasTriedAuth) {
      _hasTriedAuth = true;
      await _performDirectLogin();
    } else {
      // Already tried once, show login page for manual retry
      _redirectToLoginPage();
    }
  }

  Future<void> _performDirectLogin() async {
    // 不设置 authenticating 状态，避免显示"正在登录"
    // SDK 授权页会直接弹出覆盖当前界面
    _errorMessage = null;

    try {
      debugPrint('[AuthGate] Starting one-click login...');

      // 先关闭可能存在的授权页，避免 "授权页已存在" 错误
      await OneClickLoginService.quitLoginPage();

      // Perform the complete one-click login flow
      final loginToken = await OneClickLoginService.performOneClickLogin(
        secretKey: _secretKey,
        timeout: 10000,
      );

      debugPrint('[AuthGate] Got token from Aliyun, calling backend...');

      final api = context.read<PsygoApiClient>();
      final authResponse = await api.oneClickLogin(loginToken);
      debugPrint(
          '[AuthGate] Backend oneClickLogin success, userId=${authResponse.userId}');

      if (!mounted) return;

      // CRITICAL iOS FIX: Change state BEFORE closing auth page to prevent auto-retry
      setState(() => _state = _AuthState.authenticating);

      await OneClickLoginService.quitLoginPage();
      await _loginMatrixAndProceed();
    } on SwitchLoginMethodException {
      // User clicked "其他方式登录" button, redirect to login page
      debugPrint('[AuthGate] User chose to switch login method');
      // SDK 已自动关闭授权页，无需手动关闭
      _forceManualLogin = true;
      setState(() => _state = _AuthState.needsLogin);
      _redirectToManualLoginPage();
      return;
    } catch (e) {
      debugPrint('[AuthGate] One-click login error: $e');
      // 出错时关闭授权页
      await OneClickLoginService.quitLoginPage();

      // Check if user cancelled
      final errorStr = e.toString();
      if (PlatformInfos.isMobile) {
        debugPrint(
            '[AuthGate] One-click login failed on mobile, redirecting to manual login');
        _forceManualLogin = true;
        setState(() => _state = _AuthState.needsLogin);
        _redirectToManualLoginPage();
        return;
      }

      if (_shouldFallbackToManualLogin(errorStr)) {
        debugPrint(
            '[AuthGate] One-click login unavailable, redirecting to manual login');
        _forceManualLogin = true;
        setState(() => _state = _AuthState.needsLogin);
        _redirectToManualLoginPage();
        return;
      }

      if (errorStr.contains('USER_CANCEL') || errorStr.contains('用户取消')) {
        _redirectToLoginPage();
        return;
      }

      // If we still have retry attempts, stay in checking state (don't show error)
      // Will be automatically retried when app resumes
      if (_resumeRetryCount < _maxResumeRetries) {
        debugPrint(
            '[AuthGate] Login error but retries available ($_resumeRetryCount/$_maxResumeRetries), staying in checking state');
        // Keep state as checking, will be retried
        return;
      }

      // No more retries, show error
      setState(() {
        _state = _AuthState.error;
        _errorMessage = _parseErrorMessage(errorStr);
      });
    }
  }

  bool _shouldFallbackToManualLogin(String errorStr) {
    if (errorStr.contains('预取号失败')) {
      return true;
    }
    if (errorStr.contains('蜂窝网络未开启') ||
        errorStr.contains('未检测到sim卡') ||
        errorStr.contains('未检测到SIM卡') ||
        errorStr.contains('网络环境不支持')) {
      return true;
    }
    final codeMatch = RegExp(r'code:\s*(\d{6})').firstMatch(errorStr);
    final code = codeMatch?.group(1);
    return code != null && _oneClickFallbackCodes.contains(code);
  }

  String _parseErrorMessage(String error) {
    final l10n = L10n.of(context);
    // 网络权限被拒绝的常见错误
    if (error.contains('网络不可用') ||
        error.contains('Network is unreachable') ||
        error.contains('网络连接失败') ||
        error.contains('Connection failed')) {
      return l10n.authOneClickNetworkErrorHint;
    }
    if (error.contains('预取号失败')) {
      return l10n.authOneClickUnsupportedNetworkHint;
    }
    if (error.contains('SDK初始化失败')) {
      return l10n.authOneClickInitFailedHint;
    }
    return l10n.authLoginFailedRetryLater;
  }

  Future<void> _ensurePostLoginDestination() async {
    if (_hasResolvedPostLoginDestination || _isResolvingPostLoginDestination) {
      return;
    }
    _isResolvingPostLoginDestination = true;
    try {
      final destination = await resolvePostLoginDestination();
      if (!mounted) return;
      final router = PsygoApp.router;
      final currentPath = router.routeInformationProvider.value.uri.path;
      debugPrint(
        '[AuthGate] Post-login destination resolved: $destination, current: $currentPath',
      );
      if (currentPath != destination) {
        router.go(destination);
      }
      _hasResolvedPostLoginDestination = true;
    } catch (e) {
      debugPrint('[AuthGate] Failed to resolve post-login destination: $e');
    } finally {
      _isResolvingPostLoginDestination = false;
    }
  }

  Future<void> _loginMatrixAndProceed() async {
    final auth = context.read<PsygoAuthState>();
    final matrixAccessToken = auth.matrixAccessToken;
    final matrixUserId = auth.matrixUserId;
    final matrixDeviceId = auth.matrixDeviceId;

    if (matrixAccessToken == null || matrixUserId == null) {
      debugPrint('[AuthGate] Missing Matrix credentials for Matrix login');
      setState(() {
        _state = _AuthState.error;
        _errorMessage = L10n.of(context).authMatrixCredentialsMissing;
      });
      return;
    }

    debugPrint(
        '[AuthGate] Matrix credentials: userId=$matrixUserId, deviceId=$matrixDeviceId');

    try {
      final matrix = Matrix.of(context);

      // 使用用户专属 client。登录链路优先复用内存对象，避免重复 initWithRestore。
      final client = await ClientManager.getOrCreateLoginClientForUser(
        matrixUserId,
        widget.store,
        inMemoryClients: widget.clients,
      );

      debugPrint('[AuthGate] Client database: ${client.database}');
      debugPrint('[AuthGate] Client name: ${client.clientName}');
      debugPrint('[AuthGate] Client isLogged: ${client.isLogged()}');
      debugPrint('[AuthGate] Client deviceID: ${client.deviceID}');

      final addedBeforeLogin = matrix.ensureClientRegistered(client);
      debugPrint(
        '[AuthGate] Client ${addedBeforeLogin ? 'added to' : 'already in'} clients list, length=${widget.clients.length}',
      );

      // Note: Encryption is disabled for this Matrix server
      // 检查是否需要重新登录：未登录 或 userID 不匹配（切换账号的情况）
      final needsLogin = !client.isLogged() || client.userID != matrixUserId;
      if (needsLogin) {
        // 如果已登录但 userID 不匹配，先退出旧账号
        if (client.isLogged() && client.userID != matrixUserId) {
          try {
            await client.logout();
          } catch (_) {}
        }

        // Clear old data before login (仅清除内存状态，数据库保留)
        await client.clear();

        // 使用固定 homeserver，直接 init，避免额外探测请求带来的登录卡顿。
        final homeserverUrl = Uri.parse(PsygoConfig.matrixHomeserver);
        debugPrint('[AuthGate] Setting homeserver: $homeserverUrl');

        debugPrint(
            '[AuthGate] Attempting Matrix login: matrixUserId=$matrixUserId');

        // Use access_token directly
        await client.init(
          newToken: matrixAccessToken,
          newUserID: matrixUserId,
          newHomeserver: homeserverUrl,
          newDeviceName: PlatformInfos.clientName,
          // Do not block UI on first sync/load; background sync continues after init.
          waitForFirstSync: false,
          waitUntilLoadCompletedLoaded: false,
        );
        debugPrint(
            '[AuthGate] Matrix login success, deviceID=${client.deviceID}');

        // CRITICAL: Ensure client is in the clients list and subscriptions are active
        // client.init(newToken:...) may not trigger onLoginStateChanged event.
        final addedAfterLogin = matrix.ensureClientRegistered(client);
        debugPrint(
          '[AuthGate] Client ${addedAfterLogin ? 'added to' : 'already in'} clients list, length=${widget.clients.length}',
        );

        // 设置当前 client 为活跃客户端
        matrix.setActiveClient(client);
        debugPrint('[AuthGate] Set active client to ${client.clientName}');

        // PC端：切换到主窗口模式
        if (PlatformInfos.isDesktop) {
          await WindowService.switchToMainWindow();
        }

        setState(() => _state = _AuthState.authenticated);

        // 启动协议检查后台服务
        _startAgreementCheckService();

        // 启动同步状态监听，检测持续连接失败
        _startSyncStatusMonitoring(client);
        if (PlatformInfos.isMobile) {
          unawaited(matrix.ensureAliyunPushRegistered(client));
        }

        // Navigate to post-login destination after successful login.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_ensurePostLoginDestination());
        });

        if (PlatformInfos.isMobile) {
          Future.delayed(const Duration(seconds: 1), () {
            PermissionService.instance.requestPushPermissions();
          });
        }
        return;
      }

      // Client is already logged in with correct userID, just proceed
      debugPrint(
          '[AuthGate] Client already logged in with correct userID=${client.userID}, deviceID=${client.deviceID}');

      final addedAlreadyLogged = matrix.ensureClientRegistered(client);
      debugPrint(
        '[AuthGate] Client ${addedAlreadyLogged ? 'added to' : 'already in'} clients list (already logged in), length=${widget.clients.length}',
      );

      // 设置当前 client 为活跃客户端
      matrix.setActiveClient(client);
      debugPrint('[AuthGate] Set active client to ${client.clientName}');

      // PC端：切换到主窗口模式
      if (PlatformInfos.isDesktop) {
        await WindowService.switchToMainWindow();
      }

      setState(() => _state = _AuthState.authenticated);

      // 启动协议检查后台服务
      _startAgreementCheckService();

      // 启动同步状态监听，检测持续连接失败
      _startSyncStatusMonitoring(client);
      if (PlatformInfos.isMobile) {
        unawaited(matrix.ensureAliyunPushRegistered(client));
      }

      // Navigate to post-login destination if not already there.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_ensurePostLoginDestination());
      });

      if (PlatformInfos.isMobile) {
        Future.delayed(const Duration(seconds: 1), () {
          PermissionService.instance.requestPushPermissions();
        });
      }
    } catch (e, stackTrace) {
      debugPrint('[AuthGate] Matrix login failed: $e');
      debugPrint('[AuthGate] Stack trace: $stackTrace');

      final errorStr = e.toString();
      final isInvalidToken = errorStr.contains('M_UNKNOWN_TOKEN') ||
          errorStr.contains('Invalid access token');

      // Token 失效：清除所有状态并跳转到登录页
      if (isInvalidToken) {
        debugPrint(
            '[AuthGate] Matrix token invalid, clearing all auth state and redirecting to login...');
        await _clearAllAuthStateAndRedirectToLogin();
        return;
      }

      // 网络/加密错误：显示错误信息
      if (errorStr.contains('Upload key failed') ||
          errorStr.contains('Connection refused') ||
          errorStr.contains('SocketException')) {
        debugPrint('[AuthGate] Matrix encryption/network error');

        setState(() {
          _state = _AuthState.error;
          _errorMessage = L10n.of(context).authChatServiceUnavailable;
        });
        return;
      }

      // 其他错误：尝试重试一次
      if (!_hasRetriedMatrixLogin) {
        debugPrint('[AuthGate] Matrix login failed, retrying once...');
        _hasRetriedMatrixLogin = true;

        final auth = context.read<PsygoAuthState>();
        await auth.markLoggedOut();

        if (!mounted) return;

        setState(() {
          _state = _AuthState.checking;
          _hasTriedAuth = false;
        });

        await _checkAuthState();
        return;
      }

      // 重试后仍然失败：清除状态并跳转登录
      debugPrint(
          '[AuthGate] Matrix login failed after retry, clearing auth and redirecting to login...');
      await _clearAllAuthStateAndRedirectToLogin();
    }
  }

  // 路由重定向重试计数，防止无限递归
  int _redirectRetryCount = 0;
  static const int _maxRedirectRetries = 5;

  void _redirectToLoginPage() {
    // Mobile only: Stay in AuthGate, don't redirect to /login-signup
    // AuthGate will handle one-click login automatically
    if (PlatformInfos.isMobile) {
      setState(() => _state = _AuthState.error);
      return;
    }

    // Web and Desktop: redirect to /login-signup for manual login options
    _hasResolvedPostLoginDestination = false;
    _isResolvingPostLoginDestination = false;
    setState(() => _state = _AuthState.needsLogin);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final navKey = PsygoApp.router.routerDelegate.navigatorKey;
      final ctx = navKey.currentContext;
      if (ctx == null) {
        // 防止无限递归：限制重试次数
        _redirectRetryCount++;
        if (_redirectRetryCount >= _maxRedirectRetries) {
          debugPrint('[AuthGate] Max redirect retries reached, giving up');
          _redirectRetryCount = 0;
          return;
        }
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _redirectToLoginPage());
        return;
      }

      // 重置重试计数
      _redirectRetryCount = 0;

      final router = GoRouter.of(ctx);
      if (router.routerDelegate.currentConfiguration.fullPath !=
          '/login-signup') {
        router.go('/login-signup');
      }
    });
  }

  void _redirectToManualLoginPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (PsygoApp.router.routerDelegate.currentConfiguration.fullPath !=
          '/login-signup') {
        PsygoApp.router.go('/login-signup');
      }
    });
  }

  /// 启动协议检查后台服务
  Future<void> _startAgreementCheckService() async {
    final api = context.read<PsygoApiClient>();

    BuildContext? getNavigatorContext() {
      return PsygoApp.navigatorKey.currentContext;
    }

    AgreementCheckService.startBackgroundCheck(
      api,
      () => getNavigatorContext() ?? context,
      _forceLogout,
    );

    // 等待 Navigator 可用
    var waitAttempts = 0;
    const maxWaitAttempts = 10;
    BuildContext? navContext;
    while (waitAttempts < maxWaitAttempts) {
      navContext = getNavigatorContext();
      if (navContext != null) break;
      await Future.delayed(const Duration(milliseconds: 300));
      waitAttempts++;
      if (!mounted) return;
    }

    if (navContext == null) return;

    // 立即执行一次检查
    final agreementService = AgreementCheckService(api);
    await agreementService.checkAndHandle(navContext);
  }

  /// 启动同步状态监听，检测持续连接失败
  void _startSyncStatusMonitoring(Client client) {
    final targetClientName = client.clientName;

    // 如果已经在监听同一个 client，不要重复启动
    if (_syncStatusSubscription != null &&
        _syncMonitoringClientName == targetClientName) {
      debugPrint(
          '[AuthGate] Sync status monitoring already active for $targetClientName, skipping');
      return;
    }

    if (_syncStatusSubscription != null) {
      debugPrint(
          '[AuthGate] Sync monitor client changed, restarting: $_syncMonitoringClientName -> $targetClientName');
      _syncStatusSubscription?.cancel();
      _syncStatusSubscription = null;
    }

    debugPrint('[AuthGate] Starting sync status monitoring');
    _consecutiveSyncErrors = 0;
    _syncMonitoringClientName = targetClientName;

    _syncStatusSubscription = client.onSyncStatus.stream.listen((status) {
      if (!mounted) return;

      if (status.status == SyncStatus.error) {
        _consecutiveSyncErrors++;

        // 获取错误信息：SdkError 有 exception 属性
        final error = status.error;
        final errorStr =
            (error?.exception?.toString() ?? error?.toString() ?? '')
                .toLowerCase();
        debugPrint('[AuthGate] Sync error #$_consecutiveSyncErrors: $errorStr');

        // 连续同步失败达到阈值时登出
        // 包括：网络错误、连接超时、HTTP错误等
        if (_consecutiveSyncErrors >= _maxConsecutiveSyncErrors) {
          debugPrint(
              '[AuthGate] Max consecutive sync errors reached ($_consecutiveSyncErrors), logging out user');
          _handlePersistentConnectionFailure();
        }
      } else if (status.status == SyncStatus.finished) {
        // 只有 finished 才表示同步真正完成，重置计数器
        if (_consecutiveSyncErrors > 0) {
          debugPrint('[AuthGate] Sync recovered, resetting error counter');
          _consecutiveSyncErrors = 0;
        }
      }
    });
  }

  /// 处理持续连接失败：清除登录状态并跳转到登录页
  Future<void> _handlePersistentConnectionFailure() async {
    debugPrint('[AuthGate] Handling persistent connection failure');

    // 取消同步监听避免重复触发
    _syncStatusSubscription?.cancel();
    _syncStatusSubscription = null;
    _syncMonitoringClientName = null;

    // 显示提示
    if (mounted) {
      final navContext = PsygoApp.navigatorKey.currentContext ?? context;
      ScaffoldMessenger.of(navContext).showSnackBar(
        SnackBar(
          content: Text(L10n.of(navContext).authPersistentNetworkFailure),
          duration: Duration(seconds: 3),
        ),
      );
    }

    // 清除所有认证状态并跳转到登录页
    await _clearAllAuthStateAndRedirectToLogin();
  }

  /// 强制登出（协议未接受时调用）
  Future<void> _forceLogout() async {
    // 防止重复调用
    if (_isLoggingOut) {
      debugPrint('[AuthGate] Already logging out, skipping duplicate call');
      return;
    }
    _isLoggingOut = true;

    debugPrint('[AuthGate] Force logout triggered - agreement not accepted');

    // 停止后台检查服务
    AgreementCheckService.stopBackgroundCheck();
    _syncStatusSubscription?.cancel();
    _syncStatusSubscription = null;
    _syncMonitoringClientName = null;

    // 清除 Automate 认证状态
    final auth = context.read<PsygoAuthState>();
    await auth.markLoggedOut();

    // 退出所有 Matrix 客户端
    // 注意：client.logout() 会触发 onLoginStateChanged，自动执行：
    // - 清除图片缓存 (MxcImage.clearCache)
    // - 清除用户缓存 (DesktopLayout.clearUserCache)
    // - 从 store 移除 clientName
    final matrix = Matrix.of(context);
    final clients = List.from(matrix.widget.clients);
    for (final client in clients) {
      try {
        if (client.isLogged()) {
          await client.logout();
          debugPrint('[AuthGate] Matrix client logged out');
        }
      } catch (e) {
        debugPrint('[AuthGate] Matrix client logout error: $e');
        // 网络失败时强制清除本地状态
        try {
          await client.clear();
          debugPrint('[AuthGate] Matrix client local state cleared');
        } catch (clearError) {
          debugPrint('[AuthGate] Matrix client clear error: $clearError');
        }
      }
    }

    if (!mounted) {
      _isLoggingOut = false;
      return;
    }

    // PC端：切换回登录小窗口
    if (PlatformInfos.isDesktop) {
      await WindowService.switchToLoginWindow();
    }

    // 重置 AuthGate 状态
    _hasResolvedPostLoginDestination = false;
    _isResolvingPostLoginDestination = false;
    setState(() {
      _state = _AuthState.checking;
      _hasTriedAuth = false; // 允许一键登录重新触发
      _hasRetriedMatrixLogin = false;
      _resumeRetryCount = 0;
    });

    // 移动端：设置延迟登录标志，等待 app 回到前台后再触发一键登录
    if (PlatformInfos.isMobile) {
      debugPrint(
          '[AuthGate] Force logout complete, setting pending one-click login flag');
      _pendingOneClickLogin = true;
      // 如果 app 已经在前台，立即触发
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        debugPrint(
            '[AuthGate] App is in foreground, triggering one-click login immediately');
        _pendingOneClickLogin = false;
        await _checkAuthStateSafe();
      }
    } else {
      debugPrint('[AuthGate] Force logout complete, redirecting to login page');
      PsygoApp.router.go('/login-signup');
    }

    _isLoggingOut = false;
  }

  /// 清除所有认证状态并跳转到登录页（Token 失效时调用）
  Future<void> _clearAllAuthStateAndRedirectToLogin() async {
    // 防止重复调用
    if (_isLoggingOut) {
      debugPrint('[AuthGate] Already logging out, skipping duplicate call');
      return;
    }
    _isLoggingOut = true;

    debugPrint(
        '[AuthGate] Clearing all auth state and redirecting to login...');

    // 停止后台检查服务
    AgreementCheckService.stopBackgroundCheck();
    _syncStatusSubscription?.cancel();
    _syncStatusSubscription = null;
    _syncMonitoringClientName = null;

    // 清除 Automate 认证状态
    final auth = context.read<PsygoAuthState>();
    await auth.markLoggedOut();

    // 退出所有 Matrix 客户端
    // 注意：client.logout() 会触发 onLoginStateChanged，自动执行：
    // - 清除图片缓存 (MxcImage.clearCache)
    // - 清除用户缓存 (DesktopLayout.clearUserCache)
    // - 从 store 移除 clientName
    try {
      final matrix = Matrix.of(context);
      final clients = List.from(matrix.widget.clients);
      for (final client in clients) {
        if (client.isLogged()) {
          try {
            await client.logout();
            debugPrint('[AuthGate] Matrix client logged out');
          } catch (e) {
            debugPrint('[AuthGate] Matrix logout error: $e');
            // 网络失败时强制清除本地状态
            try {
              await client.clear();
              debugPrint('[AuthGate] Matrix client local state cleared');
            } catch (clearError) {
              debugPrint('[AuthGate] Matrix client clear error: $clearError');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[AuthGate] Could not access Matrix: $e');
    }

    if (!mounted) {
      _isLoggingOut = false;
      return;
    }

    // PC端：切换到登录小窗口
    if (PlatformInfos.isDesktop) {
      await WindowService.switchToLoginWindow();
    }

    // 重置 AuthGate 状态
    _hasResolvedPostLoginDestination = false;
    _isResolvingPostLoginDestination = false;
    setState(() {
      // PC端/Web端：设置为 needsLogin，显示登录页面
      // 移动端：设置为 checking，等待一键登录
      _state =
          PlatformInfos.isMobile ? _AuthState.checking : _AuthState.needsLogin;
      _hasTriedAuth = false;
      _hasRetriedMatrixLogin = false;
      _resumeRetryCount = 0;
    });

    // 移动端：设置延迟登录标志，等待 app 回到前台后再触发一键登录
    // 这是因为在后台触发一键登录可能导致授权页无法正确显示
    // PC端/Web端：跳转到登录页
    if (PlatformInfos.isMobile) {
      debugPrint(
          '[AuthGate] Auth state cleared, setting pending one-click login flag');
      _pendingOneClickLogin = true;
      // 如果 app 已经在前台，立即触发
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        debugPrint(
            '[AuthGate] App is in foreground, triggering one-click login immediately');
        _pendingOneClickLogin = false;
        await _checkAuthStateSafe();
      }
    } else {
      debugPrint('[AuthGate] Auth state cleared, redirecting to login page');
      PsygoApp.router.go('/login-signup');
    }

    _isLoggingOut = false;
  }

  @override
  Widget build(BuildContext context) {
    // watch auth state 以便在状态变化时重建 UI
    // 实际的登出逻辑在 _onAuthStateChanged 中处理
    context.watch<PsygoAuthState>();
    final l10n = L10n.of(context);

    switch (_state) {
      case _AuthState.checking:
        // 显示加载界面，避免黑屏
        return _buildLoadingScreen(l10n.authCheckingLoginState);

      case _AuthState.refreshing:
        return _buildLoadingScreen(l10n.authValidatingLoginState);

      case _AuthState.authenticating:
        return _buildLoadingScreen(l10n.authSigningIn);

      case _AuthState.error:
        return _buildErrorScreen();

      case _AuthState.needsLogin:
        // 被强制更新阻止时显示提示
        if (_blockedByForceUpdate) {
          return _buildForceUpdateBlockedScreen();
        }
        // 移动端：需要登录时显示加载界面，等待一键登录 SDK 弹出
        // 这样可以避免短暂显示聊天列表后再弹出登录页
        if (PlatformInfos.isMobile) {
          if (_forceManualLogin) {
            return widget.child ?? const SizedBox.shrink();
          }
          return _buildLoadingScreen(l10n.authPreparingLogin);
        }
        // PC端/Web端：显示登录页面
        return widget.child ?? const SizedBox.shrink();

      case _AuthState.authenticated:
        // 被强制更新阻止时显示提示
        if (_blockedByForceUpdate) {
          return _buildForceUpdateBlockedScreen();
        }
        return widget.child ?? const SizedBox.shrink();
    }
  }

  /// 强制更新阻止界面
  Widget _buildForceUpdateBlockedScreen() {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.system_update_rounded,
                size: 64,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                l10n.authNeedUpdateTitle,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.authNeedUpdateMessage,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: () async {
                  // 重新触发更新检查
                  setState(() {
                    _blockedByForceUpdate = false;
                  });
                  await _initUpdateCheck();
                },
                child: Text(l10n.authCheckAgain),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingScreen(String message) {
    // PC端使用新的主题风格
    if (PlatformInfos.isDesktop) {
      final theme = Theme.of(context);
      final isDark = theme.brightness == Brightness.dark;

      return Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [
                      const Color(0xFF0A1628),
                      const Color(0xFF0D2233),
                      const Color(0xFF0F3D3E),
                    ]
                  : [
                      const Color(0xFFF0F4F8),
                      const Color(0xFFE8EFF5),
                      const Color(0xFFE0F2F1),
                    ],
            ),
          ),
          child: Center(
            child: Image.asset(
              isDark ? 'assets/logo_dark.png' : 'assets/logo_transparent.png',
              width: 100,
              height: 100,
            ),
          ),
        ),
      );
    }

    // 非PC端：只显示 logo，根据主题深浅色切换
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: Image.asset(
          isDark ? 'assets/logo_dark.png' : 'assets/logo.png',
          width: 100,
          height: 100,
        ),
      ),
    );
  }

  Widget _buildErrorScreen() {
    final isMatrixError = _errorMessage?.contains('Matrix') ?? false;
    final normalizedError = (_errorMessage ?? '').toLowerCase();
    final isNetworkError =
        normalizedError.contains('network') || normalizedError.contains('网络');
    final l10n = L10n.of(context);

    // PC端使用新的主题风格
    if (PlatformInfos.isDesktop) {
      final theme = Theme.of(context);
      final isDark = theme.brightness == Brightness.dark;
      final textColor = isDark ? Colors.white : const Color(0xFF1A2332);
      final subtitleColor = isDark
          ? Colors.white.withValues(alpha: 0.7)
          : const Color(0xFF666666);
      final accentColor =
          isDark ? const Color(0xFF00FF9F) : const Color(0xFF00A878);
      const errorColor = Color(0xFFFF6B6B);

      return Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [
                      const Color(0xFF0A1628),
                      const Color(0xFF0D2233),
                      const Color(0xFF0F3D3E),
                    ]
                  : [
                      const Color(0xFFF0F4F8),
                      const Color(0xFFE8EFF5),
                      const Color(0xFFE0F2F1),
                    ],
            ),
          ),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              margin: const EdgeInsets.all(32),
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.black.withValues(alpha: 0.08),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: isDark
                        ? Colors.black.withValues(alpha: 0.3)
                        : Colors.black.withValues(alpha: 0.08),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Error icon
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: errorColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(50),
                    ),
                    child: const Icon(
                      Icons.error_outline,
                      size: 48,
                      color: errorColor,
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Title
                  Text(
                    l10n.authLoginFailedTitle,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Error message
                  Text(
                    _errorMessage ?? l10n.authUnknownError,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: subtitleColor,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 28),
                  // Buttons
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      // Retry button
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: isDark
                                ? [
                                    const Color(0xFF00B386),
                                    const Color(0xFF00D4A1),
                                  ]
                                : [
                                    accentColor.withValues(alpha: 0.9),
                                    accentColor,
                                  ],
                          ),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: accentColor.withValues(alpha: 0.3),
                              blurRadius: 15,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              setState(() {
                                _state = _AuthState.checking;
                                _hasTriedAuth = false;
                                _hasRetriedMatrixLogin = false;
                                _resumeRetryCount = 0;
                              });
                              _checkAuthStateSafe();
                            },
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24, vertical: 14),
                              child: Text(
                                l10n.tryAgain,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (isMatrixError)
                        TextButton(
                          onPressed: () async {
                            final auth = context.read<PsygoAuthState>();
                            await auth.markLoggedOut();
                            setState(() {
                              _state = _AuthState.checking;
                              _hasTriedAuth = false;
                              _hasRetriedMatrixLogin = false;
                              _resumeRetryCount = 0;
                            });
                            _checkAuthStateSafe();
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: accentColor,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 14),
                          ),
                          child: Text(l10n.authReLogin),
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

    // 非PC端保持原样
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 24),
              Text(
                l10n.authLoginFailedTitle,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 12),
              Text(
                _errorMessage ?? l10n.authUnknownError,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 32),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _state = _AuthState.checking;
                        _hasTriedAuth = false;
                        _hasRetriedMatrixLogin = false;
                        _resumeRetryCount = 0; // Reset retry counter
                      });
                      _checkAuthStateSafe();
                    },
                    child: Text(l10n.tryAgain),
                  ),
                  if (isNetworkError) ...[
                    FilledButton.icon(
                      onPressed: () async {
                        await PermissionService.instance.openSettings();
                      },
                      icon: const Icon(Icons.settings, size: 18),
                      label: Text(l10n.authOpenSettings),
                    ),
                  ],
                  if (isMatrixError) ...[
                    FilledButton(
                      onPressed: () async {
                        // Clear all credentials and force re-login
                        final auth = context.read<PsygoAuthState>();
                        await auth.markLoggedOut();

                        setState(() {
                          _state = _AuthState.checking;
                          _hasTriedAuth = false;
                          _hasRetriedMatrixLogin = false;
                          _resumeRetryCount = 0; // Reset retry counter
                        });
                        _checkAuthStateSafe();
                      },
                      child: Text(l10n.authReLogin),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
