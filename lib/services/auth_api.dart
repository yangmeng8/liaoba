import 'package:dio/dio.dart';

import '../shared/json_utils.dart';
import 'api_client.dart';
import 'auth_manager.dart';

/// 短信验证码发送场景（对应后端 SmsSceneEnum）。
class SmsScene {
  /// 用户(手机)登录/注册
  static const int memberLogin = 1;

  /// 重置密码
  static const int resetPassword = 4;
}

/// 会员认证相关接口。
class AuthApi {
  /// 发送手机短信验证码。
  /// [scene] 对应后端 SmsSceneEnum：1=用户(手机)登录/注册。
  static Future<bool> sendSmsCode({
    required String mobile,
    int scene = SmsScene.memberLogin,
  }) async {
    final resp = await ApiClient.dio.post(
      '/admin-api/member/auth/send-sms-code',
      data: {'mobile': mobile, 'scene': scene},
    );
    final data = ApiClient.unwrap(resp);
    return data == true;
  }

  /// 手机 + 验证码 + 密码注册。
  /// 成功返回后端登录结果（userId、accessToken 等），已自动保存到 [AuthManager]。
  static Future<void> smsRegister({
    required String mobile,
    required String code,
    required String password,
    String? nickname,
    String? captcha,
    String region = '',
  }) async {
    final resp = await ApiClient.dio.post(
      '/admin-api/member/auth/sms-register',
      data: {
        'mobile': mobile,
        'code': code,
        'password': password,
        if (nickname != null && nickname.isNotEmpty) 'nickname': nickname,
        if (captcha != null && captcha.isNotEmpty) 'captcha': captcha,
        'region': region,
      },
    );
    final data = ApiClient.unwrap(resp);
    if (data is Map) {
      await AuthManager.instance.save(
        userId: asInt(data['userId']),
        accessToken: (data['accessToken'] ?? '').toString(),
        refreshToken: (data['refreshToken'] ?? '').toString(),
        expiresTime: data['expiresTime']?.toString(),
        openid: data['openid']?.toString(),
      );
    }
  }

  /// 手机 + 验证码快捷登录。成功后自动保存登录态。
  static Future<void> smsLogin({
    required String mobile,
    required String code,
  }) async {
    final resp = await ApiClient.dio.post(
      '/admin-api/member/auth/sms-login',
      data: {'mobile': mobile, 'code': code},
    );
    await _saveLoginResp(resp);
  }

  /// 手机 + 密码登录。成功后自动保存登录态。
  static Future<void> passwordLogin({
    required String mobile,
    required String password,
  }) async {
    final resp = await ApiClient.dio.post(
      '/admin-api/system/auth/login',
      data: {'username': mobile, 'password': password},
    );
    await _saveLoginResp(resp);
  }

  /// 重置密码（忘记密码）。成功返回 true。
  static Future<bool> resetPassword({
    required String mobile,
    required String code,
    required String password,
  }) async {
    final resp = await ApiClient.dio.put(
      '/admin-api/member/user/reset-password',
      data: {'mobile': mobile, 'code': code, 'password': password},
    );
    final data = ApiClient.unwrap(resp);
    return data == true;
  }

  /// 退出登录。服务端使当前 token 失效，成功返回 true。
  static Future<bool> logout() async {
    final resp = await ApiClient.dio.post(
      '/admin-api/member/auth/logout',
    );
    final data = ApiClient.unwrap(resp);
    return data == true;
  }

  /// 解析登录接口返回并保存登录态。
  static Future<void> _saveLoginResp(Response resp) async {
    final data = ApiClient.unwrap(resp);
    if (data is Map) {
      await AuthManager.instance.save(
        userId: asInt(data['userId']),
        accessToken: (data['accessToken'] ?? '').toString(),
        refreshToken: (data['refreshToken'] ?? '').toString(),
        expiresTime: data['expiresTime']?.toString(),
        openid: data['openid']?.toString(),
      );
    }
  }

  /// 拉取登录用户资料（昵称/头像/权限码）并缓存（对应 H5 登录后调用的权限信息接口）。
  static Future<void> loadUserProfile() async {
    final resp = await ApiClient.dio
        .get('/admin-api/system/auth/get-permission-info');
    final data = ApiClient.unwrap(resp);
    final user = data is Map ? data['user'] : null;
    if (user is Map) {
      await AuthManager.instance.updateProfile(
        nickname: (user['nickname'] ?? '').toString(),
        avatar: (user['avatar'] ?? '').toString(),
      );
    }
    // 权限码列表（管理端功能显隐用；超级管理员为 ["*:*:*"]）
    final perms = data is Map ? data['permissions'] : null;
    if (perms is List) {
      AuthManager.instance.permissions =
          perms.map((e) => e.toString()).toList();
    }
  }

  /// 获得用户精简资料（昵称/头像/性别/部门；点头像弹资料页场景，免鉴权）。
  static Future<SimpleUser?> getSimpleUser(int id) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/system/user/get-simple',
      queryParameters: {'id': id},
    );
    final data = ApiClient.unwrap(resp);
    if (data is! Map<String, dynamic>) return null;
    return SimpleUser.fromJson(data);
  }

  /// 全量精简用户列表（添加好友的用户选择器用；
  /// 客户端本地搜索 + 隐藏自己 + 已好友置灰）。
  static Future<List<SimpleUser>> getSimpleUserList() async {
    final resp = await ApiClient.dio
        .get('/admin-api/system/user/simple-list');
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => SimpleUser.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}

/// 用户精简资料（对应后端 UserSimpleRespVO）。
class SimpleUser {
  final int id;
  final String nickname;
  final String avatar;

  /// 性别（1=男 2=女；0 未设置）。
  final int sex;
  final String deptName;

  const SimpleUser({
    required this.id,
    required this.nickname,
    required this.avatar,
    this.sex = 0,
    this.deptName = '',
  });

  factory SimpleUser.fromJson(Map<String, dynamic> json) => SimpleUser(
    id: json['id'] is int
        ? json['id'] as int
        : int.tryParse('${json['id']}') ?? 0,
    nickname: (json['nickname'] ?? '').toString(),
    avatar: (json['avatar'] ?? '').toString(),
    sex: json['sex'] is int ? json['sex'] as int : int.tryParse('${json['sex']}') ?? 0,
    deptName: (json['deptName'] ?? '').toString(),
  );

  /// 性别文案（0 未设置返回空）。
  String get sexLabel => switch (sex) {
    1 => '男',
    2 => '女',
    _ => '',
  };
}
