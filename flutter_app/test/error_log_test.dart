import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_app/protocol/device_log.dart';
import 'package:flutter_app/protocol/mqtt_ack.dart';
import 'package:flutter_app/protocol/mqtt_payloads.dart';
import 'package:flutter_app/protocol/mqtt_topics.dart';
import 'package:flutter_app/screens/console_screen.dart';
import 'package:flutter_app/screens/error_log_tab.dart';
import 'package:flutter_app/services/device_error_log.dart';
import 'package:flutter_app/services/mqtt_session_manager.dart';
import 'package:flutter_app/theme/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sample_messages.dart';

Map<String, Object?> _entry(int seq, String level, String msg) => {
  'seq': seq,
  'boot': 3,
  'level': level,
  'uptime_ms': 61000,
  'msg': msg,
};

/// A fake ESP32 holding [total] log lines, answering GET_LOGS 2 per page.
class _FakeEsp {
  _FakeEsp(this.total);

  final int total;
  final messages = StreamController<MqttDeviceMessage>.broadcast();
  final requests = <Map<String, Object?>>[];

  Future<MqttAck> send(
    String deviceId,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    requests.add(payload);
    final start = payload['start_seq']! as int;
    final end = (start + 2).clamp(0, total);
    scheduleMicrotask(() {
      messages.add(
        MqttDeviceMessage(
          deviceId: deviceId,
          topic: 'v1/u/devices/$deviceId/status',
          kind: MqttDeviceTopicKind.status,
          payload: jsonEncode({
            'v': 1,
            'type': 'LOGS',
            'cmd_id': payload['cmd_id'],
            'next_seq': end,
            'more': end < total,
            'entries': [
              for (var i = start; i < end; i++)
                _entry(i, i.isEven ? 'E' : 'W', 'tag: line $i'),
            ],
          }),
          receivedAt: DateTime.now(),
        ),
      );
    });
    return MqttAck(
      cmdId: payload['cmd_id']! as String,
      result: 'ok',
      code: 'OK',
    );
  }
}

void main() {
  group('GET_LOGS payload', () {
    test('builds command with paging fields', () {
      final p = MqttPayloads.getLogs(cmdId: 'abc', startSeq: 7, limit: 10);
      expect(p['type'], 'GET_LOGS');
      expect(p['start_seq'], 7);
      expect(p['limit'], 10);
      expect(
        () => MqttPayloads.getLogs(cmdId: 'abc', limit: 26),
        throwsArgumentError,
      );
      expect(
        () => MqttPayloads.getLogs(cmdId: 'abc', startSeq: -1),
        throwsArgumentError,
      );
    });

    test('parses a LOGS page and skips malformed entries', () {
      final page = DeviceLogPage.tryParse({
        'type': 'LOGS',
        'cmd_id': 'x',
        'next_seq': 3,
        'more': true,
        'entries': [
          _entry(1, 'E', 'crash: task=a'),
          {'seq': 'bad'},
        ],
      })!;
      expect(page.entries, hasLength(1));
      expect(page.entries.single.isError, isTrue);
      expect(page.nextSeq, 3);
      expect(page.more, isTrue);
      expect(DeviceLogPage.tryParse({'type': 'SNAPSHOT'}), isNull);
    });
  });

  group('DeviceErrorLog', () {
    test('pages until more is false', () async {
      final esp = _FakeEsp(5);
      final service = DeviceErrorLog(
        messages: esp.messages.stream,
        sender: esp.send,
      );
      await service.load(deviceId);
      expect(service.statusOf(deviceId), DeviceErrorLogStatus.loaded);
      expect(service.entriesOf(deviceId).map((e) => e.seq), [0, 1, 2, 3, 4]);
      expect(esp.requests.map((r) => r['start_seq']), [0, 2, 4]);
    });

    test('reports a refused command', () async {
      final service = DeviceErrorLog(
        messages: const Stream.empty(),
        sender: (id, payload, {timeout = const Duration(seconds: 5)}) async =>
            throw MqttCommandException.rejected(
              const MqttAck(
                cmdId: 'x',
                result: 'error',
                code: 'UNSUPPORTED_ACTION',
              ),
            ),
      );
      await service.load(deviceId);
      expect(service.statusOf(deviceId), DeviceErrorLogStatus.failed);
      expect(service.errorOf(deviceId), contains('chưa hỗ trợ'));
    });

    test('fails when the LOGS message never arrives', () async {
      final esp = _FakeEsp(1);
      final service = DeviceErrorLog(
        messages: const Stream.empty(),
        sender: esp.send,
        pageTimeout: const Duration(milliseconds: 50),
      );
      await service.load(deviceId);
      expect(service.statusOf(deviceId), DeviceErrorLogStatus.failed);
    });
  });

  group('Nhật ký kỹ thuật screen', () {
    testWidgets('error tab lists entries newest first', (tester) async {
      final esp = _FakeEsp(3);
      final service = DeviceErrorLog(
        messages: esp.messages.stream,
        sender: esp.send,
      );
      await tester.runAsync(() => service.load(deviceId));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ErrorLogTab(
              deviceId: deviceId,
              service: service,
              autoLoad: false,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('tag: line 0'), findsOneWidget);
      expect(find.text('tag: line 2'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('tag: line 2')).dy,
        lessThan(tester.getTopLeft(find.text('tag: line 0')).dy),
      );
    });

    testWidgets('opens on Console realtime, switches to Nhật ký lỗi', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const ConsoleScreen(
            inShell: false,
            args: ConsoleArgs(name: 'Ao nuôi A1', deviceId: deviceId),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Console realtime'), findsOneWidget);
      expect(find.text('Chưa có bản tin nào'), findsOneWidget);
      expect(find.text('Nhật ký lỗi lưu trong bộ nhớ thiết bị'), findsNothing);

      await tester.tap(find.text('Nhật ký lỗi'));
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Nhật ký lỗi lưu trong bộ nhớ thiết bị'),
        findsOneWidget,
      );
    });
  });
}
