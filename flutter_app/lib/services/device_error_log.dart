import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../protocol/device_log.dart';
import '../protocol/mqtt_ack.dart';
import '../protocol/mqtt_payloads.dart';
import '../protocol/mqtt_topics.dart';
import 'mqtt_session_manager.dart';

typedef LogCommandSender =
    Future<MqttAck> Function(
      String deviceId,
      Map<String, Object?> payload, {
      Duration timeout,
    });

enum DeviceErrorLogStatus { idle, loading, loaded, failed }

/// Reads the persistent error log of an ESP32 over MQTT: sends `GET_LOGS`,
/// takes the `LOGS` message with the same `cmd_id` and repeats with
/// `start_seq = next_seq` until `more` is false.
class DeviceErrorLog extends ChangeNotifier {
  DeviceErrorLog({
    Stream<MqttDeviceMessage>? messages,
    LogCommandSender? sender,
    this.pageTimeout = const Duration(seconds: 6),
  }) : _messages = messages,
       _sender = sender;

  static final instance = DeviceErrorLog();

  /// The flash ring holds about 2000 lines (25 per page).
  static const maxPages = 100;

  final Stream<MqttDeviceMessage>? _messages;
  final LogCommandSender? _sender;
  final Duration pageTimeout;

  final _entries = <String, List<DeviceLogEntry>>{};
  final _status = <String, DeviceErrorLogStatus>{};
  final _errors = <String, String>{};
  final _truncated = <String>{};

  /// Oldest first.
  List<DeviceLogEntry> entriesOf(String deviceId) =>
      _entries[deviceId] ?? const [];

  DeviceErrorLogStatus statusOf(String deviceId) =>
      _status[deviceId] ?? DeviceErrorLogStatus.idle;

  String? errorOf(String deviceId) => _errors[deviceId];

  /// True when [maxPages] was reached before the end of the log.
  bool isTruncated(String deviceId) => _truncated.contains(deviceId);

  Future<void> load(String deviceId) async {
    if (statusOf(deviceId) == DeviceErrorLogStatus.loading) return;
    final entries = <DeviceLogEntry>[];
    _entries[deviceId] = entries;
    _errors.remove(deviceId);
    _truncated.remove(deviceId);
    _status[deviceId] = DeviceErrorLogStatus.loading;
    notifyListeners();
    try {
      var start = 0;
      for (var page = 0; ; page++) {
        final result = await _requestPage(deviceId, start);
        entries.addAll(result.entries);
        notifyListeners();
        if (!result.more || result.entries.isEmpty || result.nextSeq <= start) {
          break;
        }
        if (page + 1 >= maxPages) {
          _truncated.add(deviceId);
          break;
        }
        start = result.nextSeq;
      }
      _status[deviceId] = DeviceErrorLogStatus.loaded;
    } on MqttCommandException catch (error) {
      _fail(deviceId, _describe(error));
    } catch (error) {
      _fail(deviceId, 'Không đọc được nhật ký lỗi: $error');
    }
    notifyListeners();
  }

  void _fail(String deviceId, String message) {
    _errors[deviceId] = message;
    _status[deviceId] = DeviceErrorLogStatus.failed;
  }

  String _describe(MqttCommandException error) {
    if (error.code == 'UNSUPPORTED_ACTION') {
      return 'Firmware của thiết bị chưa hỗ trợ đọc nhật ký lỗi.';
    }
    return error.message;
  }

  Future<DeviceLogPage> _requestPage(String deviceId, int startSeq) async {
    final cmdId = MqttPayloads.newCommandId();
    final completer = Completer<DeviceLogPage>();
    final stream = _messages ?? MqttSessionManager.instance.messages;
    final subscription = stream.listen((message) {
      if (message.deviceId != deviceId ||
          message.kind != MqttDeviceTopicKind.status ||
          completer.isCompleted) {
        return;
      }
      try {
        final json = jsonDecode(message.payload);
        if (json is! Map<String, Object?>) return;
        final page = DeviceLogPage.tryParse(json);
        if (page != null && page.cmdId == cmdId) completer.complete(page);
      } on FormatException {
        return;
      }
    });
    try {
      final sender =
          _sender ?? MqttSessionManager.instance.publishCommandAndWaitForAck;
      await sender(
        deviceId,
        MqttPayloads.getLogs(cmdId: cmdId, startSeq: startSeq),
        timeout: pageTimeout,
      );
      return await completer.future.timeout(
        pageTimeout,
        onTimeout: () => throw const MqttCommandException(
          'Thiết bị đã nhận lệnh nhưng không gửi dữ liệu nhật ký '
          '(có thể đang mất kết nối MQTT).',
        ),
      );
    } finally {
      await subscription.cancel();
    }
  }
}
