import 'package:shared_preferences/shared_preferences.dart';

/// 登录态管理：内存 + shared_preferences 持久化。
/// 注册/登录成功后保存 token，退出登录时清除。
class AuthManager {
  AuthManager._();

  static final AuthManager instance = AuthManager._();

  static const _kUserId = 'auth.user_id';
  static const _kAccessToken = 'auth.access_token';
  static const _kRefreshToken = 'auth.refresh_token';
  static const _kExpiresTime = 'auth.expires_time';
  static const _kOpenid = 'auth.openid';

  int? userId;
  String? accessToken;
  String? refreshToken;
  String? expiresTime;
  String? openid;

  bool get isLoggedIn => accessToken != null && accessToken!.isNotEmpty;

  /// App 启动时调用，从磁盘恢复登录态。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    userId = prefs.getInt(_kUserId);
    accessToken = prefs.getString(_kAccessToken);
    refreshToken = prefs.getString(_kRefreshToken);
    expiresTime = prefs.getString(_kExpiresTime);
    openid = prefs.getString(_kOpenid);
  }

  /// 注册/登录成功后保存。
  Future<void> save({
    required int userId,
    required String accessToken,
    required String refreshToken,
    String? expiresTime,
    String? openid,
  }) async {
    this.userId = userId;
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    this.expiresTime = expiresTime;
    this.openid = openid;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kUserId, userId);
    await prefs.setString(_kAccessToken, accessToken);
    await prefs.setString(_kRefreshToken, refreshToken);
    if (expiresTime != null) {
      await prefs.setString(_kExpiresTime, expiresTime);
    }
    if (openid != null) {
      await prefs.setString(_kOpenid, openid);
    }
  }

  /// 退出登录时清除。
  Future<void> clear() async {
    userId = null;
    accessToken = null;
    refreshToken = null;
    expiresTime = null;
    openid = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs
        .remove(_kUserId)
        .then((_) => prefs.remove(_kAccessToken))
        .then((_) => prefs.remove(_kRefreshToken))
        .then((_) => prefs.remove(_kExpiresTime))
        .then((_) => prefs.remove(_kOpenid));
  }
}
