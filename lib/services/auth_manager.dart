import 'dart:async';

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

  /// 用户资料变化广播（昵称/头像/手机号更新、登录/退出），
  /// 显示层订阅即时刷新（如改绑手机号后各返回页同步显示新号）。
  final _changesCtrl = StreamController<void>.broadcast();

  Stream<void> get changes => _changesCtrl.stream;

  void _emitChange() {
    if (!_changesCtrl.isClosed) _changesCtrl.add(null);
  }

  /// 401 跳转去重：并发请求同时 401 时只 push 一次登录页。
  bool _redirectingToLogin = false;

  static const _kUserId = 'auth.user_id';
  static const _kAccessToken = 'auth.access_token';
  static const _kRefreshToken = 'auth.refresh_token';
  static const _kExpiresTime = 'auth.expires_time';
  static const _kOpenid = 'auth.openid';
  static const _kNickname = 'auth.nickname';
  static const _kAvatar = 'auth.avatar';
  static const _kMobile = 'auth.mobile';
  static const _kImCode = 'auth.im_code';

  int? userId;
  String? accessToken;
  String? refreshToken;
  String? expiresTime;
  String? openid;

  /// 登录用户昵称/头像/手机号/IM号（来自 /member/user/get，null=未加载）。
  String? nickname;
  String? avatar;
  String? mobile;

  /// IM 号（member/user/get 的 code 字段，用户唯一业务号）。
  String? imCode;

  bool get isLoggedIn => accessToken != null && accessToken!.isNotEmpty;

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
    mobile = prefs.getString(_kMobile);
    imCode = prefs.getString(_kImCode);
  }

  /// 更新登录用户资料（昵称/头像/手机号/IM号，来自用户中心接口）。
  Future<void> updateProfile({
    required String nickname,
    required String avatar,
    String? mobile,
    String? imCode,
  }) async {
    this.nickname = nickname;
    this.avatar = avatar;
    if (mobile != null) this.mobile = mobile;
    if (imCode != null) this.imCode = imCode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kNickname, nickname);
    await prefs.setString(_kAvatar, avatar);
    if (mobile != null) await prefs.setString(_kMobile, mobile);
    if (imCode != null) await prefs.setString(_kImCode, imCode);
    _emitChange();
  }

  /// 更新绑定手机号（修改绑定手机号成功后调用，仅更新本地缓存）。
  Future<void> updateMobile(String mobile) async {
    this.mobile = mobile;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMobile, mobile);
    _emitChange();
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
    mobile = null;
    imCode = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs
        .remove(_kUserId)
        .then((_) => prefs.remove(_kAccessToken))
        .then((_) => prefs.remove(_kRefreshToken))
        .then((_) => prefs.remove(_kExpiresTime))
        .then((_) => prefs.remove(_kOpenid))
        .then((_) => prefs.remove(_kNickname))
        .then((_) => prefs.remove(_kAvatar))
        .then((_) => prefs.remove(_kMobile))
        .then((_) => prefs.remove(_kImCode));
    _emitChange();
  }
}
