import 'dart:io';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'package:collection/collection.dart';
import 'package:desktop_notifications/desktop_notifications.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_html/html.dart' as html;

import 'package:psygo/config/setting_keys.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/utils/custom_http_client.dart';
import 'package:psygo/utils/custom_image_resizer.dart';
import 'package:psygo/utils/init_with_restore.dart';
import 'package:psygo/utils/platform_infos.dart';
import 'matrix_sdk_extensions/flutter_matrix_dart_sdk_database/builder.dart';

abstract class ClientManager {
  static const String clientNamespace = 'com.psygo.store.clients';

  /// 将 Matrix 用户 ID 转换为合法的 clientName
  /// 例如: @user:server.com -> Psygo_user_server.com
  static String userIdToClientName(String matrixUserId) {
    // 去掉 @ 符号，将 : 替换为 _
    final sanitized = matrixUserId
        .replaceFirst('@', '')
        .replaceAll(':', '_')
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_'); // 替换其他非法文件名字符
    return '${AppSettings.applicationName.value}_$sanitized';
  }

  /// 根据 Matrix 用户 ID 获取或创建 Client
  /// 如果该用户已有数据库则复用，否则创建新的
  static Future<Client> getOrCreateClientForUser(
    String matrixUserId,
    SharedPreferences store,
  ) async {
    final clientName = userIdToClientName(matrixUserId);
    developer.log('[ClientManager] getOrCreateClientForUser: $matrixUserId -> $clientName', name: 'ClientManager');

    // 检查是否已在 store 中
    final clientNamesList = store.getStringList(clientNamespace) ?? [];
    if (!clientNamesList.contains(clientName)) {
      // 添加到 store
      clientNamesList.add(clientName);
      await store.setStringList(clientNamespace, clientNamesList);
      developer.log('[ClientManager] Added new clientName to store: $clientName', name: 'ClientManager');
    }

    // 创建并初始化 client
    final client = await createClient(clientName, store);
    await client.initWithRestore(
      onMigration: () async {
        final l10n = await lookupL10n(PlatformDispatcher.instance.locale);
        sendInitNotification(
          l10n.databaseMigrationTitle,
          l10n.databaseMigrationBody,
        );
      },
    ).catchError(
      (e, s) => Logs().e('Unable to initialize client', e, s),
    );

    return client;
  }

  /// 登录流程专用：获取可直接用于 token 初始化的 client。
  ///
  /// 与 [getOrCreateClientForUser] 的区别：
  /// - 优先复用内存中的 client，避免重复打开数据库
  /// - 新建 client 时不执行 initWithRestore，登录流程会紧接着调用 client.init(newToken: ...)
  static Future<Client> getOrCreateLoginClientForUser(
    String matrixUserId,
    SharedPreferences store, {
    required List<Client> inMemoryClients,
  }) async {
    final clientName = userIdToClientName(matrixUserId);
    developer.log('[ClientManager] getOrCreateLoginClientForUser: $matrixUserId -> $clientName', name: 'ClientManager');

    final existing = inMemoryClients.firstWhereOrNull(
      (client) => client.clientName == clientName,
    );
    if (existing != null) {
      developer.log('[ClientManager] Reusing in-memory client: $clientName', name: 'ClientManager');
      return existing;
    }

    final clientNamesList = store.getStringList(clientNamespace) ?? [];
    if (!clientNamesList.contains(clientName)) {
      clientNamesList.add(clientName);
      await store.setStringList(clientNamespace, clientNamesList);
      developer.log('[ClientManager] Added login clientName to store: $clientName', name: 'ClientManager');
    }

    return createClient(clientName, store);
  }

  static Future<List<Client>> getClients({
    bool initialize = true,
    required SharedPreferences store,
  }) async {
    developer.log('[ClientManager] getClients called', name: 'ClientManager');
    final clientNames = <String>{};
    try {
      final clientNamesList = store.getStringList(clientNamespace) ?? [];
      clientNames.addAll(clientNamesList);
      developer.log('[ClientManager] Found ${clientNames.length} client names', name: 'ClientManager');
    } catch (e, s) {
      Logs().w('Client names in store are corrupted', e, s);
      await store.remove(clientNamespace);
    }
    if (clientNames.isEmpty) {
      developer.log('[ClientManager] No client names, adding default', name: 'ClientManager');
      clientNames.add(PlatformInfos.clientName);
      await store.setStringList(clientNamespace, clientNames.toList());
    }
    developer.log('[ClientManager] Creating ${clientNames.length} clients...', name: 'ClientManager');
    final clients =
        await Future.wait(clientNames.map((name) => createClient(name, store)));
    developer.log('[ClientManager] Clients created', name: 'ClientManager');
    if (initialize) {
      developer.log('[ClientManager] Initializing clients...', name: 'ClientManager');
      await Future.wait(
        clients.map(
          (client) => client.initWithRestore(
            onMigration: () async {
              final l10n = await lookupL10n(PlatformDispatcher.instance.locale);
              sendInitNotification(
                l10n.databaseMigrationTitle,
                l10n.databaseMigrationBody,
              );
            },
          ).catchError(
            (e, s) => Logs().e('Unable to initialize client', e, s),
          ),
        ),
      );
      developer.log('[ClientManager] Clients initialized', name: 'ClientManager');
    }
    if (clients.length > 1 && clients.any((c) => !c.isLogged())) {
      developer.log('[ClientManager] Removing logged out clients...', name: 'ClientManager');
      final loggedOutClients = clients.where((c) => !c.isLogged()).toList();
      for (final client in loggedOutClients) {
        Logs().w(
          'Multi account is enabled but client ${client.userID} is not logged in. Removing...',
        );
        clientNames.remove(client.clientName);
        clients.remove(client);
      }
      await store.setStringList(clientNamespace, clientNames.toList());
    }
    developer.log('[ClientManager] getClients complete, returning ${clients.length} clients', name: 'ClientManager');
    return clients;
  }

