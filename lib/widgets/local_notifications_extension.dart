import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:desktop_notifications/desktop_notifications.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:image/image.dart';
import 'package:matrix/matrix.dart';
import 'package:universal_html/html.dart' as html;
import 'package:window_manager/window_manager.dart';
import 'package:path/path.dart' as path;

import 'package:psygo/config/setting_keys.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/utils/aliyun_push_service.dart';
import 'package:psygo/utils/client_download_content_extension.dart';
import 'package:psygo/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:psygo/utils/platform_infos.dart';
import 'package:psygo/utils/push_helper.dart';
import 'package:psygo/utils/window_service.dart';
import 'package:psygo/widgets/fluffy_chat_app.dart';
import 'package:psygo/widgets/matrix.dart';

extension LocalNotificationsExtension on MatrixState {
  static final html.AudioElement _audioPlayer = html.AudioElement()
    ..src = 'assets/assets/sounds/notification.ogg'
    ..load();

  static FlutterLocalNotificationsPlugin? _flutterLocalNotificationsPlugin;
  static bool _isInitialized = false;
  static Future<bool>? _initializationFuture;

  Uri _windowsLogoUri() {
    final logoPath = path.join(
      path.dirname(Platform.resolvedExecutable),
      'data',
      'flutter_assets',
      'assets',
      'logo.png',
    );
    return Uri.file(logoPath, windows: true);
  }

  Future<FlutterLocalNotificationsPlugin?> _getNotificationsPlugin() async {
    if (_flutterLocalNotificationsPlugin != null && _isInitialized) {
      return _flutterLocalNotificationsPlugin!;
    }

    _flutterLocalNotificationsPlugin ??= FlutterLocalNotificationsPlugin();
    _initializationFuture ??= _initializeNotificationsPlugin();
    final initialized = await _initializationFuture!;

    if (!initialized) {
      return null;
    }
    return _flutterLocalNotificationsPlugin;
  }

  Future<bool> _initializeNotificationsPlugin() async {
    final plugin = _flutterLocalNotificationsPlugin;
    if (plugin == null) return false;

    InitializationSettings? initSettings;
    if (Platform.isWindows) {
      final iconUri = _windowsLogoUri();
      initSettings = InitializationSettings(
        windows: WindowsInitializationSettings(
          appName: 'Psygo',
          appUserModelId: 'com.psygo.app',
          guid: '8af2f2bb-4f08-4ac1-824e-977080f91d42',
          iconPath: iconUri.toFilePath(),
        ),
      );
    } else if (Platform.isMacOS) {
      initSettings = const InitializationSettings(
        macOS: DarwinInitializationSettings(),
      );
    }

    if (initSettings == null) {
      _isInitialized = true;
      return true;
    }

    Future<bool> initializeWithSettings(InitializationSettings settings) async {
      final result = await plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: (response) async {
          final roomId = response.payload;
          if (roomId != null && roomId.isNotEmpty) {
            await WindowService.showWindow();
            PsygoApp.router.go('/rooms/$roomId');
          }
        },
      );
      return result == true;
    }

