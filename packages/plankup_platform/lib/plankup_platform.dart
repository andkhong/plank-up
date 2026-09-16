
import 'plankup_platform_platform_interface.dart';

class PlankupPlatform {
  Future<String?> getPlatformVersion() {
    return PlankupPlatformPlatform.instance.getPlatformVersion();
  }
}