  static Future<void> addClientNameToStore(
    String clientName,
    SharedPreferences store,
  ) async {
    final clientNamesList = store.getStringList(clientNamespace) ?? [];
    clientNamesList.add(clientName);
    await store.setStringList(clientNamespace, clientNamesList);
  }

  static Future<void> removeClientNameFromStore(
    String clientName,
    SharedPreferences store,
  ) async {
    final clientNamesList = store.getStringList(clientNamespace) ?? [];
    clientNamesList.remove(clientName);
    await store.setStringList(clientNamespace, clientNamesList);
  }

  static NativeImplementations get nativeImplementations => kIsWeb
      ? const NativeImplementationsDummy()
      : NativeImplementationsIsolate(
          compute,
          vodozemacInit: () => vod.init(wasmPath: './assets/assets/vodozemac/'),
        );

  static Future<Client> createClient(
    String clientName,
    SharedPreferences store,
  ) async {
    developer.log('[ClientManager] createClient: $clientName', name: 'ClientManager');
    final shareKeysWith = AppSettings.shareKeysWith.value;
    final enableSoftLogout = AppSettings.enableSoftLogout.value;

    developer.log('[ClientManager] Building database for: $clientName', name: 'ClientManager');
    final database = await flutterMatrixSdkDatabaseBuilder(clientName);
    developer.log('[ClientManager] Database built for: $clientName', name: 'ClientManager');

    return Client(
      clientName,
      httpClient: CustomHttpClient.createHTTPClient(),
      verificationMethods: {
        KeyVerificationMethod.numbers,
        if (kIsWeb || PlatformInfos.isMobile || PlatformInfos.isLinux)
          KeyVerificationMethod.emoji,
      },
      importantStateEvents: <String>{
        // To make room emotes work
        'im.ponies.room_emotes',
      },
      logLevel: kReleaseMode ? Level.warning : Level.verbose,
      database: database,
      supportedLoginTypes: {
        AuthenticationTypes.password,
        AuthenticationTypes.sso,
      },
      nativeImplementations: nativeImplementations,
      customImageResizer:
          PlatformInfos.isMobile || kIsWeb ? customImageResizer : null,
      defaultNetworkRequestTimeout: const Duration(minutes: 30),
      enableDehydratedDevices: true,
      shareKeysWith: ShareKeysWith.values
              .singleWhereOrNull((share) => share.name == shareKeysWith) ??
          ShareKeysWith.all,
      convertLinebreaksInFormatting: false,
      onSoftLogout:
          enableSoftLogout ? (client) => client.refreshAccessToken() : null,
    );
  }

  static void sendInitNotification(String title, String body) async {
    if (kIsWeb) {
      html.Notification(
        title,
        body: body,
      );
      return;
    }
    if (Platform.isLinux) {
      await NotificationsClient().notify(
        title,
        body: body,
        appName: AppSettings.applicationName.value,
        hints: [
          NotificationHint.soundName('message-new-instant'),
        ],
      );
      return;
    }

    final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    final iconUri = Platform.isWindows ? _windowsLogoUri() : null;

    await flutterLocalNotificationsPlugin.initialize(
      InitializationSettings(
        android: const AndroidInitializationSettings('notifications_icon'),
        iOS: const DarwinInitializationSettings(),
        windows: Platform.isWindows
            ? WindowsInitializationSettings(
                appName: AppSettings.applicationName.value,
                appUserModelId: 'com.psygo.app',
                guid: '8af2f2bb-4f08-4ac1-824e-977080f91d42',
                iconPath: iconUri!.toFilePath(),
              )
            : null,
      ),
    );

    flutterLocalNotificationsPlugin.show(
      0,
      title,
      body,
      NotificationDetails(
        android: const AndroidNotificationDetails(
          'error_message',
          'Error Messages',
          importance: Importance.high,
          priority: Priority.max,
        ),
        iOS: const DarwinNotificationDetails(sound: 'notification.caf'),
        windows: Platform.isWindows
            ? WindowsNotificationDetails(
                images: [
                  WindowsImage(
                    iconUri!,
                    altText: AppSettings.applicationName.value,
                    placement: WindowsImagePlacement.appLogoOverride,
                  ),
                ],
              )
            : null,
      ),
    );
  }

  static Uri _windowsLogoUri() {
    final logoPath = path.join(
      path.dirname(Platform.resolvedExecutable),
      'data',
      'flutter_assets',
      'assets',
      'logo.png',
    );
    return Uri.file(logoPath, windows: true);
  }
}
