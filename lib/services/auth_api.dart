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
  /// [tenantId]：注册流程传 0（后端要求），登录/忘记密码默认租户 1。
  static Future<bool> sendSmsCode({
    required String mobile,
    int scene = SmsScene.memberLogin,
    int? tenantId,
  }) async {
    final resp = await ApiClient.dio.post(
      '/app-api/member/auth/send-sms-code',
      data: {'mobile': mobile, 'scene': scene},
      options: tenantId == null
          ? null
          : Options(headers: {'tenant-id': tenantId}),
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
      '/app-api/member/auth/sms-register',
      // 注册接口后端要求 tenant-id=0（其余场景租户 1）
      options: Options(headers: {'tenant-id': 0}),
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
      '/app-api/member/auth/sms-login',
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
      '/app-api/member/auth/login',
      // member 体系登录参数为 mobile（原 system 体系用 username）
      data: {'mobile': mobile, 'password': password},
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
      '/app-api/member/user/reset-password',
      data: {'mobile': mobile, 'code': code, 'password': password},
    );
    final data = ApiClient.unwrap(resp);
    return data == true;
  }

  /// 退出登录。服务端使当前 token 失效，成功返回 true。
  static Future<bool> logout() async {
    final resp = await ApiClient.dio.post(
      '/app-api/member/auth/logout',
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

  /// 拉取登录用户资料（昵称/头像/手机号）并缓存。
  /// app 端走 member 体系用户中心接口（app-api/system/auth/get-permission-info 不存在）。
  static Future<void> loadUserProfile() async {
    final resp = await ApiClient.dio
        .get('/app-api/member/user/get');
    final data = ApiClient.unwrap(resp);
    if (data is Map) {
      await AuthManager.instance.updateProfile(
        nickname: (data['nickname'] ?? '').toString(),
        avatar: (data['avatar'] ?? '').toString(),
        mobile: (data['mobile'] ?? '').toString(),
      );
    }
  }

  /// 通过手机号搜索用户（app-api/system/user 系列接口不存在；
  /// 命中返回精简资料，未找到/未启用返回 null）。
  static Future<SimpleUser?> findUserByMobile(String mobile) async {
    final resp = await ApiClient.dio.put(
      '/app-api/member/user/findUserByMobile',
      queryParameters: {'mobile': mobile},
    );
    final data = ApiClient.unwrap(resp);
    if (data is! Map<String, dynamic>) return null;
    return SimpleUser.fromJson(data);
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
