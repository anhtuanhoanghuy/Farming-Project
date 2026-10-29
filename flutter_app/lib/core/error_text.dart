import '../protocol/mqtt_ack.dart';
import '../state/developer_access_controller.dart';

/// Message of [error] for the user, without the Dart type prefix.
String errorText(Object error) => switch (error) {
  MqttCommandException(:final message) => message,
  FormatException(:final message) => message,
  StateError(:final message) => message,
  _ => '$error',
};

/// Keeps exception details out of normal user-facing messages.
String userErrorText(String summary, Object error) =>
    DeveloperAccessController.instance.hasAccess
    ? '$summary: ${errorText(error)}'
    : summary;
