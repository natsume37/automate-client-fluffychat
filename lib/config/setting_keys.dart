import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:async/async.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix_api_lite/utils/logs.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:psygo/core/config.dart';
import 'package:psygo/utils/platform_infos.dart';

enum AppSettings<T> {
  textMessageMaxLength<int>('textMessageMaxLength', 16384),
  audioRecordingNumChannels<int>('audioRecordingNumChannels', 1),
  audioRecordingAutoGain<bool>('audioRecordingAutoGain', true),
  audioRecordingEchoCancel<bool>('audioRecordingEchoCancel', false),
  audioRecordingNoiseSuppress<bool>('audioRecordingNoiseSuppress', true),
  audioRecordingBitRate<int>('audioRecordingBitRate', 64000),
  audioRecordingSamplingRate<int>('audioRecordingSamplingRate', 44100),
  showNoGoogle<bool>('com.psygo.show_no_google', false),
  unifiedPushRegistered<bool>('com.psygo.unifiedpush.registered', false),
  unifiedPushEndpoint<String>('com.psygo.unifiedpush.endpoint', ''),
  aliyunPushDeviceId<String>('com.psygo.aliyunpush.device_id', ''),
  aliyunPushPushKey<String>('com.psygo.aliyunpush.push_key', ''),
  pushNotificationsGatewayUrl<String>(
    'pushNotificationsGatewayUrl',
    'https://push.automate.app/_matrix/push/v1/notify',
  ),
  pushNotificationsPusherFormat<String>(
    'pushNotificationsPusherFormat',
    'event_id_only',
  ),
  renderHtml<bool>('com.psygo.renderHtml', true),
  fontSizeFactor<double>('com.psygo.font_size_factor', 1.0),
  hideRedactedEvents<bool>('com.psygo.hideRedactedEvents', false),
  hideUnknownEvents<bool>('com.psygo.hideUnknownEvents', true),
  separateChatTypes<bool>('com.psygo.separateChatTypes', false),
  autoplayImages<bool>('com.psygo.autoplay_images', true),
  sendTypingNotifications<bool>('com.psygo.send_typing_notifications', true),
  sendPublicReadReceipts<bool>('com.psygo.send_public_read_receipts', true),
  swipeRightToLeftToReply<bool>('com.psygo.swipeRightToLeftToReply', true),
  sendOnEnter<bool>('com.psygo.send_on_enter', false),
  showPresences<bool>('com.psygo.show_presences', true),
  displayNavigationRail<bool>('com.psygo.display_navigation_rail', false),
  experimentalVoip<bool>('com.psygo.experimental_voip', false),
  shareKeysWith<String>('com.psygo.share_keys_with_2', 'all'),
  noEncryptionWarningShown<bool>(
    'com.psygo.no_encryption_warning_shown',
    false,
  ),
  displayChatDetailsColumn(
    'com.psygo.display_chat_details_column',
    false,
  ),
  // AppConfig-mirrored settings
  applicationName<String>('com.psygo.application_name', 'Psygo'),
  // homeserver 指向本地 K8s Synapse（运行时从 PsygoConfig.matrixHomeserver 获取）
  // 枚举 defaultValue 必须是编译时常量，所以这里用空字符串占位
  defaultHomeserver<String>('com.psygo.default_homeserver', ''),
  // colorSchemeSeed stored as ARGB int
  colorSchemeSeedInt<int>(
    'com.psygo.color_scheme_seed',
    0xFF5625BA,
  ),
  emojiSuggestionLocale<String>('emoji_suggestion_locale', ''),
  enableSoftLogout<bool>('com.psygo.enable_soft_logout', false);

  final String key;
  final T defaultValue;

  const AppSettings(this.key, this.defaultValue);

  static SharedPreferences get store => _store!;
  static SharedPreferences? _store;