    try {
      var initialized = await initializeWithSettings(initSettings);
      if (!initialized && Platform.isWindows) {
        initialized = await initializeWithSettings(
          const InitializationSettings(
            windows: WindowsInitializationSettings(
              appName: 'Psygo',
              appUserModelId: 'com.psygo.app',
              guid: '8af2f2bb-4f08-4ac1-824e-977080f91d42',
            ),
          ),
        );
      }

      _isInitialized = initialized;
      return initialized;
    } catch (e, s) {
      _isInitialized = false;
      return false;
    } finally {
      _initializationFuture = null;
    }
  }

  void showLocalNotification(Event event) async {
    final roomId = event.room.id;
    try {
      if (Platform.isLinux) {
        Logs().i(
          '[LinuxNotify] showLocalNotification room=$roomId event=${event.eventId} type=${event.type} activeRoom=$activeRoomId',
        );
      }
      // 如果用户在当前房间，不显示通知
      if (activeRoomId == roomId) {
        if (kIsWeb && webHasFocus) {
          if (Platform.isLinux) {
            Logs().i('[LinuxNotify] skip: active room and web focused');
          }
          return;
        }
        if (PlatformInfos.isDesktop &&
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
            !WindowService.isHiddenToTray) {
          try {
            final isVisible = await windowManager.isVisible();
            final isFocused = await windowManager.isFocused();
            final isMinimized = await windowManager.isMinimized();
            if (isVisible && isFocused && !isMinimized) {
              if (Platform.isLinux) {
                Logs().i('[LinuxNotify] skip: active room and window focused');
              }
              return;
            }
          } catch (e, s) {
            Logs().w('Unable to query window state for notification gating', e, s);
          }
        }
        // 移动端：App 在前台且在当前房间时不显示通知
        if ((Platform.isAndroid || Platform.isIOS) &&
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
          if (Platform.isLinux) {
            Logs().i('[LinuxNotify] skip: active room foreground (mobile)');
          }
          return;
        }
      }

      final title =
          event.room.getLocalizedDisplayname(MatrixLocals(L10n.of(context)));
      final body = await event.calcLocalizedBody(
        MatrixLocals(L10n.of(context)),
        withSenderNamePrefix: !event.room.isDirectChat ||
            event.room.lastEvent?.senderId == client.userID,
        plaintextBody: true,
        hideReply: true,
        hideEdit: true,
        removeMarkdown: true,
      );

      if (kIsWeb) {
        final avatarUrl = event.senderFromMemoryOrFallback.avatarUrl;
        Uri? thumbnailUri;

        if (avatarUrl != null) {
          const size = 128;
          const thumbnailMethod = ThumbnailMethod.crop;
          // Pre-cache so that we can later just set the thumbnail uri as icon:
          try {
            await client.downloadMxcCached(
              avatarUrl,
              width: size,
              height: size,
              thumbnailMethod: thumbnailMethod,
              isThumbnail: true,
              rounded: true,
            );
          } catch (e, s) {
            Logs().d('Unable to pre-download avatar for web notification', e, s);
          }

          thumbnailUri =
              await event.senderFromMemoryOrFallback.avatarUrl?.getThumbnailUri(
            client,
            width: size,
            height: size,
            method: thumbnailMethod,
          );
        }

        _audioPlayer.play();

        html.Notification(
          title,
          body: body,
          icon: thumbnailUri?.toString(),
          tag: event.room.id,
        );
      } else if (Platform.isLinux) {
        final avatarUrl = event.room.avatar;
        final fullHints = [NotificationHint.soundName('message-new-instant')];

        if (avatarUrl != null) {
          try {
            const size = notificationAvatarDimension;
            const thumbnailMethod = ThumbnailMethod.crop;
            // Pre-cache so that we can later just set the thumbnail uri as icon:
            final data = await client.downloadMxcCached(
              avatarUrl,
              width: size,
              height: size,
              thumbnailMethod: thumbnailMethod,
              isThumbnail: true,
              rounded: true,
            );

            final image = decodeImage(data);
            if (image != null) {
              final realData = image.getBytes(order: ChannelOrder.rgba);
              fullHints.add(
                NotificationHint.imageData(
                  image.width,
                  image.height,
                  realData,
                  hasAlpha: true,
                  channels: 4,
                ),
              );
            }
          } catch (e, s) {
            Logs().w('Unable to load avatar for Linux notification', e, s);
          }
        }
        final fullActions = [
          NotificationAction(
            'default',
            L10n.of(context).openChat,
          ),
          NotificationAction(
            DesktopNotificationActions.seen.name,
            L10n.of(context).markAsRead,
          ),
        ];

        Future<dynamic> sendLinuxNotification({
          required List<NotificationHint> notifyHints,
          required List<NotificationAction> notifyActions,
          required int replacesId,
        }) async {
          final client = linuxNotifications;
          if (client == null) return null;
          return client.notify(
            title,
            body: body,
            replacesId: replacesId,
            appName: AppSettings.applicationName.value,
            appIcon: 'psygo',
            actions: notifyActions,
            hints: notifyHints,
          );
        }

        dynamic notification;
        var notificationHasActions = true;
        try {
          notification = await sendLinuxNotification(
            notifyHints: fullHints,
            notifyActions: fullActions,
            replacesId: linuxNotificationIds[roomId] ?? 0,
          );
        } catch (e, s) {
          Logs().w('Linux notification failed, retrying with new client', e, s);
          resetLinuxNotifications();
          try {
            notification = await sendLinuxNotification(
              notifyHints: fullHints,
              notifyActions: fullActions,
              replacesId: linuxNotificationIds[roomId] ?? 0,
            );
          } catch (e, s) {
            Logs().w(
              'Linux notification retry failed, falling back to minimal',
              e,
              s,
            );
            notificationHasActions = false;
            try {
              notification = await sendLinuxNotification(
                notifyHints: const [],
                notifyActions: const [],
                replacesId: 0,
              );
            } catch (e, s) {
              Logs().w('Linux notification minimal fallback failed', e, s);
              return;
            }
          }
        }
        if (notification == null) return;
        if (notificationHasActions) {
          notification.action.then((actionStr) async {
            if (actionStr == null || actionStr.isEmpty) {
              return;
            }
            if (actionStr == DesktopNotificationActions.seen.name) {
              event.room.setReadMarker(
                event.eventId,
                mRead: event.eventId,
                public: AppSettings.sendPublicReadReceipts.value,
              );
            } else {
              // 点击通知本身(default)或其他情况都跳转到聊天室
              await WindowService.showWindow();
              setActiveClient(event.room.client);
              PsygoApp.router.go('/rooms/${event.room.id}');
            }
          });
        }
        linuxNotificationIds[roomId] = notification.id;
      } else if (Platform.isWindows || Platform.isMacOS) {
        final plugin = await _getNotificationsPlugin();
        if (plugin == null) {
          return;
        }

        NotificationDetails? notificationDetails;
        if (Platform.isWindows) {
          final iconUri = _windowsLogoUri();
          notificationDetails = NotificationDetails(
            windows: WindowsNotificationDetails(
              images: [
                WindowsImage(
                  iconUri,
                  altText: 'Psygo',
                  placement: WindowsImagePlacement.appLogoOverride,
                ),
              ],
            ),
          );
        } else if (Platform.isMacOS) {
          notificationDetails = const NotificationDetails(
            macOS: DarwinNotificationDetails(
              sound: 'notification.caf',
            ),
          );
        }

        await plugin.show(
          roomId.hashCode,
          title,
          body,
          notificationDetails,
          payload: roomId,
        );
      } else if (Platform.isAndroid || Platform.isIOS) {
        // Android/iOS: 通过阿里云推送服务显示本地通知
        // 这里处理的是在线时 Matrix SDK 收到的消息
        // 离线时由 Push Gateway → 阿里云推送 → 厂商通道处理
        await AliyunPushService.instance.showNotificationForRoom(
          roomId: roomId,
          eventId: event.eventId,
          title: title,
          body: body,
          badge: 0, // 角标功能已禁用
        );
      }
    } catch (e, s) {
      Logs().e('Failed to show local notification', e, s);
    }
  }
}

enum DesktopNotificationActions { seen, openChat }
