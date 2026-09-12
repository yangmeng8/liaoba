import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shared/group_avatar.dart';
import 'im_websocket.dart';

/// 登录态管理：内存 + shared_preferences 持久化。
/// 注册/登录成功后保存 token，退出登录时清除。
class AuthManager {
  AuthManager._();

  static final AuthManager instance = AuthManager._();

  /// 全局导航 Key（main.dart 注入），401 时用于从任意页面跳回登录页。
  GlobalKey<NavigatorState>? rootNavigatorKey;

  /// 401 跳转去重：并发请求同时 401 时只 push 一次登录页。
  bool _redirectingToLogin = false;

  static const _kUserId = 'auth.user_id';
  static const _kAccessToken = 'auth.access_token';
  static const _kRefreshToken = 'auth.refresh_token';
  static const _kExpiresTime = 'auth.expires_time';
  static const _kOpenid = 'auth.openid';
  static const _kNickname = 'auth.nickname';
  static const _kAvatar = 'auth.avatar';

  int? userId;
  String? accessToken;
  String? refreshToken;
  String? expiresTime;
  String? openid;

  /// 登录用户昵称/头像（来自 /system/auth/get-permission-info，null=未加载）。
  String? nickname;
  String? avatar;

  /// 登录用户权限码列表（来自 get-permission-info 的 permissions；
  /// 超级管理员为 ["*:*:*"]，内存缓存，登出时清空）。
  List<String> permissions = [];

  bool get isLoggedIn => accessToken != null && accessToken!.isNotEmpty;

  /// 是否拥有指定权限码（对应 H5 hasAccessByCodes，传任一命中即 true）；
  /// 支持超级管理员通配 "*:*:*" 与前缀通配 "system:*"。
  bool hasAccess(String code) {
    if (code.isEmpty) return false;
    for (final p in permissions) {
      if (p == code || p == '*:*:*') return true;
      // 前缀段通配：system:notice:* 命中 system:notice:query
      if (p.endsWith(':*') && code.startsWith(p.substring(0, p.length - 1))) {
        return true;
      }
    }
    return false;
  }

  /// App 启动时调用，从磁盘恢复登录态。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    userId = prefs.getInt(_kUserId);
    accessToken = prefs.getString(_kAccessToken);
    refreshToken = prefs.getString(_kRefreshToken);
    expiresTime = prefs.getString(_kExpiresTime);
    openid = prefs.getString(_kOpenid);
    nickname = prefs.getString(_kNickname);
    avatar = prefs.getString(_kAvatar);
  }

  /// 更新登录用户资料（昵称/头像，来自权限信息接口）。
  Future<void> updateProfile({required String nickname, required String avatar}) async {
    this.nickname = nickname;
    this.avatar = avatar;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kNickname, nickname);
    await prefs.setString(_kAvatar, avatar);
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
    // 登录成功：重置 401 跳转标志，允许下次失效再跳
    _redirectingToLogin = false;
  }

  /// 接口返回 401（账号未登录/登录态失效）时的统一处理：
  /// 清除登录态 + 断开 IM 长连接 + 清栈跳转登录页（去重，防并发 401 重复 push）。
  Future<void> handleUnauthorized() async {
    if (_redirectingToLogin) return;
    _redirectingToLogin = true;
    await clear();
    // 清空群头像成员表缓存（重新登录后按新账号拉取）
    GroupAvatar.clearCache();
    // token 已失效，长连接停止重连（重新登录后 ensure() 会重建）
    ImWebSocket.instance.disconnect();
    final nav = rootNavigatorKey?.currentState;
    if (nav != null && nav.mounted) {
      nav.pushNamedAndRemoveUntil('/login', (route) => false);
    }
  }

  /// 退出登录时清除。
  Future<void> clear() async {
    userId = null;
    accessToken = null;
    refreshToken = null;
    expiresTime = null;
    openid = null;
    nickname = null;
    avatar = null;
    permissions = [];

    final prefs = await SharedPreferences.getInstance();
    await prefs
        .remove(_kUserId)
        .then((_) => prefs.remove(_kAccessToken))
        .then((_) => prefs.remove(_kRefreshToken))
        .then((_) => prefs.remove(_kExpiresTime))
        .then((_) => prefs.remove(_kOpenid))
        .then((_) => prefs.remove(_kNickname))
        .then((_) => prefs.remove(_kAvatar));
  }
}