  static Future<SharedPreferences> init({loadWebConfigFile = true}) async {
    if (AppSettings._store != null) return AppSettings.store;

    final store = AppSettings._store = await SharedPreferences.getInstance();

    // Migrate wrong datatype for fontSizeFactor
    final fontSizeFactorString =
        Result(() => store.getString(AppSettings.fontSizeFactor.key))
            .asValue
            ?.value;
    if (fontSizeFactorString != null) {
      Logs().i('Migrate wrong datatype for fontSizeFactor!');
      await store.remove(AppSettings.fontSizeFactor.key);
      final fontSizeFactor = double.tryParse(fontSizeFactorString);
      if (fontSizeFactor != null) {
        await store.setDouble(AppSettings.fontSizeFactor.key, fontSizeFactor);
      }
    }

    if (store.getBool(AppSettings.sendOnEnter.key) == null) {
      await store.setBool(AppSettings.sendOnEnter.key, !PlatformInfos.isMobile);
    }
    if (kIsWeb && loadWebConfigFile) {
      try {
        final configJsonString =
            utf8.decode((await http.get(Uri.parse('config.json'))).bodyBytes);
        final configJson =
            json.decode(configJsonString) as Map<String, Object?>;
        for (final setting in AppSettings.values) {
          if (store.get(setting.key) != null) continue;
          final configValue = configJson[setting.name];
          if (configValue == null) continue;
          if (configValue is bool) {
            await store.setBool(setting.key, configValue);
          }
          if (configValue is String) {
            await store.setString(setting.key, configValue);
          }
          if (configValue is int) {
            await store.setInt(setting.key, configValue);
          }
          if (configValue is double) {
            await store.setDouble(setting.key, configValue);
          }
        }
      } on FormatException catch (_) {
        Logs().v('[ConfigLoader] config.json not found');
      } catch (e) {
        Logs().v('[ConfigLoader] config.json not found', e);
      }
    }

    return store;
  }
}

extension AppSettingsBoolExtension on AppSettings<bool> {
  bool get value {
    final value = Result(() => AppSettings.store.getBool(key));
    final error = value.asError;
    if (error != null) {
      Logs().e(
        'Unable to fetch $key from storage. Removing entry...',
        error.error,
        error.stackTrace,
      );
    }
    return value.asValue?.value ?? defaultValue;
  }

  Future<void> setItem(bool value) => AppSettings.store.setBool(key, value);
}

extension AppSettingsStringExtension on AppSettings<String> {
  String get value {
    // applicationName 从环境变量读取，不从本地存储读取
    // 支持多环境数据库隔离（Psygo_dev / Psygo_test / Psygo）
    if (this == AppSettings.applicationName) {
      return PsygoConfig.appName;
    }
    final value = Result(() => AppSettings.store.getString(key));
    final error = value.asError;
    if (error != null) {
      Logs().e(
        'Unable to fetch $key from storage. Removing entry...',
        error.error,
        error.stackTrace,
      );
    }
    return value.asValue?.value ?? defaultValue;
  }

  Future<void> setItem(String value) => AppSettings.store.setString(key, value);
}

extension AppSettingsIntExtension on AppSettings<int> {
  int get value {
    final value = Result(() => AppSettings.store.getInt(key));
    final error = value.asError;
    if (error != null) {
      Logs().e(
        'Unable to fetch $key from storage. Removing entry...',
        error.error,
        error.stackTrace,
      );
    }
    return value.asValue?.value ?? defaultValue;
  }

  Future<void> setItem(int value) => AppSettings.store.setInt(key, value);
}

extension AppSettingsDoubleExtension on AppSettings<double> {
  double get value {
    final value = Result(() => AppSettings.store.getDouble(key));
    final error = value.asError;
    if (error != null) {
      Logs().e(
        'Unable to fetch $key from storage. Removing entry...',
        error.error,
        error.stackTrace,
      );
    }
    return value.asValue?.value ?? defaultValue;
  }

  Future<void> setItem(double value) => AppSettings.store.setDouble(key, value);
}
