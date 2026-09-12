import '../models/im_conversation.dart' show ImCommonStatus;
import '../shared/json_utils.dart';
import 'api_client.dart';

/// 通知公告接口（对应后端 system 模块 NoticeController；管理端 CRUD，
/// 与 IM 消息体系无关——不进 WebSocket、不进会话列表）。
class NoticeApi {
  /// 分页查询公告列表。
  /// [title] 标题模糊搜索（空串不传）；[status] 状态筛选（0=开启 1=关闭）。
  static Future<NoticePage> getNoticePage({
    required int pageNo,
    required int pageSize,
    String title = '',
    int? status,
  }) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/system/notice/page',
      queryParameters: {
        'pageNo': pageNo,
        'pageSize': pageSize,
        if (title.isNotEmpty) 'title': title,
        if (status != null && status >= 0) 'status': status,
      },
    );
    final data = ApiClient.unwrap(resp);
    if (data is! Map) return NoticePage.empty();
    final list = data['list'];
    return NoticePage(
      total: asInt(data['total']),
      list: list is List
          ? list
              .map((e) => Notice.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
    );
  }

  /// 公告详情。
  static Future<Notice> getNotice({required int id}) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/system/notice/get',
      queryParameters: {'id': id},
    );
    return Notice.fromJson(Map<String, dynamic>.from(ApiClient.unwrap(resp)));
  }

  /// 新增公告。
  static Future<void> createNotice({required Notice notice}) async {
    await ApiClient.dio.post(
      '/admin-api/system/notice/create',
      data: notice.toCreateJson(),
    );
  }

  /// 更新公告。
  static Future<void> updateNotice({required Notice notice}) async {
    await ApiClient.dio.put(
      '/admin-api/system/notice/update',
      data: notice.toUpdateJson(),
    );
  }

  /// 删除公告。
  static Future<void> deleteNotice({required int id}) async {
    await ApiClient.dio.delete(
      '/admin-api/system/notice/delete',
      queryParameters: {'id': id},
    );
  }
}

/// 分页结果。
class NoticePage {
  final int total;
  final List<Notice> list;

  const NoticePage({required this.total, required this.list});

  factory NoticePage.empty() => const NoticePage(total: 0, list: []);
}

/// 公告类型（对应后端 NoticeTypeEnum / 字典 SYSTEM_NOTICE_TYPE）。
class NoticeType {
  static const int notification = 1; // 通知
  static const int announcement = 2; // 公告

  static String label(int type) => type == announcement ? '公告' : '通知';
}

/// 公告数据模型（对应后端 NoticeRespVO）。
class Notice {
  final int id;
  final String title;
  final String content;
  final int type;
  final int status;
  final String remark;
  final DateTime? createTime;

  const Notice({
    required this.id,
    required this.title,
    required this.content,
    required this.type,
    required this.status,
    required this.remark,
    required this.createTime,
  });

  bool get enabled => status == ImCommonStatus.enable;

  factory Notice.fromJson(Map<String, dynamic> json) {
    return Notice(
      id: asInt(json['id']),
      title: asString(json['title']),
      content: asString(json['content']),
      type: asInt(json['type'], NoticeType.notification),
      status: asInt(json['status'], ImCommonStatus.enable),
      remark: asString(json['remark']),
      createTime: DateTime.tryParse(json['createTime']?.toString() ?? ''),
    );
  }

  Map<String, dynamic> toCreateJson() => {
        'title': title,
        'content': content,
        'type': type,
        'status': status,
        'remark': remark,
      };

  Map<String, dynamic> toUpdateJson() => {...toCreateJson(), 'id': id};

  Notice copyWith({
    String? title,
    String? content,
    int? type,
    int? status,
    String? remark,
  }) {
    return Notice(
      id: id,
      title: title ?? this.title,
      content: content ?? this.content,
      type: type ?? this.type,
      status: status ?? this.status,
      remark: remark ?? this.remark,
      createTime: createTime,
    );
  }
}
