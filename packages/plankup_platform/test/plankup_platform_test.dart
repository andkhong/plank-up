import 'package:flutter_test/flutter_test.dart';
import 'package:plankup_platform/plankup_platform.dart';
import 'package:plankup_platform/plankup_platform_platform_interface.dart';
import 'package:plankup_platform/plankup_platform_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockPlankupPlatformPlatform
    with MockPlatformInterfaceMixin
    implements PlankupPlatformPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final PlankupPlatformPlatform initialPlatform = PlankupPlatformPlatform.instance;

  test('$MethodChannelPlankupPlatform is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelPlankupPlatform>());
  });

  test('getPlatformVersion', () async {
    PlankupPlatform plankupPlatformPlugin = PlankupPlatform();
    MockPlankupPlatformPlatform fakePlatform = MockPlankupPlatformPlatform();
    PlankupPlatformPlatform.instance = fakePlatform;

    expect(await plankupPlatformPlugin.getPlatformVersion(), '42');
  });
}
