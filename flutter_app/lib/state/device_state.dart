import 'package:flutter/foundation.dart';

import '../protocol/device_snapshot.dart';
import '../protocol/device_telemetry.dart';

/// What the ESP32 of the open device really holds and measures, read from
/// MQTT. Screens show this rather than what the user last asked for.
class DeviceState extends ChangeNotifier {
  DeviceState();

  static final instance = DeviceState();

  String? _deviceId;
  DeviceSnapshot? _snapshot;
  DeviceTelemetry? _telemetry;

  String? get deviceId => _deviceId;

  /// Last `SNAPSHOT` of the status topic; null until the ESP32 has sent one.
  DeviceSnapshot? get snapshot => _snapshot;

  /// Last `telemetry` message.
  DeviceTelemetry? get telemetry => _telemetry;

  /// Network the ESP32 uses (`ETH` or `WIFI`): from telemetry, or from the
  /// snapshot until the first telemetry has arrived. Null when unknown. There
  /// is no "none": the ESP32 can only talk over MQTT, and losing the network
  /// is reported by the LWT (presence offline).
  String? get internetMethod {
    final method = _telemetry?.netInterface ?? _snapshot?.netInterface;
    return method == 'ETH' || method == 'WIFI' ? method : null;
  }

  void reset(String? deviceId) {
    _deviceId = deviceId;
    _snapshot = null;
    _telemetry = null;
    _hiddenSensors.clear();
    _confirmedHidden.clear();
    notifyListeners();
  }

  // Sensors the user deleted whose ACK has not come yet are hidden at once; a
  // snapshot drops the hiding after the ESP32 confirmed the deletion.
  final _hiddenSensors = <String>{};
  final _confirmedHidden = <String>{};

  bool isSensorHidden(String portId) => _hiddenSensors.contains(portId);

  void hideSensor(String portId) {
    _hiddenSensors.add(portId);
    notifyListeners();
  }

  /// The ESP32 acknowledged the deletion: the next snapshot no longer lists it.
  void confirmSensorHidden(String portId) {
    if (_hiddenSensors.contains(portId)) _confirmedHidden.add(portId);
  }

  /// The deletion failed: the sensor is shown again.
  void restoreSensor(String portId) {
    _confirmedHidden.remove(portId);
    if (_hiddenSensors.remove(portId)) notifyListeners();
  }

  /// Forgets everything read from the device (it went offline or the app lost
  /// MQTT): values must then show as unknown rather than stale.
  void clearLive() => reset(_deviceId);

  void applySnapshot(DeviceSnapshot snapshot) {
    _snapshot = snapshot;
    _hiddenSensors.removeAll(_confirmedHidden);
    _confirmedHidden.clear();
    notifyListeners();
  }

  void applyTelemetry(DeviceTelemetry telemetry) {
    _telemetry = telemetry;
    notifyListeners();
  }

  /// Latest telemetry of one sensor; null when it has not been reported.
  TelemetryInput? reading(String portId) => _telemetry?.input(portId);
}
