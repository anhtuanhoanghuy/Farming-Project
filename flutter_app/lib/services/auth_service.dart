import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_config.dart';

class AuthService {
  AuthService._();

  static SupabaseClient get _client => Supabase.instance.client;

  static Future<void> init() {
    if (!isConfigured) return Future.value();
    return Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
    );
  }

  static bool get isConfigured =>
      !AppConfig.supabaseUrl.contains('YOUR_') &&
      !AppConfig.supabaseAnonKey.contains('YOUR_');

  /// Session is persisted by supabase_flutter and restored on app start.
  static bool get isSignedIn =>
      isConfigured && _client.auth.currentSession != null;

  static String? get userId =>
      isConfigured ? _client.auth.currentUser?.id : null;

  /// The Supabase user id; every device/CRUD operation belongs to this account.
  static String requireUserId() =>
      userId ?? (throw StateError('Chưa đăng nhập Supabase'));

  static String? get email => _client.auth.currentUser?.email;

  static Stream<AuthState> get onAuthStateChange =>
      _client.auth.onAuthStateChange;

  static Future<void> signInWithGoogle() async {
    if (!isConfigured) {
      throw StateError('Chưa cấu hình Supabase trong app_config.dart');
    }
    final google = GoogleSignIn.instance;
    await google.initialize(
      clientId: AppConfig.googleIosClientId.isEmpty
          ? null
          : AppConfig.googleIosClientId,
      serverClientId: AppConfig.googleWebClientId,
    );
    final user = await google.authenticate();
    final idToken = user.authentication.idToken;
    if (idToken == null) throw StateError('Không lấy được Google ID token');

    final authorization =
        await user.authorizationClient.authorizationForScopes(_scopes) ??
        await user.authorizationClient.authorizeScopes(_scopes);

    await _client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
      accessToken: authorization.accessToken,
    );
  }

  static const _scopes = ['email', 'profile'];

  static Future<void> signOut() async {
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
    await _client.auth.signOut();
  }
}
