/// Values the firmware contract leaves open; see docs/requirement.md §20.
class AppConfig {
  AppConfig._();

  static const appVersion = '1.0.0';

  /// Supabase project settings; pass with --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://widjujyotyhjelcsprqe.supabase.co',
  );
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_E4cndQzEl6ZP9XqRM-QDuA_RXTjLC1z',
  );

  /// Google Cloud "Web application" OAuth client ID (the same one configured in Supabase Google provider).
  static const googleWebClientId =
      '999197274849-3kqfrvo87velphtnuph933bmuoq8bub2.apps.googleusercontent.com';

  /// Google Cloud "iOS" OAuth client ID; only needed on iOS.
  static const googleIosClientId = '';

  /// Protocomm Sec1 proof-of-possession; temporary value until the firmware contract is final (Q10).
  static const pop = 'abcd1234';

  /// Broker defaults are the current deployment endpoint. Override with
  /// --dart-define=MQTT_HOST=... --dart-define=MQTT_PORT=... if needed.
  static const mqttHost = String.fromEnvironment(
    'MQTT_HOST',
    defaultValue: '103.98.150.157',
  );
  static const mqttTls = bool.fromEnvironment('MQTT_TLS', defaultValue: false);
  static const mqttPort = int.fromEnvironment('MQTT_PORT', defaultValue: 1883);
  static const mqttUsername = String.fromEnvironment('MQTT_USERNAME');
  static const mqttPassword = String.fromEnvironment('MQTT_PASSWORD');

  static bool get isMqttConfigured => mqttHost.trim().isNotEmpty;
}
