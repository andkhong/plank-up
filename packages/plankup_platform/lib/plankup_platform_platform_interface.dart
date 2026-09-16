import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'plankup_platform_method_channel.dart';

abstract class PlankupPlatformPlatform extends PlatformInterface {
  /// Constructs a PlankupPlatformPlatform.
  PlankupPlatformPlatform() : super(token: _token);

  static final Object _token = Object();

  static PlankupPlatformPlatform _instance = MethodChannelPlankupPlatform();

  /// The default instance of [PlankupPlatformPlatform] to use.
  ///
  /// Defaults to [MethodChannelPlankupPlatform].
  static PlankupPlatformPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [PlankupPlatformPlatform] when
  /// they register themselves.
  static set instance(PlankupPlatformPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
