import 'dart:convert';
import 'dart:io';
import 'package:aliyun_push/aliyun_push.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:psygo/config/setting_keys.dart';
import 'package:psygo/core/config.dart';

/// 阿里云移动推送服务
///
/// 负责初始化阿里云推送 SDK，处理推送消息回调
/// 使用透传消息（MESSAGE）模式，客户端决定是否显示通知
class AliyunPushService {
  static AliyunPushService? _instance;
  static AliyunPushService get instance => _instance ??= AliyunPushService._();

  final AliyunPush _aliyunPush = AliyunPush();
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  String? _deviceId;

  /// 获取当前活跃房间 ID 的回调（由 MatrixState 设置）
  String? Function()? activeRoomIdGetter;

  /// 获取当前用户 Matrix ID 的回调（由 MatrixState 设置，用于过滤自己发的消息）
  String? Function()? currentUserIdGetter;

  /// 通知点击回调（由 MatrixState 设置）
  void Function(String roomId, String? eventId)? onNotificationTapped;

  /// 已显示通知的 event_id 集合（防止重复通知）
  /// 使用 LinkedHashSet 限制大小，避免内存无限增长
  final Set<String> _shownEventIds = {};
  static const int _maxShownEventIds = 100;

  /// 正在导航到的房间 ID（用于防止导航过程中的竞态条件）
  String? _navigatingToRoomId;

  void _audit(String message) {
    if (!kReleaseMode) return;
    // Use print to ensure logs show up in release builds.
    // ignore: avoid_print
    print('[PUSH_AUDIT] $message');
  }

  String _mask(String? value, {int prefix = 4, int suffix = 4}) {
    if (value == null || value.isEmpty) return 'null';
    if (value.length <= prefix + suffix) return value;
    return '${value.substring(0, prefix)}...${value.substring(value.length - suffix)}';
  }

  String _truncate(String? value, {int max = 200}) {
    if (value == null || value.isEmpty) return '';
    if (value.length <= max) return value;
    return '${value.substring(0, max)}...';
  }

  bool get _isAppResumed {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  AliyunPushService._();

  /// 标记正在进入某个房间（防止导航过程中的重复通知）
  ///
  /// 当用户点击聊天列表进入房间时调用，500ms 后自动清除
  void markEnteringRoom(String roomId) {
    _navigatingToRoomId = roomId;
    Future.delayed(const Duration(milliseconds: 500), () {
      if (_navigatingToRoomId == roomId) {
        _navigatingToRoomId = null;
      }
    });
    Logs().d('[AliyunPush] Marked entering room: $roomId');
  }

  /// 清除进入房间标记（用于取消导航时调用）
  void clearEnteringRoom() {
    _navigatingToRoomId = null;
  }

  /// 阿里云推送配置（通过 --dart-define-from-file=env.json 注入）
  static const _androidAppKey = String.fromEnvironment('PUSH_ANDROID_APP_KEY');
  static const _androidAppSecret = String.fromEnvironment('PUSH_ANDROID_APP_SECRET');
  static const _iosAppKey = String.fromEnvironment('PUSH_IOS_APP_KEY');
  static const _iosAppSecret = String.fromEnvironment('PUSH_IOS_APP_SECRET');

  /// 获取当前平台的 appKey
  String get _appKey => Platform.isIOS ? _iosAppKey : _androidAppKey;

  /// 获取当前平台的 appSecret
  String get _appSecret => Platform.isIOS ? _iosAppSecret : _androidAppSecret;

  /// 获取设备 ID（推送 token）
  String? get deviceId => _deviceId;

  /// 是否已初始化
  bool get isInitialized => _initialized;

  /// 初始化阿里云推送
  ///
  /// 应在 app 启动时调用，仅在移动端有效
  Future<bool> initialize() async {
    if (_initialized) {
      Logs().d('[AliyunPush] Already initialized');
      return true;
    }

    if (!Platform.isAndroid && !Platform.isIOS) {
      Logs().d('[AliyunPush] Not a mobile platform, skipping');
      return false;
    }

    try {
      Logs().i('[AliyunPush] Initializing with appKey: $_appKey');
      _audit('init start appKey=$_appKey');

      // 初始化本地通知（用于显示透传消息）
      await _initLocalNotifications();

      // 设置消息回调（必须在初始化之前设置）
      _setupCallbacks();

      // 初始化 SDK
      final result = await _aliyunPush.initPush(
        appKey: _appKey,
        appSecret: _appSecret,
      );

      final code = result['code'] as String?;
      final errorMsg = result['errorMsg'] as String?;

      if (code == kAliyunPushSuccessCode) {
        Logs().i('[AliyunPush] SDK initialized successfully');
        _audit('init success');
        _initialized = true;

        // 获取设备 ID
        await _fetchDeviceId();

        // 初始化厂商通道（Android 专用，支持 vivo/华为/小米等离线推送）
        if (Platform.isAndroid) {
          await initThirdPush();
        }

        // 清除角标（角标功能已禁用，启动时清除残留角标）
        try {
          if (Platform.isIOS) {
            await _aliyunPush.setIOSBadgeNum(0);
          } else if (Platform.isAndroid) {
            await _aliyunPush.setAndroidBadgeNum(0);
          }
        } catch (e) {
          // 忽略清除角标失败
        }

        // 设置日志级别（调试时可开启）
        if (kDebugMode) {
          await _aliyunPush.setLogLevel(AliyunPushLogLevel.debug);
        }

        return true;
      } else {
        Logs().e('[AliyunPush] SDK init failed: code=$code, msg=$errorMsg');
        _audit('init failed code=$code msg=$errorMsg');
        return false;
      }
    } catch (e, s) {
      Logs().e('[AliyunPush] SDK init exception', e, s);
      _audit('init exception $e');
      return false;
    }
  }

  /// 初始化本地通知插件
  Future<void> _initLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings('notifications_icon');
    const iosSettings = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // 注意：通知权限由 PermissionService 在登录成功后统一请求
    // 这里不再请求，避免 App 启动时就弹出权限弹窗

    Logs().d('[AliyunPush] Local notifications initialized');
  }

