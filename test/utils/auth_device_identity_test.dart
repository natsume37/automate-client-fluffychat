import 'package:flutter_test/flutter_test.dart';
import 'package:psygo/utils/auth_device_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AuthDeviceIdentity', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('reuses the same device id after initial creation', () async {
      final first = await AuthDeviceIdentity.getOrCreateDeviceId();
      final second = await AuthDeviceIdentity.getOrCreateDeviceId();

      expect(first, isNotEmpty);
      expect(second, first);
      expect(first, startsWith('${AuthDeviceIdentity.platformName}_'));
    });

    test('buildRequestPayload includes stable device metadata', () async {
      final firstPayload = await AuthDeviceIdentity.buildRequestPayload();
      final secondPayload = await AuthDeviceIdentity.buildRequestPayload();

      expect(
        firstPayload['auth_device_platform'],
        AuthDeviceIdentity.platformName,
      );
      expect(firstPayload['auth_device_id'], isNotEmpty);
      expect(secondPayload, firstPayload);
    });
  });
}
