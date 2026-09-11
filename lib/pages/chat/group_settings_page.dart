import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../models/im_conversation.dart';
import '../../models/im_message.dart';
import '../../models/im_ws_frame.dart';
import '../../services/api_client.dart';
import '../../services/auth_manager.dart';
import '../../services/chat_history_cleaner.dart';
import '../../services/im_api.dart';
import '../../services/im_websocket.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/im_avatar.dart';
import '../../shared/json_utils.dart';
import '../../stores/conversation_store.dart';
import '../contacts/user_profile_page.dart';
import 'chat_search_page.dart';
import 'group_request_page.dart';

/// 群成员上限（对齐 H5 GROUP_MAX_MEMBER）。
const int _kGroupMaxMember = 500;

/// 群管理员上限（对齐 H5 GROUP_ADMIN_MAX_COUNT）。
const int _kGroupAdminMaxCount = 3;

/// 禁言时长选项（对齐 H5 mutePresets）。
const List<(String, int)> _kMutePresets = [
  ('10 分钟', 600),
  ('1 小时', 3600),
  ('12 小时', 43200),
  ('1 天', 86400),
  ('7 天', 604800),
  ('30 天', 2592000),
  ('永久', 0),
];

/// 群设置页（对齐 H5 conversation-group-side.vue）：
/// - 数据加载：群详情 + 全量成员并行拉取
/// - 权限体系：OWNER > ADMIN > NORMAL 三级角色驱动整页 UI 显隐
/// - 实时同步：WebSocket 本群事件静默重拉；被移出（解散/自退/被踢）秒切只读态
/// - 退群只读态：仅保留查看成员、查找聊天内容、清空本地记录
class GroupSettingsPage extends StatefulWidget {
  final int groupId;

  const GroupSettingsPage({super.key, required this.groupId});

  @override
  State<GroupSettingsPage> createState() => _GroupSettingsPageState();
}

class _GroupSettingsPageState extends State<GroupSettingsPage> {
  bool _loading = true;
  String? _error;
  ImGroup? _group;

  /// 全量成员（含已退群记录，渲染时过滤有效成员）。
  List<ImGroupMember> _members = [];

  /// 我与群的关系已终止（退群/被踢/解散后的只读态标记）。
  bool _groupRelationInvalid = false;

  /// switch 本地状态（先切 UI 再请求，失败回滚）。
  bool _mutedAll = false;
  bool _joinApproval = false;
  bool _mySilent = false;
  bool _pinned = false;
  bool _actionRunning = false;

  /// 成员九宫格搜索关键词 + 折叠展开。
  final _memberSearchCtrl = TextEditingController();
  String _memberKeyword = '';
  bool _membersExpanded = false;
  static const int _memberCollapseLimit = 10;

  StreamSubscription? _wsSub;

  // ==================== 派生状态 ====================

  int get _myUserId => AuthManager.instance.userId ?? 0;

  /// 当前有效成员（过滤已退群），按角色升序 + userId 排序。
  List<ImGroupMember> get _currentMembers {
    final list = _members.where((m) => m.active).toList();
    list.sort((a, b) {
      final roleDiff = a.role.compareTo(b.role);
      return roleDiff != 0 ? roleDiff : a.userId.compareTo(b.userId);
    });
    return list;
  }

  /// 我的成员记录（无效即 null）。
  ImGroupMember? get _myMember {
    if (_groupRelationInvalid) return null;
    for (final m in _members) {
      if (m.userId == _myUserId && m.active) return m;
    }
    return null;
  }

  /// 是否群主。
  bool get _isOwner =>
      _myMember != null && _myMember!.role == ImGroupRole.owner;

  /// 是否可管理群（群主/管理员且未退群）。
  bool get _canManageGroup =>
      _myMember != null &&
      (_myMember!.role == ImGroupRole.owner ||
          _myMember!.role == ImGroupRole.admin);

  /// 是否可管理指定成员（管理权限 && 非自己 && 非群主 &&（我是群主 || 对方普通成员））。
  bool _canManageMember(ImGroupMember m) {
    if (!_canManageGroup) return false;
    if (m.userId == _myUserId) return false;
    if (m.role == ImGroupRole.owner) return false;
    return _isOwner || m.role == ImGroupRole.normal;
  }

  /// 退群只读态：加载时发现我不是有效成员，或群标记已退。
  bool get _isQuitGroupDetail =>
      _groupRelationInvalid || (_group?.quit ?? false);

