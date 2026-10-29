import 'dart:convert';
import 'dart:typed_data';

class ProvisioningMessages {
  ProvisioningMessages._();

  static Uint8List configRequest({
    required String ssid,
    required String password,
    required String userId,
    required bool onlyUseEthernet,
  }) => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'ssid': ssid,
        'password': password,
        'user_id': userId,
        'only_use_ethernet': onlyUseEthernet,
      }),
    ),
  );

  static Uint8List statusRequest() => Uint8List.fromList(utf8.encode('{}'));

  static String parseConfigAccepted(Uint8List response) {
    final json = _decodeObject(response);
    final status = _requiredString(json, 'status');
    final deviceId = _deviceId(json);
    if (status != 'IN_PROGRESS') {
      final reason = json['reason'];
      throw FormatException(
        'Thiết bị từ chối cấu hình: '
        '${reason is String ? reason : status}',
      );
    }
    return deviceId;
  }

  static ProvisioningStatus parseStatus(Uint8List response) {
    final json = _decodeObject(response);
    final state = _requiredString(json, 'state');
    final deviceId = _deviceId(json);
    switch (state) {
      case 'idle':
        return ProvisioningStatus(
          state: ProvisioningState.idle,
          deviceId: deviceId,
        );
      case 'in_progress':
        return ProvisioningStatus(
          state: ProvisioningState.inProgress,
          deviceId: deviceId,
        );
      case 'done':
        final status = _requiredString(json, 'status');
        if (status != 'SUCCESS' && status != 'WARNING' && status != 'ERROR') {
          throw FormatException(
            'Trạng thái provisioning không hợp lệ: $status',
          );
        }
        final saved = json['saved'];
        final attempts = json['attempts'];
        if (saved is! bool || attempts is! int || attempts < 0) {
          throw const FormatException(
            'Kết quả provisioning thiếu saved/attempts hợp lệ',
          );
        }
        return ProvisioningStatus(
          state: ProvisioningState.done,
          deviceId: deviceId,
          status: status,
          saved: saved,
          attempts: attempts,
          maxSensorCount: _optionalCount(json, 'max_sensor_count'),
          maxLoadCount: _optionalCount(json, 'max_load_count'),
          code: _optionalString(json, 'code'),
          reason: _optionalString(json, 'reason'),
          message: _optionalString(json, 'message'),
        );
      default:
        throw FormatException('Trạng thái provisioning không hợp lệ: $state');
    }
  }

  static Map<String, dynamic> _decodeObject(Uint8List response) {
    final decoded = jsonDecode(utf8.decode(response, allowMalformed: true));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Phản hồi provisioning không phải JSON object',
      );
    }
    return decoded;
  }

  static String _deviceId(Map<String, dynamic> json) {
    final deviceId = _requiredString(json, 'device_id');
    if (!RegExp(r'^[0-9a-f]{12}$').hasMatch(deviceId)) {
      throw const FormatException('device_id provisioning không hợp lệ');
    }
    return deviceId;
  }

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Phản hồi provisioning thiếu $key hợp lệ');
    }
    return value;
  }

  static String? _optionalString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String) {
      throw FormatException('Trường provisioning $key không hợp lệ');
    }
    return value;
  }

  static int? _optionalCount(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! int || value < 0) {
      throw FormatException('Trường provisioning $key không hợp lệ');
    }
    return value;
  }
}

enum ProvisioningState { idle, inProgress, done }

class ProvisioningStatus {
  const ProvisioningStatus({
    required this.state,
    required this.deviceId,
    this.status,
    this.saved,
    this.attempts,
    this.maxSensorCount,
    this.maxLoadCount,
    this.code,
    this.reason,
    this.message,
  });

  final ProvisioningState state;
  final String deviceId;
  final String? status;
  final bool? saved;
  final int? attempts;
  final int? maxSensorCount;
  final int? maxLoadCount;
  final String? code;
  final String? reason;
  final String? message;
}
