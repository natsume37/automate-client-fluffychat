import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:psygo/config/app_config.dart';
import 'package:psygo/utils/client_manager.dart';
import 'package:psygo/utils/custom_http_client.dart';
import 'package:psygo/utils/notification_background_handler.dart';
import 'package:psygo/utils/platform_infos.dart';
import 'package:psygo/utils/window_service.dart';
import 'config/setting_keys.dart';
import 'widgets/fluffy_chat_app.dart';

ReceivePort? mainIsolateReceivePort;

void main() async {
  // 全局错误处理器：捕获并忽略第三方包的 setState 错误
  // swipe_to_action 包在 widget 销毁后仍会尝试 setState，这是包的 bug
  FlutterError.onError = (FlutterErrorDetails details) {
    final exception = details.exception;
    final stack = details.stack?.toString() ?? '';

    // 忽略 swipe_to_action 包的 setState 错误（静默处理）
    if (exception.toString().contains('Null check operator used on a null value') &&
        stack.contains('SwipeableState')) {
      return;
    }

    // 其他错误正常处理
    FlutterError.presentError(details);
  };

  if (PlatformInfos.isAndroid) {
    final port = mainIsolateReceivePort = ReceivePort();
    IsolateNameServer.removePortNameMapping(AppConfig.mainIsolatePortName);
    IsolateNameServer.registerPortWithName(
      port.sendPort,
      AppConfig.mainIsolatePortName,
    );
    await waitForPushIsolateDone();
  }

  // Our background push shared isolate accesses flutter-internal things very early in the startup proccess
  // To make sure that the parts of flutter needed are started up already, we need to ensure that the
  // widget bindings are initialized already.
  WidgetsFlutterBinding.ensureInitialized();
  CustomHttpClient.applyHttpOverrides();

  // PC 端窗口初始化
  if (PlatformInfos.isDesktop) {
    // [DEBUG] 清除登录状态代码 - 测试时启用
    // debugPrint('[DEBUG] Desktop: Clearing all login state...');
    // await const FlutterSecureStorage().deleteAll();
    // final debugPrefs = await SharedPreferences.getInstance();
    // await debugPrefs.clear();
    // // 清除 Matrix 数据库
    // final appSupportDir = await getApplicationSupportDirectory();
    // final dbFiles = appSupportDir.listSync().where((f) => f.path.endsWith('.sqlite'));
    // for (final dbFile in dbFiles) {
    //   debugPrint('[DEBUG] Deleting Matrix database: ${dbFile.path}');
    //   await File(dbFile.path).delete();
    // }
    // debugPrint('[DEBUG] Desktop: Login state cleared!');

    // 初始化窗口管理器 - 登录页面使用小窗口无边框样式
    await windowManager.ensureInitialized();

    // 检查是否已登录：通过 FlutterSecureStorage 检查 Psygo 认证 token
    // 使用 automate_primary_token 判断，而不是 Matrix 客户端列表
    // 因为用户可能收到验证码但未完成登录，此时 Matrix 客户端已创建但用户未真正登录
    const storage = FlutterSecureStorage();
    final primaryToken = await storage.read(key: 'automate_primary_token');
    final isLoggedIn = primaryToken != null && primaryToken.isNotEmpty;
    debugPrint('[Window] isLoggedIn: $isLoggedIn');

    // 设置关闭时隐藏到托盘（拦截系统关闭按钮）
    await WindowService.setCloseToTray();

    if (isLoggedIn) {
      // 已登录：使用主窗口大小
      const mainWindowSize = Size(1280, 720);
      // 最小宽度必须大于 PC 模式阈值 (columnWidth * 2 + navRailWidth = 840)
      const mainWindowMinSize = Size(960, 600);
      await windowManager.waitUntilReadyToShow(null, () async {
        await windowManager.setResizable(true);
        await windowManager.setMaximumSize(const Size(9999, 9999));
        await windowManager.setSize(mainWindowSize);
        await windowManager.setMinimumSize(mainWindowMinSize);
        await windowManager.center();
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        await windowManager.show();
        await windowManager.focus();
      });
    } else {
      // 未登录：使用登录窗口大小
      const loginWindowSize = Size(420, 580);
      await windowManager.waitUntilReadyToShow(null, () async {
        await windowManager.setSize(loginWindowSize);
        await windowManager.setMinimumSize(loginWindowSize);
        await windowManager.setMaximumSize(loginWindowSize);
        await windowManager.center();
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
        await windowManager.setResizable(false);
        await windowManager.show();
        await windowManager.focus();
      });
    }

    // 初始化系统托盘（登录和主窗口都需要）
    await WindowService.initSystemTray();
  }

  // iOS: Avoid "black screen" on cold start by rendering a first frame ASAP.
  // Client restore / database open can be slow or hang on some iOS setups after
  // the user kills the app; doing this work before `runApp` leaves the screen
  // blank. We bootstrap inside a widget and start heavy init after the first
  // frame.
  if (PlatformInfos.isIOS) {
    runApp(const _IosStartupApp());
    return;
  }

  final store = await AppSettings.init();
  Logs().i('Welcome to ${AppSettings.applicationName.value} <3');

  await vod.init(wasmPath: './assets/assets/vodozemac/');

  Logs().nativeColors = !PlatformInfos.isIOS;
  final clients = await ClientManager.getClients(store: store);

  // If the app starts in detached mode, we assume that it is in
  // background fetch mode for processing push notifications. This is
  // currently only supported on Android.
  if (PlatformInfos.isAndroid &&
      AppLifecycleState.detached == WidgetsBinding.instance.lifecycleState) {
    // Do not send online presences when app is in background fetch mode.
    for (final client in clients) {
      client.backgroundSync = false;
      client.syncPresence = PresenceType.offline;
    }

    // In the background fetch mode we do not want to waste ressources with
    // starting the Flutter engine but process incoming push notifications.
    // 注意：我们使用阿里云推送，禁用 FluffyChat 原有的 BackgroundPush
    // BackgroundPush.clientOnly(clients.first);
    // To start the flutter engine afterwards we add an custom observer.
    WidgetsBinding.instance.addObserver(AppStarter(clients, store));
    Logs().i(
      '${AppSettings.applicationName.value} started in background-fetch mode. No GUI will be created unless the app is no longer detached.',
    );
    return;
  }

  // Started in foreground mode.
  Logs().i(
    '${AppSettings.applicationName.value} started in foreground mode. Rendering GUI...',
  );
  await startGui(clients, store);
}

