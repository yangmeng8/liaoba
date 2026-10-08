import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common/version_update_dialog.dart';
import 'api_client.dart';

/// 服务端返回的 App 版本信息（/app-api/app/version/latest）。
class VersionInfo {
  const VersionInfo({
    required this.version,
    required this.description,
    required this.forceUpdate,
    this.id,
    this.createTime,
  });

  final int? id;

  /// 最新版本号（点分如 1.0.4）。
  final String version;

  /// 版本描述（换行分隔多条更新说明）。
  final String description;

  /// 是否强制更新。
  final bool forceUpdate;
  final String? createTime;

  factory VersionInfo.fromJson(Map<String, dynamic> json) => VersionInfo(
        id: _parseInt(json['id']),
        version: json['version']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        forceUpdate: _parseBool(json['forceUpdate']),
        createTime: json['createTime']?.toString(),
      );
}

/// 版本检查、下载地址获取和更新弹框服务（参考 app_im VersionService）。
///
/// 流程：checkUpdate（版本比较）→ getDownloadUrl（infra/config 配置的
/// 下载直链）→ showDialog（强制更新不可关闭）→ url_launcher 外部浏览器下载。
class VersionService {
  VersionService._();

  static final VersionService instance = VersionService._();

  /// 全局导航 Key（main 注入）：自动检查时无页面 context，用它弹更新框。
  GlobalKey<NavigatorState>? navigatorKey;

  bool _checking = false;
  DateTime? _lastCheckAt;
  static const _minimumCheckInterval = Duration(seconds: 5);

