class DeviceRecord {
  const DeviceRecord({
    required this.id,
    required this.macAddress,
    required this.name,
    this.userId,
    this.maxSensorCount,
    this.maxLoadCount,
    this.deviceType = 'controller',
    this.powerSource = 'mains',
    this.createdAt,
  });

  /// Row of the `devices` table.
  factory DeviceRecord.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final mac = json['mac_address'];
    if (id is! String || id.isEmpty || mac is! String || mac.isEmpty) {
      throw FormatException('Dòng devices thiếu id/mac_address: $json');
    }
    final name = json['name'];
    int? count(String key) => (json[key] as num?)?.toInt();
    return DeviceRecord(
      id: id,
      macAddress: mac,
      name: name is String && name.trim().isNotEmpty ? name : mac,
      userId: json['user_id'] as String?,
      maxSensorCount: count('max_sensor_count'),
      maxLoadCount: count('max_load_count'),
      deviceType: json['device_type'] as String? ?? 'controller',
      powerSource: json['power_source'] as String? ?? 'mains',
      createdAt: json['created_at'] as String?,
    );
  }

  final String id;
  final String macAddress;
  final String name;
  final String? userId;

  /// Null when the device did not report its capabilities while provisioning.
  final int? maxSensorCount;
  final int? maxLoadCount;

  /// `controller` or `sensor_node`.
  final String deviceType;

  /// `mains`, `battery` or `solar_battery`.
  final String powerSource;
  final String? createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'mac_address': macAddress,
    'name': name,
    'user_id': userId,
    'max_sensor_count': maxSensorCount,
    'max_load_count': maxLoadCount,
    'device_type': deviceType,
    'power_source': powerSource,
    'created_at': createdAt,
  };
}
