/// Port identifiers of the protocol (`mqtt_protocol.md`, section 6.2).
abstract final class PortIds {
  static const rs485Type = 'rs485';
  static const analogType = 'analog_4_20ma';
  static const diType = 'di';
  static const interfaceTypes = [rs485Type, analogType, diType];

  static const rs485Ports = ['RS1', 'RS2', 'RS3', 'RS4'];
  static const analogPorts = ['AN1'];
  static const diPorts = ['DI1', 'DI2', 'DI3', 'DI4'];
  static const loadPorts = ['DO1', 'DO2', 'DO3', 'DO4'];
  static const conditionIds = ['CON1', 'CON2'];
  static const schedulerIds = ['SHE1', 'SHE2', 'SHE3'];

  /// Ports of one interface type when the snapshot does not list them yet.
  static List<String> defaultPorts(String interfaceType) =>
      switch (interfaceType) {
        rs485Type => rs485Ports,
        analogType => analogPorts,
        diType => diPorts,
        _ => const [],
      };

  static String? interfaceTypeOfPort(String portId) {
    for (final type in interfaceTypes) {
      if (defaultPorts(type).contains(portId)) return type;
    }
    return null;
  }

  static String loadId(int number) => 'DO$number';

  static String? loadFeedbackLoadId(String sensorName) {
    for (final loadId in loadPorts) {
      if (sensorName.startsWith('${loadId}_')) return loadId;
    }
    return null;
  }

  static String? loadButtonLoadId(String sensorName) {
    final match = RegExp(r'^(?:ON|OFF)([1-4])_').firstMatch(sensorName);
    return match == null ? null : 'DO${match.group(1)}';
  }

  static bool isReservedLoadSensorName(String sensorName) =>
      loadFeedbackLoadId(sensorName) != null ||
      loadButtonLoadId(sensorName) != null;

  static bool isLoad(String id) => loadPorts.contains(id);
  static bool isSensor(String id) => interfaceTypeOfPort(id) != null;
  static bool isCondition(String id) => conditionIds.contains(id);
  static bool isScheduler(String id) => schedulerIds.contains(id);
}
