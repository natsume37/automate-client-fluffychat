import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'platform_infos.dart';

/// Stable per-installation auth device identity for login rate limiting.
class AuthDeviceIdentity {
  AuthDeviceIdentity._();

  static const String _prefsKey = 'automate_auth_device_id';
  static const Uuid _uuid = Uuid();

  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_prefsKey)?.trim();
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final deviceId = '${platformName}_${_uuid.v4()}';
    await prefs.setString(_prefsKey, deviceId);
    return deviceId;
  }

  static String get platformName {
    if (PlatformInfos.isWeb) return 'web';
    if (PlatformInfos.isAndroid) return 'android';
    if (PlatformInfos.isIOS) return 'ios';
    if (PlatformInfos.isMacOS) return 'macos';
    if (PlatformInfos.isWindows) return 'windows';
    if (PlatformInfos.isLinux) return 'linux';
    return 'unknown';
  }

  static Future<Map<String, String>> buildRequestPayload() async {
    final deviceId = await getOrCreateDeviceId();
    return {
      'auth_device_id': deviceId,
      'auth_device_platform': platformName,
    };
  }
}