  /// 获取当前 App 版本号。
  Future<String> getCurrentVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      return packageInfo.version.trim();
    } catch (e, st) {
      _log('获取当前版本号失败: $e\n$st', error: true);
      return '';
    }
  }

  /// 检查服务端版本是否高于当前版本。
  ///
  /// 接口：GET /app-api/app/version/latest
  /// 服务端 version 为空但 forceUpdate=true 时仍返回（后台临时强制升版）。
  Future<VersionInfo?> checkUpdate() async {
    try {
      final currentVersion = await getCurrentVersion();
      if (currentVersion.isEmpty) {
        _log('当前版本号为空，跳过检查', error: true);
        return null;
      }
      _log('当前 App 版本: $currentVersion');

      final response = await ApiClient.dio.get<dynamic>(
        '/app-api/app/version/latest',
      );
      final data = ApiClient.unwrap(response);
      if (data is! Map) {
        _log('版本接口返回无效', error: true);
        return null;
      }
      final versionInfo = VersionInfo.fromJson(Map<String, dynamic>.from(data));
      final latestVersion = versionInfo.version.trim();
      _log('服务端最新版本: "$latestVersion", forceUpdate=${versionInfo.forceUpdate}');

      if (latestVersion.isEmpty) {
        if (versionInfo.forceUpdate) return versionInfo;
        _log('version 为空且非强制更新，跳过');
        return null;
      }

      final comparison = compareVersion(currentVersion, latestVersion);
      if (comparison < 0) {
        _log('需要更新: $currentVersion < $latestVersion');
        return versionInfo;
      }
      _log('当前已是最新版本');
      return null;
    } catch (e, st) {
      _log('版本检查异常: $e\n$st', error: true);
      return null;
    }
  }

  /// 获取 App 下载地址。
  ///
  /// 接口：GET /app-api/infra/config/get
  /// iOS 用 key=url.config.app-ios-download-url；
  /// Android 用 key=url.config.app-android-download-url。
  /// data 为 APK 直链或 iOS 安装链接。
  Future<String?> getDownloadUrl() async {
    try {
      final String configKey;
      if (Platform.isIOS) {
        configKey = 'url.config.app-ios-download-url';
      } else if (Platform.isAndroid) {
        configKey = 'url.config.app-android-download-url';
      } else {
        _log('当前平台不支持获取下载地址: ${Platform.operatingSystem}', error: true);
        return null;
      }

      final response = await ApiClient.dio.get<dynamic>(
        '/app-api/infra/config/get',
        queryParameters: {'key': configKey},
      );
      final downloadUrl = ApiClient.unwrap(response)?.toString().trim() ?? '';
      if (downloadUrl.isNotEmpty) {
        _log('获取到 App 下载地址: $downloadUrl');
        return downloadUrl;
      }
      _log('下载地址为空', error: true);
      return null;
    } catch (e, st) {
      _log('获取下载地址异常: $e\n$st', error: true);
      return null;
    }
  }

  /// 打开外部浏览器下载 App。
  Future<bool> openDownloadUrl(String url) async {
    try {
      final uri = Uri.tryParse(url.trim());
      const allowedSchemes = {'http', 'https', 'itms-services'};
      if (uri == null || !allowedSchemes.contains(uri.scheme.toLowerCase())) {
        _log('下载地址格式无效: $url', error: true);
        return false;
      }
      final opened = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      _log(opened ? '已打开下载地址: $url' : '打开下载地址失败: $url', error: !opened);
      return opened;
    } catch (e, st) {
      _log('打开下载地址异常: $e\n$st', error: true);
      return false;
    }
  }

  /// 检查版本、获取下载地址并显示更新弹框。
  ///
  /// [manual]：手动触发（设置页「检查更新」），无更新时 toast 提示；
  /// 自动触发（进主框架）无更新则静默。
  Future<void> checkAndShow({BuildContext? context, bool manual = false}) async {
    if (_checking) return;
    final now = DateTime.now();
    if (_lastCheckAt != null &&
        now.difference(_lastCheckAt!) < _minimumCheckInterval) {
      _log('距离上次检查不足 5 秒，跳过本次检查');
      return;
    }
    _lastCheckAt = now;
    _checking = true;

    BuildContext? toastContext = context;
    try {
      final versionInfo = await checkUpdate();
      if (versionInfo == null) {
        if (manual && toastContext != null && toastContext.mounted) {
          ScaffoldMessenger.of(toastContext)
              .showSnackBar(const SnackBar(content: Text('当前已是最新版本')));
        }
        return;
      }

      final downloadUrl = await getDownloadUrl();
      if (downloadUrl == null || downloadUrl.isEmpty) {
        _log('下载地址为空，无法显示更新弹框', error: true);
        if (manual && toastContext != null && toastContext.mounted) {
          ScaffoldMessenger.of(toastContext)
              .showSnackBar(const SnackBar(content: Text('获取下载地址失败，请稍后重试')));
        }
        return;
      }

      // 弹框 context 优先取入参；自动检查时用注入的 rootNavigatorKey
      final dialogContext = context ?? navigatorKey?.currentContext;
      if (dialogContext == null || !dialogContext.mounted) {
        _log('无法获取 Context，无法显示更新弹框', error: true);
        return;
      }

      await showDialog<void>(
        context: dialogContext,
        barrierDismissible: false,
        builder: (_) => VersionUpdateDialog(
          version: versionInfo.version,
          description: versionInfo.description,
          isForceUpdate: versionInfo.forceUpdate,
          onUpdate: () {
            // 异步下载不阻塞弹框（外部浏览器打开）
            openDownloadUrl(downloadUrl);
          },
          onDismiss: versionInfo.forceUpdate ? null : () {},
        ),
      );
    } catch (e, st) {
      _log('版本更新流程异常: $e\n$st', error: true);
    } finally {
      _checking = false;
    }
  }

  /// 比较点分版本号：v1 < v2 返回 -1，相等返回 0，否则返回 1。
  int compareVersion(String version1, String version2) {
    final first = _versionParts(version1);
    final second = _versionParts(version2);
    final length = first.length > second.length ? first.length : second.length;

    for (var index = 0; index < length; index++) {
      final left = index < first.length ? first[index] : 0;
      final right = index < second.length ? second[index] : 0;
      if (left < right) return -1;
      if (left > right) return 1;
    }
    return 0;
  }

  List<int> _versionParts(String version) {
    final normalized = version.trim().toLowerCase().replaceFirst('v', '');
    return normalized
        .split('.')
        .map((part) =>
            int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
  }

  void _log(String message, {bool error = false}) {
    debugPrint('[版本检查] $message');
    if (error) {
      debugPrint('[版本检查][错误] $message');
    }
  }
}

int? _parseInt(dynamic value) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '');
}

bool _parseBool(dynamic value) {
  if (value is bool) return value;
  return value?.toString().toLowerCase() == 'true';
}
