import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'plankup_platform_platform_interface.dart';

/// An implementation of [PlankupPlatformPlatform] that uses method channels.
class MethodChannelPlankupPlatform extends PlankupPlatformPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('plankup_platform');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