class _IosStartupApp extends StatefulWidget {
  const _IosStartupApp();

  @override
  State<_IosStartupApp> createState() => _IosStartupAppState();
}

class _IosStartupAppState extends State<_IosStartupApp> {
  Future<_IosStartupData>? _initFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _initFuture = _init();
      });
    });
  }

  Future<_IosStartupData> _init() async {
    developer.log('[iOS Startup] Starting initialization...', name: 'Startup');

    developer.log('[iOS Startup] Initializing AppSettings...', name: 'Startup');
    final store = await AppSettings.init();
    Logs().i('Welcome to ${AppSettings.applicationName.value} <3');
    developer.log('[iOS Startup] AppSettings initialized', name: 'Startup');

    developer.log('[iOS Startup] Initializing vodozemac...', name: 'Startup');
    await vod.init(wasmPath: './assets/assets/vodozemac/');
    Logs().nativeColors = false;
    developer.log('[iOS Startup] Vodozemac initialized', name: 'Startup');

    developer.log('[iOS Startup] Getting Matrix clients (timeout: 45s)...', name: 'Startup');
    final clients = await ClientManager.getClients(store: store)
        .timeout(const Duration(seconds: 45));
    developer.log('[iOS Startup] Got ${clients.length} Matrix clients', name: 'Startup');

    String? pin;
    try {
      developer.log('[iOS Startup] Reading PIN from keychain...', name: 'Startup');
      pin = await const FlutterSecureStorage().read(
        key: 'chat.fluffy.app_lock',
      );
      developer.log('[iOS Startup] PIN read complete (${pin != null ? "found" : "not found"})', name: 'Startup');
    } catch (e, s) {
      developer.log('[iOS Startup] PIN read ERROR: $e', name: 'Startup', error: e);
      Logs().d('Unable to read PIN from Secure storage', e, s);
    }

    developer.log('[iOS Startup] Preloading first client data...', name: 'Startup');
    final firstClient = clients.firstOrNull;
    if (firstClient != null) {
      final roomsLoading = firstClient.roomsLoading;
      if (roomsLoading != null) {
        unawaited(
          roomsLoading.catchError(
            (e, s) {
              Logs().w('roomsLoading failed', e, s);
            },
          ),
        );
      }
      final accountDataLoading = firstClient.accountDataLoading;
      if (accountDataLoading != null) {
        unawaited(
          accountDataLoading.catchError(
            (e, s) {
              Logs().w('accountDataLoading failed', e, s);
            },
          ),
        );
      }
    }

    developer.log('[iOS Startup] Initialization complete!', name: 'Startup');
    return _IosStartupData(store: store, clients: clients, pincode: pin);
  }

  void _retry() {
    setState(() {
      _initFuture = _init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final future = _initFuture;
    if (future == null) {
      return const MaterialApp(
        home: _StartupLoadingScreen(
          message: '正在启动…',
        ),
        debugShowCheckedModeBanner: false,
      );
    }

    return FutureBuilder<_IosStartupData>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const MaterialApp(
            home: _StartupLoadingScreen(
              message: '正在初始化数据…',
            ),
            debugShowCheckedModeBanner: false,
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          const errorText = '系统繁忙，请稍后重试';
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: _StartupErrorScreen(
              errorText: errorText,
              onRetry: _retry,
            ),
          );
        }

        final data = snapshot.data!;
        return PsygoApp(
          clients: data.clients,
          pincode: data.pincode,
          store: data.store,
        );
      },
    );
  }
}

