import '../shared/json_utils.dart';
import 'api_client.dart';

/// RTC 通话 REST 信令接口（对应后端 ImRtcCallController）。
/// 媒体协商完全交给 LiveKit；后端只做会话状态机、Token 签发、
/// 来电信令推送、通话历史落消息流。
class RtcApi {
  /// 创建通话（私聊/群聊通用；返回 room + livekitUrl + token）。
  static Future<RtcCallData> createCall({
    required int conversationType,
    required int mediaType,
    int? groupId,
    required List<int> inviteeIds,
  }) async {
    final resp = await ApiClient.dio.post(
      '/admin-api/im/rtc/create',
      data: {
        'conversationType': conversationType,
        'mediaType': mediaType,
        if (groupId != null) 'groupId': groupId,
        'inviteeIds': inviteeIds,
      },
    );
    return RtcCallData.fromJson(ApiClient.unwrap(resp));
  }

  /// 通话中追加邀请（仅群通话可用）。
  static Future<void> inviteCall({
    required String room,
    required List<int> inviteeIds,
  }) async {
    await ApiClient.dio.post(
      '/admin-api/im/rtc/invite',
      data: {'room': room, 'inviteeIds': inviteeIds},
    );
  }

  /// 加入已有群通话（胶囊条「加入」按钮）。
  static Future<RtcCallData> joinCall({required String room}) async {
    final resp = await ApiClient.dio.post(
      '/admin-api/im/rtc/join',
      queryParameters: {'room': room},
    );
    return RtcCallData.fromJson(ApiClient.unwrap(resp));
  }

  /// 接听通话（返回带本人 token 的连接数据）。
  static Future<RtcCallData> acceptCall({required String room}) async {
    final resp = await ApiClient.dio.post(
      '/admin-api/im/rtc/accept',
      queryParameters: {'room': room},
    );
    return RtcCallData.fromJson(ApiClient.unwrap(resp));
  }

  /// 拒绝通话（被叫接通前）。
  static Future<void> rejectCall({required String room}) async {
    await ApiClient.dio.post(
      '/admin-api/im/rtc/reject',
      queryParameters: {'room': room},
    );
  }

  /// 取消邀请（主叫接通前）。
  static Future<void> cancelCall({required String room}) async {
    await ApiClient.dio.post(
      '/admin-api/im/rtc/cancel',
      queryParameters: {'room': room},
    );
  }

  /// 离开通话（接通后）。
  static Future<void> leaveCall({required String room}) async {
    await ApiClient.dio.post(
      '/admin-api/im/rtc/leave',
      queryParameters: {'room': room},
    );
  }

  /// 振铃超时检查（INVITING 端 60s 轮询触发服务端扫描，接口静默）。
  static Future<void> noAnswerCallCheck({required String room}) async {
    await ApiClient.dio.post(
      '/admin-api/im/rtc/no-answer-call-check',
      queryParameters: {'room': room},
    );
  }

  /// 查询群当前进行中的通话（群聊顶部「N 人正在通话」胶囊条用）。
  static Future<RtcGroupCallData?> getActiveCall({required int groupId}) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/im/rtc/get-active-call',
      queryParameters: {'groupId': groupId},
    );
    final data = ApiClient.unwrap(resp);
    if (data is! Map<String, dynamic>) return null;
    return RtcGroupCallData.fromJson(data);
  }
}

/// 通话会话数据（对应后端 ImRtcCallRespVO；create/accept/join 均返回）。
class RtcCallData {
  /// 业务通话编号。
  final String room;

  /// LiveKit 服务器地址。
  final String livekitUrl;

  /// 本人入房 token（服务端按 identity=userId 签发）。
  final String token;

  /// 会话类型（1=私聊 2=群聊）。
  final int conversationType;

  /// 媒体类型（1=语音 2=视频）。
  final int mediaType;

  /// 通话状态（10=CREATED 20=RUNNING 30=ENDED）。
  final int status;

  /// 发起人编号。
  final int inviterId;

  /// 群编号（群通话）。
  final int groupId;

  /// 被邀请人编号集合。
  final List<int> inviteeIds;

  /// 已入房人编号集合。
  final List<int> joinedUserIds;

  const RtcCallData({
    required this.room,
    required this.livekitUrl,
    required this.token,
    required this.conversationType,
    required this.mediaType,
    required this.status,
    required this.inviterId,
    required this.groupId,
    required this.inviteeIds,
    required this.joinedUserIds,
  });

  factory RtcCallData.fromJson(Map<String, dynamic> json) {
    List<int> toIntList(dynamic v) {
      if (v is List) return v.map((e) => asInt(e)).where((e) => e > 0).toList();
      return const [];
    }

    return RtcCallData(
      room: asString(json['room']),
      livekitUrl: asString(json['livekitUrl']),
      token: asString(json['token']),
      conversationType: asInt(json['conversationType']),
      mediaType: asInt(json['mediaType']),
      status: asInt(json['status']),
      inviterId: asInt(json['inviterId']),
      groupId: asInt(json['groupId']),
      inviteeIds: toIntList(json['inviteeIds']),
      joinedUserIds: toIntList(json['joinedUserIds']),
    );
  }

  /// 是否视频通话。
  bool get isVideo => mediaType == 2;
}

/// 群进行中的通话（对应后端 ImRtcGroupCallRespVO）。
class RtcGroupCallData {
  final String room;
  final int groupId;
  final int mediaType;
  final int inviterId;
  final List<int> joinedUserIds;
  final List<int> inviteeIds;

  const RtcGroupCallData({
    required this.room,
    required this.groupId,
    required this.mediaType,
    required this.inviterId,
    required this.joinedUserIds,
    required this.inviteeIds,
  });

  factory RtcGroupCallData.fromJson(Map<String, dynamic> json) {
    List<int> toIntList(dynamic v) {
      if (v is List) return v.map((e) => asInt(e)).where((e) => e > 0).toList();
      return const [];
    }

    return RtcGroupCallData(
      room: asString(json['room']),
      groupId: asInt(json['groupId']),
      mediaType: asInt(json['mediaType']),
      inviterId: asInt(json['inviterId']),
      joinedUserIds: toIntList(json['joinedUserIds']),
      inviteeIds: toIntList(json['inviteeIds']),
    );
  }

  bool get isVideo => mediaType == 2;
}
