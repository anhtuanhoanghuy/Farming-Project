class DeviceRecord {
  const DeviceRecord({
    required this.id,
    required this.macAddress,
    required this.name,
    this.maxSensorCount,
    this.maxLoadCount,
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
      maxSensorCount: count('max_sensor_count'),
      maxLoadCount: count('max_load_count'),
      createdAt: json['created_at'] as String?,
    );
  }

  final String id;
  final String macAddress;
  final String name;

  /// Null when the device did not report its capabilities while provisioning.
  final int? maxSensorCount;
  final int? maxLoadCount;
  final String? createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'mac_address': macAddress,
    'name': name,
    'max_sensor_count': maxSensorCount,
    'max_load_count': maxLoadCount,
    'created_at': createdAt,
  };
}
