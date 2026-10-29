import '../protocol/port_ids.dart';

class DeviceSelection {
  const DeviceSelection({required this.deviceId, required this.name});

  final String deviceId;
  final String name;
}

/// The sensor the configuration screen opens: an existing one of the snapshot
/// (by port) or a new one for a free port.
class SensorConfigSelection {
  const SensorConfigSelection({
    required this.device,
    required this.interfaceType,
    required this.portId,
    required this.name,
    this.slaveId,
    this.enabled = true,
  });

  final DeviceSelection device;

  /// [PortIds.rs485Type], [PortIds.analogType] or [PortIds.diType].
  final String interfaceType;

  /// `RS1`..`RS4`, `AN1`, `DI1`..`DI4`.
  final String portId;
  final String name;
  final int? slaveId;
  final bool enabled;
}
