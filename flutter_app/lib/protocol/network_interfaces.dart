import 'package:flutter/foundation.dart';

class NetworkInterfaces {
  const NetworkInterfaces({
    required this.ethernet,
    required this.wifi,
    required this.cellular,
  });

  factory NetworkInterfaces.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('Thiết bị thiếu network_interfaces');
    }
    bool flag(String key) {
      final value = json[key];
      if (value is! int || (value != 0 && value != 1)) {
        throw FormatException('network_interfaces.$key phải là 0 hoặc 1');
      }
      return value == 1;
    }

    final interfaces = NetworkInterfaces(
      ethernet: flag('ethernet'),
      wifi: flag('wifi'),
      cellular: flag('4g'),
    );
    if (interfaces.ethernet && interfaces.cellular) {
      throw const FormatException('Không hỗ trợ Ethernet và 4G đồng thời');
    }
    if (!interfaces.ethernet && !interfaces.wifi && !interfaces.cellular) {
      throw const FormatException('Thiết bị không có giao diện mạng');
    }
    return interfaces;
  }

  final bool ethernet;
  final bool wifi;
  final bool cellular;

  static NetworkInterfaces? tryParse(Object? json) {
    try {
      return NetworkInterfaces.fromJson(json);
    } on FormatException catch (error) {
      debugPrint('[NetworkInterfaces] $error');
      return null;
    }
  }

  bool supports(String method) => switch (method) {
    'ETH' => ethernet,
    'WIFI' => wifi,
    '4G' => cellular,
    _ => false,
  };
}
