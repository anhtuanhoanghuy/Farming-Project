/// ACK of the `ack` topic: the ESP32 answers each valid command once, after it
/// has applied (and stored) it.
class MqttAck {
  const MqttAck({
    required this.cmdId,
    required this.result,
    required this.code,
    this.reason,
    this.cmd,
    this.bootId,
    this.dup = false,
    this.ts,
  });

  factory MqttAck.fromJson(Map<String, Object?> json) {
    final cmdId = json['cmd_id'];
    final result = json['result'];
    final code = json['code'];
    final type = json['type'];
    if (cmdId is! String ||
        result is! String ||
        code is! String ||
        (type != null && type != 'ACK')) {
      throw const FormatException(
        'MQTT ACK must be type ACK with string cmd_id, result and code fields',
      );
    }
    return MqttAck(
      cmdId: cmdId,
      result: result,
      code: code,
      reason: json['reason'] is String ? json['reason'] as String : null,
      cmd: json['cmd'] is String ? json['cmd'] as String : null,
      bootId: json['boot_id'] is String ? json['boot_id'] as String : null,
      dup: json['dup'] == true,
      ts: json['ts'] is num ? (json['ts'] as num).toInt() : null,
    );
  }

  final String cmdId;

  /// `ok` or `error`.
  final String result;

  /// `OK`, `INVALID_VALUE`, `CONFLICT`, `BUSY`, ... (section 6.3).
  final String code;
  final String? reason;

  /// Name of the command the ESP32 processed.
  final String? cmd;
  final String? bootId;

  /// True when the ESP32 answered a repeated `cmd_id` with the old ACK.
  final bool dup;
  final int? ts;

  bool get isSuccess => result == 'ok';

  /// What the user sees when the ESP32 refuses a command.
  String get errorMessage {
    final detail = reason == null || reason!.isEmpty ? '' : ' ($reason)';
    return 'Thiết bị từ chối: $code$detail';
  }
}

/// A command that did not complete: no connection, no ACK in time, or an
/// error ACK ([ack] is set then). [message] is ready to show to the user.
class MqttCommandException implements Exception {
  const MqttCommandException(this.message, {this.ack});

  factory MqttCommandException.rejected(MqttAck ack) =>
      MqttCommandException(ack.errorMessage, ack: ack);

  final String message;
  final MqttAck? ack;

  /// ACK `code` when the ESP32 refused the command.
  String? get code => ack?.code;
  String? get reason => ack?.reason;

  @override
  String toString() => message;
}