  @override
  void initState() {
    super.initState();
    _memberSearchCtrl.addListener(() {
      setState(() => _memberKeyword = _memberSearchCtrl.text.trim());
    });
    _wsSub = ImWebSocket.instance.notificationStream.listen(_handleImEvent);
    _loadDetail();
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _memberSearchCtrl.dispose();
    super.dispose();
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ==================== 数据加载 ====================

  /// 并行拉取群详情 + 全量成员；解析我的成员身份。
  Future<void> _loadDetail() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        ImApi.getGroup(id: widget.groupId),
        ImApi.getGroupMemberList(groupId: widget.groupId),
      ]);
      if (!mounted) return;
      final group = results[0] as ImGroup;
      final members = results[1] as List<ImGroupMember>;
      final activeSelf = members
          .where((m) => m.userId == _myUserId && m.active)
          .toList();
      setState(() {
        _group = group;
        _members = members;
        _groupRelationInvalid = activeSelf.isEmpty;
        _mutedAll = group.mutedAll;
        _joinApproval = group.joinApproval;
        _mySilent = group.silent;
        _loading = false;
      });
      _syncPinned();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = ApiClient.errorMessage(e);
      });
    }
  }

  /// 静默重拉（WS 事件触发，不显示 loading）。
  Future<void> _silentReload() async {
    try {
      final results = await Future.wait([
        ImApi.getGroup(id: widget.groupId),
        ImApi.getGroupMemberList(groupId: widget.groupId),
      ]);
      if (!mounted) return;
      final group = results[0] as ImGroup;
      final members = results[1] as List<ImGroupMember>;
      final activeSelf = members
          .where((m) => m.userId == _myUserId && m.active)
          .toList();
      setState(() {
        _group = group;
        _members = members;
        _groupRelationInvalid = activeSelf.isEmpty;
        _mutedAll = group.mutedAll;
        _joinApproval = group.joinApproval;
        _mySilent = group.silent;
      });
    } catch (_) {
      // 静默重拉失败保持现状
    }
  }

  /// 同步本地置顶状态（会话列表聚合结果）。
  void _syncPinned() {
    final store = ConversationStore.instance;
    setState(() {
      _pinned = store.isConversationTop(ImConversationType.group, widget.groupId);
    });
  }

  // ==================== WebSocket 实时同步 ====================

  /// 本群事件处理（对齐 H5 handleImEvent）：
  /// 被移出（解散/自退/被踢）→ 立即切只读态（本地标记，不发请求）；
  /// 其他本群事件 → 静默重拉刷新。
  void _handleImEvent(ImWsNotification n) {
    if (n.conversationType != ImConversationType.group.value) return;
    final p = n.payload;
    if (asInt(p['groupId']) != widget.groupId) return;
    final content = _parseEventContent(p);
    final removedSelf =
        n.contentType == ImGroupNotificationType.groupDissolve ||
        (n.contentType == ImGroupNotificationType.groupMemberQuit &&
            _firstNonZero([
              asInt(content['operatorUserId']),
              asInt(p['operatorUserId']),
            ]) == _myUserId) ||
        (n.contentType == ImGroupNotificationType.groupMemberKick &&
            _memberIds(content, p).contains(_myUserId));
    if (removedSelf) {
      if (!mounted) return;
      setState(() {
        _groupRelationInvalid = true;
        _pinned = false;
        // 本地标记我的成员 DISABLE + 群 DISABLE（不发请求）
        _members = _members
            .map((m) => m.userId == _myUserId
                ? _copyMemberDisabled(m)
                : m)
            .toList();
        if (_group != null) {
          _group = _copyGroupQuit(_group!);
        }
      });
      return;
    }
    _silentReload();
  }

  /// 事件 content 可能是 JSON 字符串（消息事件）或直接对象。
  Map<String, dynamic> _parseEventContent(Map<String, dynamic> payload) {
    final raw = payload['content'];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        // 非 JSON
      }
    }
    return const {};
  }

  int _firstNonZero(List<int> values) {
    for (final v in values) {
      if (v != 0) return v;
    }
    return 0;
  }

  List<int> _memberIds(
    Map<String, dynamic> content,
    Map<String, dynamic> payload,
  ) {
    final ids = parseIntList(content['memberUserIds']);
    if (ids.isNotEmpty) return ids;
    return parseIntList(payload['memberUserIds']);
  }

  ImGroupMember _copyMemberDisabled(ImGroupMember m) => ImGroupMember(
    userId: m.userId,
    nickname: m.nickname,
    avatar: m.avatar,
    displayUserName: m.displayUserName,
    role: m.role,
    status: ImCommonStatus.disable,
    muteEndTime: m.muteEndTime,
  );

  ImGroup _copyGroupQuit(ImGroup g) => ImGroup(
    id: g.id,
    name: g.name,
    ownerUserId: g.ownerUserId,
    avatar: g.avatar,
    notice: g.notice,
    mutedAll: g.mutedAll,
    joinApproval: g.joinApproval,
    joinStatus: ImCommonStatus.disable,
    groupRemark: g.groupRemark,
    silent: g.silent,
  );

  // ==================== 成员操作 ====================

  /// 点击成员 → 用户资料页（群聊入口带来源上下文）。
  void _openMemberProfile(ImGroupMember m) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfilePage(
          userId: m.userId,
          addSource: 2,
          sourceExtra: _group?.name ?? '',
        ),
      ),
    );
  }

  /// 长按成员 → 管理菜单（设/撤管理员、转让群主、禁言、移出）。
  void _openMemberActions(ImGroupMember m) {
    if (!_canManageMember(m)) return;
    final colors = context.colors;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: colors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            if (_isOwner) ...[
              ListTile(
                leading: const Icon(Icons.shield_outlined, size: 24),
                title: Text(
                  m.role == ImGroupRole.admin ? '撤销管理员' : '设为管理员',
                  style: const TextStyle(fontSize: 16),
                ),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  m.role == ImGroupRole.admin
                      ? _removeAdmin(m)
                      : _addAdmin(m);
                },
              ),
              ListTile(
                leading: const Icon(Icons.swap_horiz, size: 24),
                title: const Text('转让群主', style: TextStyle(fontSize: 16)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _transferOwner(m);
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.volume_off_outlined, size: 24),
              title: Text(
                m.muted ? '取消禁言' : '设置禁言',
                style: const TextStyle(fontSize: 16),
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                m.muted ? _cancelMute(m) : _openMutePicker(m);
              },
            ),
            ListTile(
              leading: const Icon(Icons.person_remove_outlined,
                  size: 24, color: Colors.red),
              title: const Text('移出群聊',
                  style: TextStyle(fontSize: 16, color: Colors.red)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _kickMember(m);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirm(String title, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return result == true;
  }

  /// 弹窗输入（昵称/备注编辑用）。
  Future<String?> _promptText(
    String title,
    String hint, {
    String initial = '',
    int maxLength = 30,
  }) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: maxLength,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  /// 编辑我在本群的昵称。
  Future<void> _editMyNick() async {
    if (_isQuitGroupDetail) return;
    final value = await _promptText(
      '我在本群的昵称',
      '请输入昵称',
      initial: _myMember?.displayUserName ?? '',
    );
    if (value == null) return;
    try {
      await ImApi.updateMyGroupMember(
        groupId: widget.groupId,
        displayUserName: value,
      );
      await _silentReload();
      if (mounted) _showMsg('已保存');
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  /// 编辑群聊备注（仅自己可见）。
  Future<void> _editGroupRemark() async {
    if (_isQuitGroupDetail) return;
    final value = await _promptText(
      '群聊备注',
      '备注仅自己可见',
      initial: _group?.groupRemark ?? '',
    );
    if (value == null) return;
    try {
      await ImApi.updateMyGroupMember(
        groupId: widget.groupId,
        groupRemark: value,
      );
      await _silentReload();
      if (mounted) _showMsg('已保存');
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  /// 编辑群聊名称（仅群主）。
  Future<void> _editGroupName() async {
    if (!_isOwner || _isQuitGroupDetail) return;
    final value = await _promptText(
      '群聊名称',
      '请输入群名称',
      initial: _group?.name ?? '',
    );
    if (value == null || value.isEmpty) return;
    try {
      await ImApi.updateGroup(id: widget.groupId, name: value);
      await _silentReload();
      if (mounted) _showMsg('已保存');
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  /// 编辑群公告（仅群主）。
  Future<void> _editGroupNotice() async {
    if (!_isOwner || _isQuitGroupDetail) return;
    final value = await _promptText(
      '群公告',
      '请输入群公告',
      initial: _group?.notice ?? '',
      maxLength: 200,
    );
    if (value == null) return;
    try {
      await ImApi.updateGroup(id: widget.groupId, notice: value);
      await _silentReload();
      if (mounted) _showMsg('已保存');
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  /// 设置禁言：选择时长。
  Future<void> _openMutePicker(ImGroupMember m) async {
    final colors = context.colors;
    int selected = _kMutePresets.first.$2;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: colors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('设置禁言',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colors.text)),
                const SizedBox(height: 8),
                Text('禁言成员：${m.shownName}',
                    style: TextStyle(fontSize: 13, color: colors.muted)),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (label, seconds) in _kMutePresets)
                      ChoiceChip(
                        label: Text(label),
                        selected: selected == seconds,
                        onSelected: (_) =>
                            setSheetState(() => selected = seconds),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(sheetCtx, true),
                    child: const Text('确定'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      await ImApi.muteGroupMember(
        id: widget.groupId,
        userId: m.userId,
        mutedSeconds: selected,
      );
      _showMsg('禁言成功');
      await _silentReload();
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  /// 取消禁言。
  Future<void> _cancelMute(ImGroupMember m) async {
    try {
      await ImApi.cancelMuteGroupMember(
        id: widget.groupId,
        userId: m.userId,
      );
      _showMsg('已取消禁言');
      await _silentReload();
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  /// 设为管理员（校验管理员上限）。
  Future<void> _addAdmin(ImGroupMember m) async {
    final adminCount = _currentMembers
        .where((item) => item.role == ImGroupRole.admin)
        .length;
    if (adminCount >= _kGroupAdminMaxCount) {
      _showMsg('群管理员上限为 $_kGroupAdminMaxCount 人');
      return;
    }
    try {
      await ImApi.addGroupAdmins(id: widget.groupId, userIds: [m.userId]);
      _showMsg('已设为管理员');
      await _silentReload();
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  /// 撤销管理员。
  Future<void> _removeAdmin(ImGroupMember m) async {
    try {
      await ImApi.removeGroupAdmins(id: widget.groupId, userIds: [m.userId]);
      _showMsg('已撤销管理员');
      await _silentReload();
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  /// 转让群主（二次确认）。
  Future<void> _transferOwner(ImGroupMember m) async {
    final confirmed =
        await _confirm('提示', '确定将群主转让给"${m.shownName}"吗？');
    if (!confirmed) return;
    try {
      await ImApi.transferGroupOwner(
        id: widget.groupId,
        newOwnerUserId: m.userId,
      );
      _showMsg('已转让群主');
      await _silentReload();
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  /// 移出群聊（二次确认）。
  Future<void> _kickMember(ImGroupMember m) async {
    final confirmed =
        await _confirm('提示', '确定将"${m.shownName}"移出群聊吗？');
    if (!confirmed) return;
    try {
      await ImApi.kickGroupMembers(
        groupId: widget.groupId,
        memberUserIds: [m.userId],
      );
      _showMsg('已移出群聊');
      await _silentReload();
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  // ==================== 邀请 / 批量移出 / 管理员设置 ====================

  /// 邀请成员：好友列表排除已在群成员，多选。
  Future<void> _openInvitePicker() async {
    if (_isQuitGroupDetail) return;
    if (_currentMembers.length >= _kGroupMaxMember) {
      _showMsg('群成员上限为 $_kGroupMaxMember 人');
      return;
    }
    try {
      final friends = await ImApi.getFriendList();
      if (!mounted) return;
      final inGroup = _currentMembers.map((m) => m.userId).toSet();
      final candidates = friends
          .where((f) => !inGroup.contains(f.friendUserId))
          .toList();
      if (candidates.isEmpty) {
        _showMsg('暂无可邀请的好友');
        return;
      }
      final selected = await showModalBottomSheet<List<int>>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _MemberSelectSheet(
          title: '邀请好友入群',
          members: candidates
              .map((f) => ImGroupMember(
                    userId: f.friendUserId,
                    nickname: f.nickname,
                    avatar: f.avatar,
                  ))
              .toList(),
          confirmLabel: '邀请',
        ),
      );
      if (selected == null || selected.isEmpty) return;
      await ImApi.inviteGroupMembers(
        groupId: widget.groupId,
        memberUserIds: selected,
      );
      _showMsg('已发送邀请');
      await _silentReload();
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  /// 批量移出成员（可移出的成员多选）。
  Future<void> _openRemovePicker() async {
    final removable =
        _currentMembers.where(_canManageMember).toList();
    if (removable.isEmpty) return;
    final selected = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MemberSelectSheet(
        title: '移出群成员',
        members: removable,
        confirmLabel: '移出',
        destructive: true,
      ),
    );
    if (selected == null || selected.isEmpty) return;
    final confirmed =
        await _confirm('提示', '确定将选中的 ${selected.length} 人移出群聊吗？');
    if (!confirmed) return;
    try {
      await ImApi.kickGroupMembers(
        groupId: widget.groupId,
        memberUserIds: selected,
      );
      _showMsg('已移出群聊');
      await _silentReload();
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  /// 群管理员设置：普通成员点击设为管理员，管理员点击撤销。
  Future<void> _openAdminPicker() async {
    final candidates = _currentMembers
        .where((m) => m.userId != _myUserId && m.role != ImGroupRole.owner)
        .toList();
    if (candidates.isEmpty) {
      _showMsg('暂无可设置的成员');
      return;
    }
    final selected = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MemberSelectSheet(
        title: '群管理员设置',
        members: candidates,
        confirmLabel: '确定',
        adminMark: true,
      ),
    );
    if (selected == null || selected.isEmpty) return;
    try {
      // 设为管理员：选中的普通成员；撤销：选中前是管理员的
      final toAdd = candidates
          .where((m) =>
              m.role == ImGroupRole.normal && selected.contains(m.userId))
          .map((m) => m.userId)
          .toList();
      final toRemove = candidates
          .where((m) =>
              m.role == ImGroupRole.admin && selected.contains(m.userId))
          .map((m) => m.userId)
          .toList();
      final adminCount = candidates
          .where((m) => m.role == ImGroupRole.admin)
          .length;
      if (adminCount - toRemove.length + toAdd.length > _kGroupAdminMaxCount) {
        _showMsg('群管理员上限为 $_kGroupAdminMaxCount 人');
        return;
      }
      if (toRemove.isNotEmpty) {
        await ImApi.removeGroupAdmins(
          id: widget.groupId,
          userIds: toRemove,
        );
      }
      if (toAdd.isNotEmpty) {
        await ImApi.addGroupAdmins(id: widget.groupId, userIds: toAdd);
      }
      _showMsg('管理员设置已更新');
      await _silentReload();
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  /// 转让群主：单选一个成员。
  Future<void> _openOwnerTransferPicker() async {
    final candidates =
        _currentMembers.where((m) => m.userId != _myUserId).toList();
    if (candidates.isEmpty) {
      _showMsg('暂无可转让的成员');
      return;
    }
    final selected = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MemberSelectSheet(
        title: '转让群主',
        members: candidates,
        confirmLabel: '转让',
        destructive: true,
        singleSelect: true,
      ),
    );
    if (selected == null || selected.isEmpty) return;
    final target = candidates.firstWhere((m) => m.userId == selected.first);
    final confirmed =
        await _confirm('提示', '确定将群主转让给"${target.shownName}"吗？');
    if (!confirmed) return;
    try {
      await ImApi.transferGroupOwner(
        id: widget.groupId,
        newOwnerUserId: target.userId,
      );
      _showMsg('已转让群主');
      await _silentReload();
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  // ==================== switch（先切 UI 再请求，失败回滚） ====================

  Future<void> _toggleMutedAll(bool value) async {
    setState(() => _mutedAll = value);
    try {
      await ImApi.muteGroupAll(id: widget.groupId, mutedAll: value);
    } catch (_) {
      if (mounted) setState(() => _mutedAll = !value);
    }
  }

  Future<void> _toggleJoinApproval(bool value) async {
    setState(() => _joinApproval = value);
    try {
      await ImApi.updateGroup(id: widget.groupId, joinApproval: value);
    } catch (_) {
      if (mounted) setState(() => _joinApproval = !value);
    }
  }

  Future<void> _toggleSilent(bool value) async {
    setState(() => _mySilent = value);
    try {
      await ImApi.updateMyGroupMember(
        groupId: widget.groupId,
        silent: value,
      );
    } catch (_) {
      if (mounted) setState(() => _mySilent = !value);
    }
  }

  Future<void> _togglePinned(bool value) async {
    setState(() => _pinned = value);
    try {
      await ConversationStore.instance.setConversationTop(
        ImConversationType.group,
        widget.groupId,
        value,
      );
    } catch (_) {
      if (mounted) setState(() => _pinned = !value);
    }
  }

  // ==================== 退出 / 解散 / 清空 ====================

  Future<void> _quitGroup() async {
    if (_actionRunning) return;
    final confirmed =
        await _confirm('提示', '确定退出"${_group?.name ?? ''}"吗？');
    if (!confirmed) return;
    setState(() => _actionRunning = true);
    try {
      await ImApi.quitGroup(groupId: widget.groupId);
      if (!mounted) return;
      _showMsg('已退出群聊');
      Navigator.of(context).pop();
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    } finally {
      if (mounted) setState(() => _actionRunning = false);
    }
  }

  Future<void> _dissolveGroup() async {
    if (_actionRunning) return;
    final confirmed =
        await _confirm('提示', '确定解散"${_group?.name ?? ''}"吗？');
    if (!confirmed) return;
    setState(() => _actionRunning = true);
    try {
      await ImApi.dissolveGroup(id: widget.groupId);
      if (!mounted) return;
      _showMsg('已解散群聊');
      Navigator.of(context).pop();
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    } finally {
      if (mounted) setState(() => _actionRunning = false);
    }
  }

  /// 清空本地聊天记录（纯本机操作，不动服务端）。
  Future<void> _clearHistory() async {
    final confirmed = await _confirm('提示', '确定清空本机中的群聊记录吗？该操作不可恢复。');
    if (!confirmed) return;
    await ChatHistoryCleaner.clear(
      ImConversationType.group,
      widget.groupId,
    );
    _showMsg('聊天记录已清空');
  }

  // ==================== 推荐群聊给朋友 ====================

  /// 发送群名片（CARD 消息）+ 可选留言。
  Future<void> _openRecommendPicker() async {
    if (_isQuitGroupDetail || _group == null) return;
    try {
      final friends = await ImApi.getFriendList();
      if (!mounted) return;
      if (friends.isEmpty) {
        _showMsg('暂无好友');
        return;
      }
      final selected = await showModalBottomSheet<List<int>>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _MemberSelectSheet(
          title: '推荐群聊给朋友',
          members: friends
              .map((f) => ImGroupMember(
                    userId: f.friendUserId,
                    nickname: f.nickname,
                    avatar: f.avatar,
                  ))
              .toList(),
          confirmLabel: '发送',
        ),
      );
      if (selected == null || selected.isEmpty) return;
      final leaveMessage = await _promptText(
        '给朋友留言',
        '留言内容（选填，随名片发送）',
        maxLength: 100,
      );
      if (!mounted) return;
      final card = CardPayload(
        targetType: ImConversationType.group.value,
        targetId: widget.groupId,
        name: _group!.name,
        avatar: _group!.avatar,
        memberCount: _currentMembers.length,
      );
      final failedNames = <String>[];
      for (final userId in selected) {
        try {
          await ImApi.sendPrivateMessage(
            clientMessageId: generateClientMessageId(),
            receiverId: userId,
            type: ChatMsgType.card,
            content: jsonEncode(card.toJson()),
          );
          if (leaveMessage != null && leaveMessage.isNotEmpty) {
            await ImApi.sendPrivateMessage(
              clientMessageId: generateClientMessageId(),
              receiverId: userId,
              type: ChatMsgType.text,
              content: jsonEncode({'content': leaveMessage}),
            );
          }
        } catch (_) {
          final f = friends
              .where((item) => item.friendUserId == userId)
              .firstOrNull;
          failedNames.add(f?.shownName ?? '用户$userId');
        }
      }
      if (failedNames.isEmpty) {
        _showMsg('名片已发送');
      } else if (failedNames.length == selected.length) {
        _showMsg('发送失败：${failedNames.join('、')}');
      } else {
        _showMsg('名片已发送，但 ${failedNames.join('、')} 失败');
      }
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final memberCount = _currentMembers.length;
    return Scaffold(
      backgroundColor: colors.bg,
      body: Column(
        children: [
          // 顶部导航栏（标题动态显示成员数）
          Container(
            color: colors.surface,
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 64,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        tooltip: '返回',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: Icon(Icons.chevron_left,
                            size: 34, color: colors.surfaceText),
                      ),
                    ),
                    Text(
                      _loading ? '聊天信息' : '聊天信息($memberCount人)',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: colors.surfaceText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(child: _buildBody(colors)),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeColors colors) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: colors.muted)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _loadDetail, child: const Text('重新加载')),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
      children: [
        _buildMemberSection(colors),
        const SizedBox(height: 14),
        _buildInfoCard(colors),
        const SizedBox(height: 14),
        _buildHistoryCard(colors),
        if (_canManageGroup) ...[
          const SizedBox(height: 14),
          _buildManageCard(colors),
        ],
        if (_isOwner) ...[
          const SizedBox(height: 14),
          _buildOwnerCard(colors),
        ],
        if (!_isQuitGroupDetail) ...[
          const SizedBox(height: 14),
          _buildPersonalCard(colors),
          const SizedBox(height: 14),
          _buildExitCard(colors),
        ],
      ],
    );
  }

  /// 成员九宫格卡片（搜索 + 网格 + 邀请/移出入口）。
  Widget _buildMemberSection(ThemeColors colors) {
    final keyword = _memberKeyword.toLowerCase();
    final filtered = keyword.isEmpty
        ? _currentMembers
        : _currentMembers
            .where((m) => m.shownName.toLowerCase().contains(keyword))
            .toList();
    final display = _membersExpanded || keyword.isNotEmpty
        ? filtered
        : filtered.take(_memberCollapseLimit).toList();
    final removable =
        _currentMembers.where(_canManageMember).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          // 搜索框
          Container(
            height: 36,
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: colors.bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const SizedBox(width: 10),
                Icon(Icons.search, size: 20, color: colors.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _memberSearchCtrl,
                    style: TextStyle(fontSize: 14, color: colors.text),
                    decoration: const InputDecoration(
                      hintText: '搜索群成员',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 5,
              mainAxisSpacing: 14,
              childAspectRatio: 0.72,
            ),
            itemCount: display.length +
                (!_isQuitGroupDetail ? 1 : 0) +
                (removable.isNotEmpty ? 1 : 0),
            itemBuilder: (context, index) {
              if (index < display.length) {
                final m = display[index];
                return _MemberGridItem(
                  member: m,
                  onTap: () => _openMemberProfile(m),
                  onLongPress: () => _openMemberActions(m),
                );
              }
              // "+" 邀请 / "-" 批量移出
              final isInviteSlot =
                  index == display.length && !_isQuitGroupDetail;
              return _MemberActionSlot(
                icon: isInviteSlot ? Icons.add : Icons.remove,
                onTap: isInviteSlot ? _openInvitePicker : _openRemovePicker,
              );
            },
          ),
          if (_currentMembers.length > _memberCollapseLimit &&
              keyword.isEmpty)
            GestureDetector(
              onTap: () =>
                  setState(() => _membersExpanded = !_membersExpanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _membersExpanded ? '收起' : '查看全部 ${_currentMembers.length} 名成员',
                      style: TextStyle(fontSize: 13, color: colors.muted),
                    ),
                    Icon(
                      _membersExpanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 16,
                      color: colors.muted,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 群信息卡片：名称/公告（群主可编辑）、我的昵称、群聊备注。
  Widget _buildInfoCard(ThemeColors colors) {
    final quit = _isQuitGroupDetail;
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          _buildCell(
            colors,
            leading: const Icon(Icons.group_outlined, size: 22),
            title: '群聊名称',
            trailing: Text(
              _group?.name.isNotEmpty == true ? _group!.name : '-',
              style: TextStyle(fontSize: 15, color: colors.muted),
            ),
            onTap: _isOwner && !quit ? _editGroupName : null,
          ),
          Divider(height: 1, indent: 54, color: colors.divider),
          _buildCell(
            colors,
            leading: const Icon(Icons.campaign_outlined, size: 22),
            title: '群公告',
            trailing: Text(
              (_group?.notice ?? '').isNotEmpty ? _group!.notice : '未设置',
              style: TextStyle(fontSize: 15, color: colors.muted),
            ),
            onTap: _isOwner && !quit ? _editGroupNotice : null,
          ),
          Divider(height: 1, indent: 54, color: colors.divider),
          _buildCell(
            colors,
            leading: const Icon(Icons.badge_outlined, size: 22),
            title: '我在本群的昵称',
            trailing: Text(
              (_myMember?.displayUserName ?? '').isNotEmpty
                  ? _myMember!.displayUserName
                  : '未设置',
              style: TextStyle(fontSize: 15, color: colors.muted),
            ),
            onTap: quit ? null : _editMyNick,
          ),
          Divider(height: 1, indent: 54, color: colors.divider),
          _buildCell(
            colors,
            leading: const Icon(Icons.bookmark_border, size: 22),
            title: '群聊备注',
            trailing: Text(
              (_group?.groupRemark ?? '').isNotEmpty
                  ? _group!.groupRemark
                  : '未设置',
              style: TextStyle(fontSize: 15, color: colors.muted),
            ),
            onTap: quit ? null : _editGroupRemark,
          ),
        ],
      ),
    );
  }

  /// 聊天记录卡片：查找内容 / 推荐群聊 / 清空记录。
  Widget _buildHistoryCard(ThemeColors colors) {
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          _buildCell(
            colors,
            leading: const Icon(Icons.search, size: 22),
            title: '查找聊天内容',
            chevron: true,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    ChatSearchPage(groupId: widget.groupId),
              ),
            ),
          ),
          if (!_isQuitGroupDetail) ...[
            Divider(height: 1, indent: 54, color: colors.divider),
            _buildCell(
              colors,
              leading: const Icon(Icons.share_outlined, size: 22),
              title: '推荐群聊给朋友',
              chevron: true,
              onTap: _openRecommendPicker,
            ),
          ],
          Divider(height: 1, indent: 54, color: colors.divider),
          _buildCell(
            colors,
            leading: const Icon(Icons.delete_outline, size: 22),
            title: '清空聊天记录',
            chevron: true,
            onTap: _clearHistory,
          ),
        ],
      ),
    );
  }

  /// 群管理卡片（群主/管理员）：全员禁言、进群审批。
  Widget _buildManageCard(ThemeColors colors) {
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          _buildCell(
            colors,
            leading: const Icon(Icons.volume_off_outlined, size: 22),
            title: '全员禁言',
            trailing: Switch(value: _mutedAll, onChanged: _toggleMutedAll),
          ),
          if (_isOwner) ...[
            Divider(height: 1, indent: 54, color: colors.divider),
            _buildCell(
              colors,
              leading: const Icon(Icons.verified_outlined, size: 22),
              title: '进群需审批',
              trailing:
                  Switch(value: _joinApproval, onChanged: _toggleJoinApproval),
            ),
          ],
          if (_joinApproval) ...[
            Divider(height: 1, indent: 54, color: colors.divider),
            _buildCell(
              colors,
              leading: const Icon(Icons.pending_outlined, size: 22),
              title: '进群申请',
              chevron: true,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      GroupRequestPage(groupId: widget.groupId),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 群主专属卡片：管理员设置、转让群主。
  Widget _buildOwnerCard(ThemeColors colors) {
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          _buildCell(
            colors,
            leading: const Icon(Icons.shield_outlined, size: 22),
            title: '群管理员设置',
            chevron: true,
            onTap: _openAdminPicker,
          ),
          Divider(height: 1, indent: 54, color: colors.divider),
          _buildCell(
            colors,
            leading: const Icon(Icons.swap_horiz, size: 22),
            title: '转让群主',
            chevron: true,
            onTap: _openOwnerTransferPicker,
          ),
        ],
      ),
    );
  }

  /// 个人设置卡片：置顶聊天、消息免打扰。
  Widget _buildPersonalCard(ThemeColors colors) {
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          _buildCell(
            colors,
            leading: const Icon(Icons.push_pin_outlined, size: 22),
            title: '置顶聊天',
            trailing: Switch(value: _pinned, onChanged: _togglePinned),
          ),
          Divider(height: 1, indent: 54, color: colors.divider),
          _buildCell(
            colors,
            leading: const Icon(Icons.notifications_off_outlined, size: 22),
            title: '消息免打扰',
            trailing: Switch(value: _mySilent, onChanged: _toggleSilent),
          ),
        ],
      ),
    );
  }

  /// 退出 / 解散卡片（红色居中文字）。
  Widget _buildExitCard(ThemeColors colors) {
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(20),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: Text(
          _isOwner ? '解散群聊' : '退出群聊',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, color: Colors.red),
        ),
        onTap: _isOwner ? _dissolveGroup : _quitGroup,
      ),
    );
  }

  /// 通用列表行（对齐 user_profile_page 的 cell 风格）。
  Widget _buildCell(
    ThemeColors colors, {
    required Widget leading,
    required String title,
    Widget? trailing,
    bool chevron = false,
    VoidCallback? onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: leading,
      title: Text(title, style: const TextStyle(fontSize: 16)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing != null)
            Flexible(child: trailing),
          if (chevron)
            Icon(Icons.chevron_right, size: 20, color: colors.muted),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// 成员九宫格单项：头像 + 名字 + 角色标签。
class _MemberGridItem extends StatelessWidget {
  final ImGroupMember member;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _MemberGridItem({
    required this.member,
    required this.onTap,
    required this.onLongPress,
  });

  String? get _roleLabel => switch (member.role) {
    ImGroupRole.owner => '群主',
    ImGroupRole.admin => '管理员',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ImAvatar(src: member.avatar, name: member.nickname, size: 48),
          const SizedBox(height: 4),
          SizedBox(
            width: 56,
            child: Text(
              member.shownName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: colors.muted),
            ),
          ),
          if (_roleLabel != null)
            Container(
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFFEDF5FF),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _roleLabel!,
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF4D80F0),
                  height: 1.2,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 成员九宫格操作位（"+" 邀请 / "-" 移出）。
class _MemberActionSlot extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _MemberActionSlot({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.divider),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 26, color: colors.muted),
          ),
        ],
      ),
    );
  }
}

/// 成员多选底部弹层（邀请/移出/管理员设置/转让群主/推荐复用）。
class _MemberSelectSheet extends StatefulWidget {
  final String title;
  final List<ImGroupMember> members;
  final String confirmLabel;

  /// 危险操作确认按钮变红。
  final bool destructive;

  /// 单选模式（转让群主用）。
  final bool singleSelect;

  /// 管理员设置模式：显示当前管理员选中态。
  final bool adminMark;

  const _MemberSelectSheet({
    required this.title,
    required this.members,
    required this.confirmLabel,
    this.destructive = false,
    this.singleSelect = false,
    this.adminMark = false,
  });

  @override
  State<_MemberSelectSheet> createState() => _MemberSelectSheetState();
}

class _MemberSelectSheetState extends State<_MemberSelectSheet> {
  final Set<int> _selected = {};

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: colors.text,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, size: 20, color: colors.muted),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.divider),
          Expanded(
            child: ListView.builder(
              itemCount: widget.members.length,
              itemBuilder: (context, index) {
                final m = widget.members[index];
                final checked = _selected.contains(m.userId);
                final preSelected =
                    widget.adminMark && m.role == ImGroupRole.admin;
                final isActive = checked || preSelected;
                return ListTile(
                  leading: ImAvatar(src: m.avatar, name: m.nickname, size: 40),
                  title: Text(m.shownName,
                      style: TextStyle(fontSize: 15, color: colors.text)),
                  subtitle: widget.adminMark && m.role == ImGroupRole.owner
                      ? const Text('群主')
                      : null,
                  trailing: widget.singleSelect
                      ? Icon(
                          _selected.contains(m.userId)
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          size: 22,
                          color: _selected.contains(m.userId)
                              ? AppColors.lime
                              : colors.muted,
                        )
                      : Checkbox(
                          value: isActive,
                          activeColor: AppColors.lime,
                          onChanged: preSelected && widget.adminMark
                              ? null
                              : (v) => setState(() {
                                    v!
                                        ? _selected.add(m.userId)
                                        : _selected.remove(m.userId);
                                  }),
                        ),
                  onTap: () => setState(() {
                    if (widget.singleSelect) {
                      _selected
                        ..clear()
                        ..add(m.userId);
                    } else if (preSelected && widget.adminMark) {
                      // 已是管理员的不可取消勾选（走撤销流程）
                    } else if (isActive) {
                      _selected.remove(m.userId);
                    } else {
                      _selected.add(m.userId);
                    }
                  }),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: widget.destructive
                    ? FilledButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      )
                    : null,
                onPressed: _selected.isEmpty
                    ? null
                    : () => Navigator.pop(context, _selected.toList()),
                child: Text(
                  _selected.isEmpty
                      ? widget.confirmLabel
                      : '${widget.confirmLabel}(${_selected.length})',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
