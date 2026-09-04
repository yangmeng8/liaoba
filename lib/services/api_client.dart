import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'auth_manager.dart';

/// API 日志开关：debug 模式打印请求入参/响应返回，release 关闭。
bool get _enableApiLog => kDebugMode;

void _log(String tag, String msg) {
  if (_enableApiLog) {
    debugPrint('[API]$tag $msg');
  }
}

/// 后端统一返回结构异常：code != 0 时抛出。
class ApiException implements Exception {
  final int code;
  final String msg;
  ApiException(this.code, this.msg);

  @override
  String toString() => msg;
}

/// 全局 API 客户端（基于 dio）。
class ApiClient {
  /// 后端服务根地址
  static const String baseUrl = 'https://imtest-api.yqtest.top';

  /// 租户编号（yudao 多租户场景必传，单租户默认 1）
  static const int tenantId = 1;

  ApiClient._();

  static final Dio dio = _createDio();

  static Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        headers: {'Content-Type': 'application/json'},
      ),
    );

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          // 统一带上租户编号与登录 Token
          options.headers['tenant-id'] = tenantId;
          final token = AuthManager.instance.accessToken;
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          _log('请求', '--> ${options.method} ${options.uri}');
          _log('请求', '入参: ${options.data}');
          _log('请求', '请求头: ${options.headers}');
          handler.next(options);
        },
        onResponse: (response, handler) {
          _log('响应',
              '<-- ${response.requestOptions.method} ${response.requestOptions.uri} [${response.statusCode}]');
          _log('响应', '返回: ${response.data}');
          handler.next(response);
        },
        onError: (e, handler) {
          _log('错误',
              '<-- ${e.requestOptions.method} ${e.requestOptions.uri} [${e.response?.statusCode}]');
          _log('错误', '返回: ${e.response?.data}');
          _log('错误', '异常: ${e.message}');
          handler.next(e);
        },
      ),
    );

    return dio;
  }

  /// 校验后端统一返回结构 {code, msg, data}，成功时返回 data。
  static dynamic unwrap(Response resp) {
    final body = resp.data;
    if (body is! Map || !body.containsKey('code')) return body;
    final code = body['code'];
    if (code != 0) {
      throw ApiException(code is int ? code : -1,
          (body['msg'] ?? '请求失败').toString());
    }
    return body['data'];
  }

  /// 把各种异常转成用户可读的消息。
  static String errorMessage(Object e) {
    if (e is ApiException) return e.msg;
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map && data['msg'] != null) {
        return data['msg'].toString();
      }
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return '网络连接超时，请稍后重试';
        case DioExceptionType.connectionError:
          return '网络连接失败，请检查网络';
        default:
          return '请求失败（${e.type.name}）';
      }
    }
    return '请求失败：$e';
  }
}