  /// 通知点击处理
  void _onNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return;

    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final roomId = data['room_id'] as String?;
      final eventId = data['event_id'] as String?;

      if (roomId != null && onNotificationTapped != null) {
        // 设置正在导航的房间 ID，防止导航过程中收到该房间的重复通知
        _navigatingToRoomId = roomId;

        // 延迟清除导航标志，给路由更新留出时间
        Future.delayed(const Duration(milliseconds: 500), () {
          if (_navigatingToRoomId == roomId) {
            _navigatingToRoomId = null;
          }
        });

        onNotificationTapped!(roomId, eventId);
      }
    } catch (e) {
      Logs().w('[AliyunPush] Failed to parse notification payload', e);
    }
  }

  /// 获取设备 ID
  Future<void> _fetchDeviceId() async {
    try {
      _deviceId = await _aliyunPush.getDeviceId();
      Logs().i('[AliyunPush] Device ID: ${_mask(_deviceId)} (len=${_deviceId?.length ?? 0})');
      _audit('deviceId=${_mask(_deviceId)}');
    } catch (e) {
      Logs().w('[AliyunPush] Failed to get device ID', e);
      _audit('deviceId fetch failed $e');
    }
  }

  /// 设置消息回调
  void _setupCallbacks() {
    _aliyunPush.addMessageReceiver(
      onNotification: (message) async {
        Logs().i('[AliyunPush] Notification received: $message');
        _handleNotification(message);
      },
      onNotificationOpened: (message) async {
        Logs().i('[AliyunPush] Notification opened: $message');
        _handleNotificationOpened(message);
      },
      onNotificationRemoved: (message) async {
        Logs().d('[AliyunPush] Notification removed: $message');
      },
      onMessage: (message) async {
        Logs().i('[AliyunPush] In-app message received: $message');
        _handleMessage(message);
      },
      onAndroidNotificationReceivedInApp: (message) async {
        // 延迟 50ms，让 onNotification 先执行并记录 event_id
        // 这样可以避免系统通知栏 + 本地通知的重复
        await Future.delayed(const Duration(milliseconds: 50));
        Logs().i('[AliyunPush] Android notification in app: $message');
        _handleNotificationReceivedInApp(message);
      },
      onIOSChannelOpened: (message) async {
        Logs().d('[AliyunPush] iOS channel opened: $message');
      },
    );

    Logs().d('[AliyunPush] Callbacks registered');
  }

  /// 处理通知消息（通知展示在通知栏时触发）
  ///
  /// 当系统通知栏展示通知时，此回调被触发。
  /// 需要将 event_id 加入去重集合，防止 onAndroidNotificationReceivedInApp 再次弹出本地通知。
  ///
  /// 注意：此回调在系统已经展示通知后触发，无法阻止系统通知栏的显示。
  /// 如果是自己发的消息，后端不应该推送，但我们仍然记录 event_id 用于去重。
  void _handleNotification(Map<dynamic, dynamic> message) {
    try {
      // 解析扩展参数，提取 event_id 用于去重（可能是 Map 或 JSON 字符串）
      final extraMap = _parseExtraMap(message['extraMap']);
      if (extraMap != null) {
        final eventId = extraMap['event_id'] as String?;
        final sender = extraMap['sender'] as String?;

        // 检查是否是自己发的消息
        final currentUserId = currentUserIdGetter?.call();
        if (sender != null && currentUserId != null && sender == currentUserId) {
          Logs().d('[AliyunPush] System notification for self message, this should not happen (backend issue)');
          // 仍然记录 event_id，防止后续重复
        }

        if (eventId != null && eventId.isNotEmpty) {
          // 将 event_id 加入去重集合，防止重复通知
          _shownEventIds.add(eventId);
          while (_shownEventIds.length > _maxShownEventIds) {
            _shownEventIds.remove(_shownEventIds.first);
          }
          Logs().d('[AliyunPush] Notification shown by system, marked event: $eventId');
        }
      }
    } catch (e) {
      Logs().w('[AliyunPush] Failed to parse notification for dedup', e);
    }
  }

  /// 安全解析 extraMap（可能是 Map 或 JSON 字符串）
  Map<String, dynamic>? _parseExtraMap(dynamic extraMapValue) {
    if (extraMapValue == null) return null;

    if (extraMapValue is Map) {
      // 已经是 Map，转换为 Map<String, dynamic>
      return Map<String, dynamic>.from(extraMapValue);
    } else if (extraMapValue is String) {
      // 是 JSON 字符串，需要解析
      try {
        final parsed = jsonDecode(extraMapValue);
        if (parsed is Map) {
          return Map<String, dynamic>.from(parsed);
        }
      } catch (e) {
        Logs().w('[AliyunPush] Failed to parse extraMap string: $e');
      }
    }
    return null;
  }

  /// 处理通知点击
  void _handleNotificationOpened(Map<dynamic, dynamic> message) {
    Logs().i('[AliyunPush] Notification opened: $message');

    try {
      // 解析扩展参数（可能是 Map 或 JSON 字符串）
      final extraMap = _parseExtraMap(message['extraMap']);
      if (extraMap == null) {
        Logs().w('[AliyunPush] No extraMap in notification');
        return;
      }

      final roomId = extraMap['room_id'] as String?;
      final eventId = extraMap['event_id'] as String?;

      if (roomId != null && onNotificationTapped != null) {
        _navigatingToRoomId = roomId;
        Future.delayed(const Duration(milliseconds: 500), () {
          if (_navigatingToRoomId == roomId) {
            _navigatingToRoomId = null;
          }
        });
        onNotificationTapped!(roomId, eventId);
      }
    } catch (e, s) {
      Logs().e('[AliyunPush] Failed to handle notification opened', e, s);
    }
  }

  /// 处理前台收到的通知（AndroidRemind=false 时触发）
  ///
  /// 当 App 在前台时，NOTICE 通知不会弹系统通知栏，而是触发此回调。
  /// 在这里判断用户是否在当前聊天室，智能决定是否显示本地通知。
  ///
  /// 消息格式：
  /// {
  ///   "title": "通知标题",
  ///   "body": "通知内容",
  ///   "extraMap": {
  ///     "type": "matrix_message",
  ///     "room_id": "!roomid:server",
  ///     "event_id": "$eventid",
  ///     "sender": "@user:server",
  ///     "badge": "5"
  ///   }
  /// }
  void _handleNotificationReceivedInApp(Map<dynamic, dynamic> message) {
    Logs().i('[AliyunPush] Received NOTICE in app: $message');

    try {
      // 获取通知标题和内容
      final title = message['title'] as String? ?? 'Psygo';
      final body = message['body'] as String? ?? message['summary'] as String? ?? '你收到了一条新消息';

      // 解析扩展参数（可能是 Map 或 JSON 字符串）
      final extraMap = _parseExtraMap(message['extraMap']);
      if (extraMap == null) {
        Logs().w('[AliyunPush] No extraMap in notification');
        return;
      }

      final type = extraMap['type'] as String?;

      // 只处理 matrix_message 类型
      if (type != 'matrix_message') {
        Logs().d('[AliyunPush] Ignoring non-matrix notification type: $type');
        return;
      }

      final roomId = extraMap['room_id'] as String?;
      final eventId = extraMap['event_id'] as String?;
      final sender = extraMap['sender'] as String?;
      // badge 可能是 String 或 int
      final badgeValue = extraMap['badge'];
      final badge = badgeValue is int ? badgeValue : int.tryParse(badgeValue?.toString() ?? '0') ?? 0;

      Logs().d('[AliyunPush] Matrix notification in app: room=$roomId, event=$eventId, sender=$sender, title=$title');

      // 检查是否是自己发的消息（不应该给自己显示通知）
      final currentUserId = currentUserIdGetter?.call();
      if (sender != null && currentUserId != null && sender == currentUserId) {
        Logs().d('[AliyunPush] Message from self, skip notification');
        return;
      }

      // 检查 event_id 去重（防止同一消息多次显示通知）
      if (eventId != null && _shownEventIds.contains(eventId)) {
        Logs().d('[AliyunPush] Event already shown, skip duplicate: $eventId');
        setBadgeNumber(badge);
        return;
      }

      // 检查用户是否在当前房间
      final activeRoomId = activeRoomIdGetter?.call();
      if (_isAppResumed && activeRoomId != null && activeRoomId == roomId) {
        Logs().d('[AliyunPush] User is in current room, skip notification');
        setBadgeNumber(badge);
        return;
      }

      // 检查用户是否正在导航到该房间（防止点击通知后的竞态条件）
      if (_isAppResumed && _navigatingToRoomId != null && _navigatingToRoomId == roomId) {
        Logs().d('[AliyunPush] User is navigating to this room, skip notification');
        setBadgeNumber(badge);
        return;
      }

      // 记录已显示的 event_id（维护集合大小）
      if (eventId != null) {
        _shownEventIds.add(eventId);
        while (_shownEventIds.length > _maxShownEventIds) {
          _shownEventIds.remove(_shownEventIds.first);
        }
      }

      // 用户不在当前房间，显示本地通知
      final payload = jsonEncode({
        'type': type,
        'room_id': roomId,
        'event_id': eventId,
        'sender': extraMap['sender'],
        'badge': badge,
      });

      _showLocalNotification(
        title: title,
        body: body,
        payload: payload,
        badge: badge,
      );
    } catch (e, s) {
      Logs().e('[AliyunPush] Failed to handle notification in app', e, s);
    }
  }

  /// 处理透传消息（MESSAGE 类型）
  ///
  /// 后端发送的透传消息格式：
  /// {
  ///   "type": "matrix_message",
  ///   "title": "发送者名称",
  ///   "body": "消息内容",
  ///   "room_id": "!roomid:server",
  ///   "event_id": "$eventid",
  ///   "sender": "@user:server",
  ///   "badge": 5
  /// }
  void _handleMessage(Map<dynamic, dynamic> message) {
    Logs().i('[AliyunPush] Received MESSAGE: $message');

    try {
      // 阿里云透传消息的 content 字段是 JSON 字符串
      final content = message['content'] as String?;
      if (content == null) {
        Logs().w('[AliyunPush] Message content is null');
        return;
      }

      // 解析 JSON payload
      final payload = jsonDecode(content) as Map<String, dynamic>;
      final type = payload['type'] as String?;

      // 只处理 matrix_message 类型
      if (type != 'matrix_message') {
        Logs().d('[AliyunPush] Ignoring non-matrix message type: $type');
        return;
      }

      final roomId = payload['room_id'] as String?;
      final eventId = payload['event_id'] as String?;
      final sender = payload['sender'] as String?;
      final title = payload['title'] as String? ?? 'Psygo';
      final body = payload['body'] as String? ?? '你收到了一条新消息';
      final badge = payload['badge'] as int? ?? 0;

      Logs().d('[AliyunPush] Matrix message: room=$roomId, event=$eventId, sender=$sender, title=$title');

      // 检查是否是自己发的消息（不应该给自己显示通知）
      final currentUserId = currentUserIdGetter?.call();
      if (sender != null && currentUserId != null && sender == currentUserId) {
        Logs().d('[AliyunPush] Message from self, skip notification');
        return;
      }

      // 检查 event_id 去重（防止同一消息多次显示通知）
      if (eventId != null && _shownEventIds.contains(eventId)) {
        Logs().d('[AliyunPush] Event already shown, skip duplicate: $eventId');
        setBadgeNumber(badge);
        return;
      }

      // 检查用户是否在当前房间
      final activeRoomId = activeRoomIdGetter?.call();
      if (_isAppResumed && activeRoomId != null && activeRoomId == roomId) {
        Logs().d('[AliyunPush] User is in current room, skip notification');
        setBadgeNumber(badge);
        return;
      }

      // 检查用户是否正在导航到该房间（防止点击通知后的竞态条件）
      if (_isAppResumed && _navigatingToRoomId != null && _navigatingToRoomId == roomId) {
        Logs().d('[AliyunPush] User is navigating to this room, skip notification');
        setBadgeNumber(badge);
        return;
      }

      // 记录已显示的 event_id（维护集合大小）
      if (eventId != null) {
        _shownEventIds.add(eventId);
        // 如果超过最大数量，移除最旧的（LinkedHashSet 保持插入顺序）
        while (_shownEventIds.length > _maxShownEventIds) {
          _shownEventIds.remove(_shownEventIds.first);
        }
      }

      // 用户不在当前房间，显示本地通知
      _showLocalNotification(
        title: title,
        body: body,
        payload: content,
        badge: badge,
      );
    } catch (e, s) {
      Logs().e('[AliyunPush] Failed to handle message', e, s);
    }
  }

  /// 显示本地通知（public 方法，供 Matrix SDK 调用）
  ///
  /// [roomId] 房间 ID，用于点击通知后跳转
  /// [eventId] 事件 ID，可选
  /// [title] 通知标题
  /// [body] 通知内容
  /// [badge] 角标数量
  Future<void> showNotificationForRoom({
    required String roomId,
    String? eventId,
    required String title,
    required String body,
    int badge = 0,
  }) async {
    // 检查 event_id 去重（防止同一消息多次显示通知）
    if (eventId != null && _shownEventIds.contains(eventId)) {
      Logs().d('[AliyunPush] Event already shown, skip duplicate: $eventId');
      return;
    }

    // 检查用户是否在当前房间
    final activeRoomId = activeRoomIdGetter?.call();
    if (_isAppResumed && activeRoomId != null && activeRoomId == roomId) {
      Logs().d('[AliyunPush] User is in current room, skip notification');
      return;
    }

    // 检查用户是否正在导航到该房间
    if (_isAppResumed && _navigatingToRoomId != null && _navigatingToRoomId == roomId) {
      Logs().d('[AliyunPush] User is navigating to this room, skip notification');
      return;
    }

    // 记录已显示的 event_id（维护集合大小）
    if (eventId != null) {
      _shownEventIds.add(eventId);
      while (_shownEventIds.length > _maxShownEventIds) {
        _shownEventIds.remove(_shownEventIds.first);
      }
    }

    final payload = jsonEncode({
      'type': 'matrix_message',
      'room_id': roomId,
      'event_id': eventId,
    });

    await _showLocalNotification(
      title: title,
      body: body,
      payload: payload,
      badge: badge,
    );
  }

  /// 显示本地通知（内部方法）
  Future<void> _showLocalNotification({
    required String title,
    required String body,
    required String payload,
    int badge = 0,
  }) async {
    // Android 通知详情
    const androidDetails = AndroidNotificationDetails(
      'matrix_messages', // channel id
      '消息通知', // channel name
      channelDescription: 'Matrix 消息通知',
      importance: Importance.high,
      priority: Priority.high,
      icon: 'notifications_icon',
    );

    // iOS 通知详情
    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      badgeNumber: badge,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // 使用时间戳作为通知 ID，避免覆盖
    final notificationId = DateTime.now().millisecondsSinceEpoch % 100000;

    await _localNotifications.show(
      notificationId,
      title,
      body,
      details,
      payload: payload,
    );

    // 更新角标
    await setBadgeNumber(badge);

    Logs().i('[AliyunPush] Local notification shown: id=$notificationId, title=$title');
  }

  /// 绑定账号（可选，用于精准推送）
  Future<bool> bindAccount(String account) async {
    if (!_initialized) {
      Logs().w('[AliyunPush] Not initialized, cannot bind account');
      return false;
    }

    try {
      final result = await _aliyunPush.bindAccount(account);
      final code = result['code'] as String?;
      if (code == kAliyunPushSuccessCode) {
        Logs().i('[AliyunPush] Account bound: $account');
        return true;
      } else {
        Logs().w('[AliyunPush] Bind account failed: $result');
        return false;
      }
    } catch (e) {
      Logs().e('[AliyunPush] Bind account exception', e);
      return false;
    }
  }

  /// 解绑账号
  Future<bool> unbindAccount() async {
    if (!_initialized) return false;

    try {
      final result = await _aliyunPush.unbindAccount();
      final code = result['code'] as String?;
      return code == kAliyunPushSuccessCode;
    } catch (e) {
      Logs().e('[AliyunPush] Unbind account exception', e);
      return false;
    }
  }

  /// 绑定标签（可选，用于分组推送）
  Future<bool> bindTag(List<String> tags) async {
    if (!_initialized) return false;

    try {
      final result = await _aliyunPush.bindTag(
        tags,
        target: kAliyunTargetDevice,
      );
      final code = result['code'] as String?;
      if (code == kAliyunPushSuccessCode) {
        Logs().i('[AliyunPush] Tags bound: $tags');
        return true;
      }
      return false;
    } catch (e) {
      Logs().e('[AliyunPush] Bind tag exception', e);
      return false;
    }
  }

  /// 设置角标数量（已禁用）
  Future<void> setBadgeNumber(int count) async {
    // 角标功能已禁用
  }

  /// 初始化厂商通道（Android 专用，后续接入时使用）
  Future<bool> initThirdPush() async {
    if (!Platform.isAndroid || !_initialized) return false;

    try {
      final result = await _aliyunPush.initAndroidThirdPush();
      final code = result['code'] as String?;
      if (code == kAliyunPushSuccessCode) {
        Logs().i('[AliyunPush] Third push initialized');
        return true;
      }
      Logs().w('[AliyunPush] Third push init failed: $result');
      return false;
    } catch (e) {
      Logs().e('[AliyunPush] Third push init exception', e);
      return false;
    }
  }

  // ============================================================
  // Push Gateway 集成
  // ============================================================

  /// Push Gateway URL（Synapse 调用，用集群内部地址）
  static String get _pushGatewayUrl => '${PsygoConfig.internalBaseUrl}/_matrix/push/v1/notify';

  /// 应用 ID（用于区分 iOS/Android）
  static const String _androidAppId = 'com.creativekoalas.psygo.android';
  static const String _iosAppId = 'com.creativekoalas.psygo.ios';

  /// 获取当前平台的应用 ID
  String get _appId => Platform.isIOS ? _iosAppId : _androidAppId;

  /// 获取当前平台名称
  String get _platform => Platform.isIOS ? 'ios' : 'android';

  /// 生成 pushkey
  /// 格式：{platform}_{deviceId}
  /// 同一设备的 pushkey 保持不变，避免重复注册
  String _generatePushKey() {
    return '${_platform}_${_deviceId ?? 'unknown'}';
  }

  Future<void> _reconcileStoredPushKey() async {
    if (_deviceId == null) return;

    await AppSettings.init();

    final cachedDeviceId = AppSettings.aliyunPushDeviceId.value;
    final cachedPushKey = AppSettings.aliyunPushPushKey.value;
    final currentPushKey = _generatePushKey();

    final pushKeyChanged =
        cachedPushKey.isNotEmpty && cachedPushKey != currentPushKey;
    final deviceIdChanged =
        cachedDeviceId.isNotEmpty && cachedDeviceId != _deviceId;

    if (pushKeyChanged || deviceIdChanged) {
      Logs().i('[AliyunPush] Cached push key mismatch, cleaning up old registration');
      _audit(
        'pushKey mismatch old=${_mask(cachedPushKey)} new=${_mask(currentPushKey)} '
        'deviceIdOld=${_mask(cachedDeviceId)} deviceIdNew=${_mask(_deviceId)}',
      );
      if (cachedPushKey.isNotEmpty) {
        final ok = await unregisterPush(cachedPushKey);
        if (ok) {
          Logs().i('[AliyunPush] Old push key unregistered: ${_mask(cachedPushKey)}');
          await AppSettings.aliyunPushPushKey.setItem('');
        } else {
          Logs().w('[AliyunPush] Failed to unregister old push key: ${_mask(cachedPushKey)}');
        }
      }
    }

    if (cachedDeviceId != _deviceId) {
      await AppSettings.aliyunPushDeviceId.setItem(_deviceId!);
    }
  }

  Future<void> _persistPushRegistration(String pushKey) async {
    if (_deviceId == null) return;

    await AppSettings.init();
    await AppSettings.aliyunPushDeviceId.setItem(_deviceId!);
    await AppSettings.aliyunPushPushKey.setItem(pushKey);
  }

  /// 注册推送到 automate-assistant 后端
  ///
  /// [matrixUserID] Matrix 用户 ID（如 @username:localhost）
  /// 返回生成的 pushkey，用于后续注册到 Matrix Synapse
  Future<String?> registerPusherToBackend(String matrixUserID) async {
    if (!_initialized || _deviceId == null) {
      Logs().w('[AliyunPush] Not initialized or no device ID');
      _audit('register backend skipped initialized=$_initialized deviceId=$_deviceId');
      return null;
    }

    final pushKey = _generatePushKey();
    Logs().i('[AliyunPush] Register pusher: baseUrl=${PsygoConfig.baseUrl}, apiUrl=${PsygoConfig.apiUrl}');
    Logs().i('[AliyunPush] Register pusher: k8sNamespace=${PsygoConfig.k8sNamespace}, gateway=$_pushGatewayUrl');
    Logs().i('[AliyunPush] Register payload: user=$matrixUserID deviceId=${_mask(_deviceId)} pushKey=${_mask(pushKey)} appId=$_appId platform=$_platform');
    _audit('register backend start user=$matrixUserID pushKey=${_mask(pushKey)} deviceId=${_mask(_deviceId)}');

    try {
      final uri = Uri.parse('${PsygoConfig.baseUrl}/api/push/register');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'matrix_user_id': matrixUserID,
          'device_id': _deviceId,
          'push_key': pushKey,
          'app_id': _appId,
          'platform': _platform,
          'device_name': Platform.localHostname,
        }),
      );

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200) {
        Logs().i('[AliyunPush] Pusher registered to backend: pushKey=${_mask(pushKey)}');
        _audit('register backend ok status=${response.statusCode}');
        return pushKey;
      } else {
        final errorMsg = json['error']?.toString() ?? 'unknown';
        Logs().e('[AliyunPush] Register pusher failed: status=${response.statusCode} error=$errorMsg body=${_truncate(response.body)}');
        _audit('register backend failed status=${response.statusCode} error=$errorMsg');
        return null;
      }
    } catch (e, s) {
      Logs().e('[AliyunPush] Register pusher exception', e, s);
      _audit('register backend exception $e');
      return null;
    }
  }

  /// 注册 pusher 到 Matrix Synapse
  ///
  /// 这会告诉 Synapse 当有新消息时通知我们的 Push Gateway
  /// [client] Matrix SDK Client 实例
  /// [pushKey] 从 registerPusherToBackend 返回的 pushkey
  ///
  /// 设计原则（清理旧 pusher）：
  /// 在注册新 pusher 前，先删除同一 app_id 的所有旧 pusher。
  /// 这解决了 device_id 变化导致的重复推送问题。
  /// Matrix 的 append=false 只删除相同 pushkey 的 pusher，无法清理 app_id 相同但 pushkey 不同的旧记录。
  Future<bool> registerPusherToSynapse(Client client, String pushKey) async {
    try {
      Logs().i('[AliyunPush] Register pusher to Synapse: homeserver=${PsygoConfig.matrixHomeserver}');
      Logs().i('[AliyunPush] Register pusher to Synapse: pushKey=${_mask(pushKey)} appId=$_appId gateway=$_pushGatewayUrl');
      _audit('register synapse start pushKey=${_mask(pushKey)}');
      // Step 1: 获取当前所有 pusher
      final existingPushers = await client.getPushers();
      Logs().i('[AliyunPush] Existing pushers: ${existingPushers?.length ?? 0}');

      // Step 2: 删除同一 app_id 的旧 pusher
      for (final pusher in existingPushers ?? []) {
        if (pusher.appId == _appId && pusher.pushkey != pushKey) {
          Logs().i('[AliyunPush] Removing old pusher: pushKey=${pusher.pushkey}');
          try {
            // 使用 deletePusher 删除（内部设置 kind=null）
            await client.deletePusher(pusher);
            Logs().i('[AliyunPush] Old pusher removed: pushKey=${pusher.pushkey}');
          } catch (e) {
            Logs().w('[AliyunPush] Failed to remove old pusher: ${pusher.pushkey}', e);
            // 继续删除其他的，不中断流程
          }
        }
      }

      // Step 3: 注册新 pusher
      // Matrix Pusher 规范：
      // https://spec.matrix.org/v1.6/client-server-api/#post_matrixclientv3pushersset
      await client.postPusher(
        Pusher(
          pushkey: pushKey,
          kind: 'http',
          appId: _appId,
          appDisplayName: 'Psygo',
          deviceDisplayName: Platform.localHostname,
          lang: 'zh-CN',
          data: PusherData(
            url: Uri.parse(_pushGatewayUrl),
            format: 'event_id_only',
          ),
        ),
        append: false,
      );

      Logs().i('[AliyunPush] Pusher registered to Synapse: pushKey=$pushKey');
      _audit('register synapse ok');
      return true;
    } catch (e, s) {
      Logs().e('[AliyunPush] Register pusher to Synapse failed', e, s);
      _audit('register synapse exception $e');
      return false;
    }
  }

  /// 完整的推送注册流程
  ///
  /// 1. 注册设备到 automate-assistant 后端
  /// 2. 注册 pusher 到 Matrix Synapse
  /// [client] Matrix SDK Client 实例
  Future<bool> registerPush(Client client) async {
    if (!_initialized || _deviceId == null) {
      Logs().w('[AliyunPush] Not initialized or no device ID');
      _audit('registerPush skipped initialized=$_initialized deviceId=$_deviceId');
      return false;
    }

    final matrixUserID = client.userID;
    if (matrixUserID == null) {
      Logs().w('[AliyunPush] User not logged in');
      _audit('registerPush skipped user not logged in');
      return false;
    }

    _audit('registerPush start user=$matrixUserID');

    await _reconcileStoredPushKey();

    // Step 1: 注册到后端
    final pushKey = await registerPusherToBackend(matrixUserID);
    if (pushKey == null) {
      _audit('registerPush abort: backend failed');
      return false;
    }

    await _persistPushRegistration(pushKey);

    // Step 2: 注册到 Synapse
    return await registerPusherToSynapse(client, pushKey);
  }

  /// 注销推送
  ///
  /// [pushKey] 之前注册时返回的 pushkey
  Future<bool> unregisterPush(String pushKey) async {
    try {
      final uri = Uri.parse('${PsygoConfig.baseUrl}/api/push/unregister')
          .replace(queryParameters: {'push_key': pushKey});

      final response = await http.delete(uri);

      if (response.statusCode == 200) {
        Logs().i('[AliyunPush] Pusher unregistered: pushKey=$pushKey');
        return true;
      } else {
        Logs().w('[AliyunPush] Unregister pusher failed');
        return false;
      }
    } catch (e) {
      Logs().e('[AliyunPush] Unregister pusher exception', e);
      return false;
    }
  }
}
