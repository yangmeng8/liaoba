import 'package:dio/dio.dart';

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
      '/app-api/member/auth/send-sms-code',
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
      '/app-api/member/auth/sms-register',
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
        userId: (data['userId'] as num?)?.toInt() ?? 0,
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
        userId: (data['userId'] as num?)?.toInt() ?? 0,
        accessToken: (data['accessToken'] ?? '').toString(),
        refreshToken: (data['refreshToken'] ?? '').toString(),
        expiresTime: data['expiresTime']?.toString(),
        openid: data['openid']?.toString(),
      );
    }
  }
}