class _IosStartupData {
  final List<Client> clients;
  final String? pincode;
  final SharedPreferences store;

  const _IosStartupData({
    required this.clients,
    required this.store,
    required this.pincode,
  });
}

class _StartupLoadingScreen extends StatelessWidget {
  final String message;

  const _StartupLoadingScreen({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(height: 16),
            Text(message),
          ],
        ),
      ),
    );
  }
}

class _StartupErrorScreen extends StatelessWidget {
  final String errorText;
  final VoidCallback onRetry;

  const _StartupErrorScreen({
    required this.errorText,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              const Text(
                '启动失败',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                errorText,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: onRetry,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fetch the pincode for the applock and start the flutter engine.
Future<void> startGui(List<Client> clients, SharedPreferences store) async {
  // Fetch the pin for the applock if existing for mobile applications.
  String? pin;
  if (PlatformInfos.isMobile) {
    try {
      pin = await const FlutterSecureStorage().read(
        key: 'chat.fluffy.app_lock',
      );
    } catch (e, s) {
      Logs().d('Unable to read PIN from Secure storage', e, s);
    }
  }

  // Preload first client
  final firstClient = clients.firstOrNull;
  await firstClient?.roomsLoading;
  await firstClient?.accountDataLoading;

  runApp(PsygoApp(clients: clients, pincode: pin, store: store));
}

/// Watches the lifecycle changes to start the application when it
/// is no longer detached.
class AppStarter with WidgetsBindingObserver {
  final List<Client> clients;
  final SharedPreferences store;
  bool guiStarted = false;

  AppStarter(this.clients, this.store);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (guiStarted) return;
    if (state == AppLifecycleState.detached) return;

    Logs().i(
      '${AppSettings.applicationName.value} switches from the detached background-fetch mode to ${state.name} mode. Rendering GUI...',
    );
    // Switching to foreground mode needs to reenable send online sync presence.
    for (final client in clients) {
      client.backgroundSync = true;
      client.syncPresence = PresenceType.online;
    }
    startGui(clients, store);
    // We must make sure that the GUI is only started once.
    guiStarted = true;
  }
}
