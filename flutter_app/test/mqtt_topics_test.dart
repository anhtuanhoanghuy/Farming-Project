import 'package:flutter_app/core/app_config.dart';
import 'package:flutter_app/protocol/mqtt_topics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses the configured broker endpoint without authentication or TLS', () {
    expect(AppConfig.mqttHost, '103.98.150.157');
    expect(AppConfig.mqttPort, 1883);
    expect(AppConfig.mqttTls, isFalse);
    expect(AppConfig.mqttUsername, isEmpty);
    expect(AppConfig.mqttPassword, isEmpty);
  });

  test('builds exactly the four controller topics', () {
    final topics = MqttDeviceTopics.forDevice(
      userId: 'user-1',
      deviceId: 'aabbccddeeff',
    );

    expect(topics.telemetry, 'v1/user-1/devices/aabbccddeeff/telemetry');
    expect(topics.commands, 'v1/user-1/devices/aabbccddeeff/commands');
    expect(topics.ack, 'v1/user-1/devices/aabbccddeeff/ack');
    expect(topics.status, 'v1/user-1/devices/aabbccddeeff/status');
    expect(MqttDeviceTopicKind.values, hasLength(4));
    // The app listens to everything except what it publishes.
    expect(topics.subscriptions, [topics.telemetry, topics.ack, topics.status]);
  });

  test('routes only a known-user device topic and message kind', () {
    const topic = 'v1/user-1/devices/aabbccddeeff/telemetry';
    expect(
      MqttDeviceTopics.deviceIdFromTopic(topic, userId: 'user-1'),
      'aabbccddeeff',
    );
    expect(
      MqttDeviceTopics.kindFromTopic(topic),
      MqttDeviceTopicKind.telemetry,
    );
    expect(MqttDeviceTopics.deviceIdFromTopic(topic, userId: 'user-2'), isNull);
    expect(
      MqttDeviceTopics.deviceIdFromTopic(
        'v1/user-1/devices/aabbccddeeff/other',
        userId: 'user-1',
      ),
      isNull,
    );
    expect(
      MqttDeviceTopics.deviceIdFromTopic(
        'v1/user-1/devices/aabbccddeeff/config/set',
        userId: 'user-1',
      ),
      isNull,
    );
  });

  test('accepts a 36-character Supabase user id and rejects longer ones', () {
    const uuid = '4a951ba9-1c2d-4e3f-8a4b-0123456789ab';
    final topics = MqttDeviceTopics.forDevice(
      userId: uuid,
      deviceId: 'aabbccddeeff',
    );
    expect(topics.commands, 'v1/$uuid/devices/aabbccddeeff/commands');
    expect(
      MqttDeviceTopics.deviceIdFromTopic(topics.status, userId: uuid),
      'aabbccddeeff',
    );
    expect(
      () => MqttDeviceTopics.forDevice(
        userId: '${uuid}x',
        deviceId: 'aabbccddeeff',
      ),
      throwsArgumentError,
    );
  });

  test('rejects empty and wildcard topic segments', () {
    expect(
      () => MqttDeviceTopics.forDevice(userId: '', deviceId: 'device-1'),
      throwsArgumentError,
    );
    expect(
      () => MqttDeviceTopics.forDevice(userId: 'user-1', deviceId: 'a/#'),
      throwsArgumentError,
    );
    expect(
      () => MqttDeviceTopics.forDevice(
        userId: 'user-1',
        deviceId: 'AA:BB:CC:DD:EE:FF',
      ),
      throwsArgumentError,
    );
  });
}
