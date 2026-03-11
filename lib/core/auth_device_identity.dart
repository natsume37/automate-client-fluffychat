library;

import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthDeviceInfo {
  const AuthDeviceInfo({
    required this.authDeviceId,
    required this.authDevicePlatform,
  });

  final String authDeviceId;
  final String authDevicePlatform;
}

class AuthDeviceIdentity {
  AuthDeviceIdentity._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _deviceIdStorageKey = 'automate_auth_device_id';

  static Future<AuthDeviceInfo>? _cached;

  static Future<AuthDeviceInfo> current() {
    return _cached ??= _resolve();
  }

  static Future<AuthDeviceInfo> _resolve() async {
    final platform = _detectPlatform();
    final persisted = (await _storage.read(key: _deviceIdStorageKey))?.trim();
    if (persisted != null && persisted.isNotEmpty) {
      return AuthDeviceInfo(
        authDeviceId: persisted,
        authDevicePlatform: platform,
      );
    }

    final nativeId = await _readNativeDeviceId(platform);
    final normalizedNativeId = _normalizeDeviceId(nativeId);
    final resolvedId = normalizedNativeId.isNotEmpty
        ? '${platform}_$normalizedNativeId'
        : _fallbackDeviceId(platform);

    await _storage.write(key: _deviceIdStorageKey, value: resolvedId);
    return AuthDeviceInfo(
      authDeviceId: resolvedId,
      authDevicePlatform: platform,
    );
  }

  static String _detectPlatform() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.macOS:
        return 'macos';
      default:
        return 'unknown';
    }
  }

  static Future<String> _readNativeDeviceId(String platform) async {
    try {
      final plugin = DeviceInfoPlugin();
      Map<String, dynamic> data = const <String, dynamic>{};
      switch (platform) {
        case 'android':
          data = (await plugin.androidInfo).data;
          return _firstNonEmpty(data, <String>[
            'id',
            'androidId',
            'fingerprint',
            'hardware',
            'model',
          ]);
        case 'ios':
          data = (await plugin.iosInfo).data;
          return _firstNonEmpty(data, <String>[
            'identifierForVendor',
            'name',
            'model',
          ]);
        case 'linux':
          data = (await plugin.linuxInfo).data;
          return _firstNonEmpty(data, <String>[
            'machineId',
            'id',
            'name',
            'variantId',
          ]);
        case 'windows':
          data = (await plugin.windowsInfo).data;
          return _firstNonEmpty(data, <String>[
            'deviceId',
            'computerName',
            'productName',
          ]);
        case 'macos':
          data = (await plugin.macOsInfo).data;
          return _firstNonEmpty(data, <String>[
            'systemGUID',
            'computerName',
            'model',
          ]);
        case 'web':
          data = (await plugin.webBrowserInfo).data;
          return _firstNonEmpty(data, <String>[
            'vendor',
            'platform',
            'userAgent',
          ]);
        default:
          return '';
      }
    } catch (_) {
      return '';
    }
  }

  static String _firstNonEmpty(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key]?.toString().trim() ?? '';
      if (value.isNotEmpty && value.toLowerCase() != 'unknown') {
        return value;
      }
    }
    return '';
  }

  static String _normalizeDeviceId(String value) {
    final normalized = value
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (normalized.isEmpty) return '';
    if (normalized.length > 96) {
      return normalized.substring(0, 96);
    }
    return normalized;
  }

  static String _fallbackDeviceId(String platform) {
    final nowHex = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final randHex = Random().nextInt(0x7fffffff).toRadixString(16);
    return '${platform}_local_${nowHex}_$randHex';
  }
}
