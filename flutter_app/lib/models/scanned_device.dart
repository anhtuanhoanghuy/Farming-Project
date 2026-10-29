/// A controller advertising the provisioning service over BLE.
class ScannedDevice {
  const ScannedDevice({
    required this.id,
    required this.name,
    required this.rssi,
  });

  static const serviceUuid = '021a9004-0382-4aea-bff4-6b3f1c5adfb4';

  final String id;
  final String name;
  final int rssi;

  String get shortMac {
    final tail = id.length > 8 ? id.substring(id.length - 8) : id;
    return '...$tail';
  }

  String get proximity {
    if (rssi >= -60) return 'Gần';
    if (rssi >= -75) return 'Trung bình';
    return 'Xa hơn';
  }
}
