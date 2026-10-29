import 'crud_api.dart';
import '../state/device_health.dart';
import 'device_repository.dart';
import 'mqtt_session_manager.dart';

class DeviceApi {
  DeviceApi._();

  static Future<void> deleteDevice(String deviceId) async {
    await CrudApi.deleteDevice(deviceId);
    await DeviceRepository.instance.removeDevice(deviceId);
    await MqttSessionManager.instance.removeDevice(deviceId);
    await DeviceHealth.instance.deleteDevice(deviceId);
  }
}
