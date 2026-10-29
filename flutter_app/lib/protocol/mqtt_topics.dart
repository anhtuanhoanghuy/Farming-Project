/// The four topic leaves of a device. The app publishes `commands` and
/// subscribes to `ack`, `status` and `telemetry`.
enum MqttDeviceTopicKind { telemetry, commands, ack, status }

class MqttDeviceTopics {
  const MqttDeviceTopics._(this.base);

  factory MqttDeviceTopics.forDevice({
    required String userId,
    required String deviceId,
  }) {
    _validateSegment(userId, 'userId');
    if (!_deviceIdPattern.hasMatch(deviceId)) {
      throw ArgumentError.value(
        deviceId,
        'deviceId',
        'Expected a lowercase 12-character MAC address',
      );
    }
    return MqttDeviceTopics._('v1/$userId/devices/$deviceId');
  }

  static final _deviceIdPattern = RegExp(r'^[0-9a-f]{12}$');

  final String base;

  String get telemetry => '$base/telemetry';
  String get commands => '$base/commands';
  String get ack => '$base/ack';
  String get status => '$base/status';

  /// The topics the app listens to.
  List<String> get subscriptions => [telemetry, ack, status];

  static MqttDeviceTopicKind? kindFromTopic(String topic) {
    final leaf = topic.substring(topic.lastIndexOf('/') + 1);
    for (final kind in MqttDeviceTopicKind.values) {
      if (kind.name == leaf) return kind;
    }
    return null;
  }

  static String? deviceIdFromTopic(String topic, {required String userId}) {
    final prefix = 'v1/$userId/devices/';
    if (!topic.startsWith(prefix)) return null;
    final parts = topic.substring(prefix.length).split('/');
    if (parts.length != 2 ||
        !_deviceIdPattern.hasMatch(parts[0]) ||
        kindFromTopic(topic) == null) {
      return null;
    }
    return parts[0];
  }

  static void _validateSegment(String value, String name) {
    if (value.isEmpty ||
        value.length > 36 ||
        value.codeUnits.any(
          (codeUnit) =>
              codeUnit < 0x21 ||
              codeUnit > 0x7e ||
              codeUnit == 0x2f ||
              codeUnit == 0x2b ||
              codeUnit == 0x23,
        )) {
      throw ArgumentError.value(value, name, 'Invalid MQTT topic segment');
    }
  }
}
