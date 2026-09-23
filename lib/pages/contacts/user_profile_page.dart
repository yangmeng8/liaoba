import 'package:flutter/material.dart';

import '../../models/im_conversation.dart';
import '../../models/im_message.dart' show burnDurationLabel;
import '../../services/api_client.dart';
import '../../services/auth_api.dart';
import '../../services/auth_manager.dart';
import '../../services/im_api.dart';
import '../../stores/conversation_store.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/burn_picker.dart';
import '../../shared/im_avatar.dart';
import '../chat/chat_page.dart';

/// 我与 TA 的关系（对齐 H5 三态：self / friend / stranger）。
enum _Relation { self, friend, stranger }

/// 好友资料页（对齐 H5 friend/detail 三态复用页）：
/// 聊天室头像、搜索用户、名片、联系人列表都跳这里——
/// relation 由「好友表 + 登录用户」运行时判定。
class UserProfilePage extends StatefulWidget {
  /// 目标用户编号。
  final int userId;

  /// 加好友来源上下文（1=搜索/私聊入口 2=群聊入口；
  /// 申请时告诉后端从哪加的，ImFriendAddSourceEnum）。
  final int addSource;

  /// 来源附加上下文（群聊入口=群名，随申请附带）。
  final String sourceExtra;

  const UserProfilePage({
    super.key,
    required this.userId,
    this.addSource = 1,
    this.sourceExtra = '',
  });

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  bool _loading = true;
  String? _error;
  SimpleUser? _user;
  ImFriend? _friend;
  _Relation _relation = _Relation.stranger;
  bool _actionRunning = false;

  /// 阅后即焚：当前配置（默认关）。
  bool _burnEnabled = false;
  int _burnDuration = 0;

  /// 置顶聊天（服务端会话级置顶，消息列表同步置顶）。
  bool _pinned = false;

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 数据加载（app 端无 system/user/get-simple，改用好友详情做资料源）：
  /// ① 好友详情（含昵称/头像；网络异常整页可重试）；② 关系判定（自己/好友/陌生人）；
  /// ③ 陌生人无可用资料接口 → 字母色卡 + 「用户N」兜底。
  Future<void> _loadUserInfo() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final isSelf = widget.userId == (AuthManager.instance.userId ?? 0);
    try {
      ImFriend? friend;
      if (!isSelf) {
        friend = await ImApi.getFriendDetail(friendUserId: widget.userId);
      }
      // 资料构造：自己取登录缓存；好友/拉黑好友取好友详情；陌生人留空兜底
      SimpleUser? user;
      if (isSelf) {
        user = SimpleUser(
          id: widget.userId,
          nickname: AuthManager.instance.nickname ?? '',
          avatar: AuthManager.instance.avatar ?? '',
        );
      } else if (friend != null) {
        user = SimpleUser(
          id: widget.userId,
          nickname: friend.nickname,
          avatar: friend.avatar,
        );
      }
      final relation = isSelf
          ? _Relation.self
          : (friend != null && !friend.blocked)
              ? _Relation.friend
              : _Relation.stranger;
      // 好友态：同步置顶状态 + 静默拉当前阅后即焚配置（失败保持默认，不阻塞）
      if (relation != _Relation.stranger) {
        _pinned = ConversationStore.instance
            .isConversationTop(ImConversationType.private, widget.userId);
        try {
          final burn = await ImApi.getBurnSetting(widget.userId);
          if (burn != null) {
            _burnEnabled = burn.enabled;
            _burnDuration = burn.duration;
          }
        } catch (_) {
          // 静默
        }
      }
      if (!mounted) return;
      setState(() {
        _user = user;
        _friend = friend;
        _relation = relation;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = ApiClient.errorMessage(e);
      });
    }
  }

  /// 展示名：好友备注 > 昵称 > 用户N（对齐 H5）。
  String get _displayName {
    final remark = _friend?.displayName ?? '';
    if (remark.isNotEmpty) return remark;
    final n = _user?.nickname ?? '';
    return n.isNotEmpty ? n : '用户${widget.userId}';
  }

  // ==================== 好友操作 ====================

  /// 编辑备注（对齐 H5 备注 cell 点击弹窗 → PUT /im/friend/update）。
  Future<void> _editRemark() async {
    if (_friend == null) return;
    final ctrl = TextEditingController(text: _friend!.displayName);
    final remark = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置备注'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(hintText: '好友备注（仅自己可见）'),
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
    if (remark == null || _actionRunning) return;
    setState(() => _actionRunning = true);
    try {
      await ImApi.updateFriendRemark(
        friendUserId: widget.userId,
        displayName: remark,
      );
      await _reloadFriend();
      _showMsg('备注已更新');
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    } finally {
      if (mounted) setState(() => _actionRunning = false);
    }
  }

  /// 拉黑 / 移出黑名单（对齐 H5 黑名单 switch）。
  Future<void> _toggleBlock(bool blocked) async {
    if (_actionRunning) return;
    setState(() => _actionRunning = true);
    try {
      if (blocked) {
        await ImApi.blockFriend(friendUserId: widget.userId);
      } else {
        await ImApi.unblockFriend(friendUserId: widget.userId);
      }
      await _reloadFriend();
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
      await _reloadFriend(); // 失败回滚 UI 状态
    } finally {
      if (mounted) setState(() => _actionRunning = false);
    }
  }

  /// 删除好友（红色按钮 + 确认弹窗；删除后返回上一页）。
  Future<void> _deleteFriend() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除好友'),
        content: Text('删除后将不再接收「$_displayName」的消息，确定删除吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || _actionRunning) return;
    setState(() => _actionRunning = true);
    try {
      await ImApi.deleteFriend(friendUserId: widget.userId);
      if (!mounted) return;
      _showMsg('已删除好友');
      Navigator.of(context).pop(true);
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    } finally {
      if (mounted) setState(() => _actionRunning = false);
    }
  }

  /// 好友详情刷新（备注 / 黑名单变更后）。
  Future<void> _reloadFriend() async {
    try {
      final friend = await ImApi.getFriendDetail(friendUserId: widget.userId);
      if (!mounted) return;
      setState(() {
        _friend = friend;
        _relation = (friend != null && !friend.blocked)
            ? _Relation.friend
            : _Relation.stranger;
      });
    } catch (_) {
      // 静默：保持现有展示
    }
  }

  /// 切换置顶聊天（服务端会话级置顶，多端同步；成功即刷新消息列表，
  /// 失败保持原状态并提示）。
  Future<void> _togglePinned(bool value) async {
    if (_actionRunning) return;
    setState(() => _actionRunning = true);
    try {
      await ConversationStore.instance.setConversationTop(
        ImConversationType.private,
        widget.userId,
        value,
      );
      if (!mounted) return;
      setState(() => _pinned = value);
      _showMsg(value ? '已置顶该聊天' : '已取消置顶');
    } catch (e) {
      if (mounted) _showMsg('置顶设置失败：${ApiClient.errorMessage(e)}');
    } finally {
      if (mounted) setState(() => _actionRunning = false);
    }
  }

  // ==================== 阅后即焚 ====================

  /// 当前配置文案：关 / 30秒 / 5分钟 / 2分钟（自定义）。
  String get _burnLabel =>
      !_burnEnabled || _burnDuration <= 0 ? '关' : burnDurationLabel(_burnDuration);

  /// 选项框：关 / 4星期 / 1星期 / 1天 / 8小时 / 1小时 / 5分钟 / 30秒 / 自定义。
  Future<void> _showBurnPicker() async {
    // 打开前刷新远端配置（可能是对方刚设置的）
    try {
      final burn = await ImApi.getBurnSetting(widget.userId);
      if (burn != null && mounted) {
        setState(() {
          _burnEnabled = burn.enabled;
          _burnDuration = burn.duration;
        });
      }
    } catch (_) {
      // 静默：用页面已有配置
    }
    if (!mounted) return;
    await showBurnPickerSheet(
      context,
      currentDuration: _burnEnabled ? _burnDuration : 0,
      onSet: _setBurn,
    );
  }

  /// 应用设置并刷新（0=关闭）。
  Future<void> _setBurn(int duration) async {
    if (_actionRunning) return;
    setState(() => _actionRunning = true);
    try {
      await ImApi.setBurnSetting(
        targetId: widget.userId,
        burnDuration: duration,
      );
      if (!mounted) return;
      setState(() {
        _burnEnabled = duration > 0;
        _burnDuration = duration;
      });
      _showMsg(duration > 0
          ? '已设置阅后即焚：${burnDurationLabel(duration)}'
          : '已关闭阅后即焚');
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    } finally {
      if (mounted) setState(() => _actionRunning = false);
    }
  }

  // ==================== 陌生人操作 ====================

  /// 添加好友（对齐 H5 添加朋友弹窗：申请留言 + 来源上下文贯穿）。
  Future<void> _addFriend() async {
    final ctrl = TextEditingController();
    final content = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('申请添加朋友'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 50,
          decoration: InputDecoration(
            hintText: widget.sourceExtra.isNotEmpty
                ? '你来自「${widget.sourceExtra}」，填写验证信息'
                : '填写验证信息',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (content == null || _actionRunning) return;
    setState(() => _actionRunning = true);
    try {
      await ImApi.applyFriendRequest(
        toUserId: widget.userId,
        applyContent: content,
        addSource: widget.addSource,
      );
      _showMsg('已发送好友申请');
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    } finally {
      if (mounted) setState(() => _actionRunning = false);
    }
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      body: Column(
        children: [
          // 顶部导航栏
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
                      _relation == _Relation.self ? '我的信息' : '用户资料',
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
            FilledButton(onPressed: _loadUserInfo, child: const Text('重新加载')),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 30),
      children: [
        _buildProfileCard(colors),
        if (_relation == _Relation.friend) ...[
          const SizedBox(height: 14),
          _buildFriendCard(colors),
          const SizedBox(height: 26),
          _buildMessageButton(colors),
          const SizedBox(height: 14),
          _buildDeleteButton(colors),
        ],
        if (_relation == _Relation.stranger) ...[
          const SizedBox(height: 26),
          _buildAddFriendButton(colors),
        ],
      ],
    );
  }

  /// 资料头部（三态共用）：大头像 + 展示名 + 性别 + 账号 + 部门。
  Widget _buildProfileCard(ThemeColors colors) {
    final sex = _user?.sexLabel ?? '';
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          ImAvatar(src: _user?.avatar ?? '', name: _displayName, size: 76),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  _displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                    color: colors.text,
                  ),
                ),
              ),
              if (sex.isNotEmpty) ...[
                const SizedBox(width: 6),
                Icon(
                  sex == '男' ? Icons.male : Icons.female,
                  size: 17,
                  color: sex == '男' ? Colors.blue : Colors.pink,
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '账号：${widget.userId}',
            style: TextStyle(fontSize: 13, color: colors.muted),
          ),
          if ((_user?.deptName ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '部门：${_user!.deptName}',
              style: TextStyle(fontSize: 13, color: colors.muted),
            ),
          ],
        ],
      ),
    );
  }

  /// 好友态功能卡片：备注（可编辑）/ 来源 / 添加时间 / 黑名单开关。
  Widget _buildFriendCard(ThemeColors colors) {
    final addTime = _friend?.addTime;
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          _buildCell(
            colors,
            leading: const Icon(Icons.edit_note_outlined, size: 22),
            title: '备注',
            trailing: Text(
              (_friend?.displayName ?? '').isNotEmpty
                  ? _friend!.displayName
                  : '未设置',
              style: TextStyle(fontSize: 15, color: colors.muted),
            ),
            onTap: _editRemark,
          ),
          Divider(height: 1, indent: 54, color: colors.divider),
          _buildCell(
            colors,
            leading: const Icon(Icons.link_outlined, size: 22),
            title: '来源',
            trailing: Text(
              _friend?.addSourceLabel ?? '-',
              style: TextStyle(fontSize: 15, color: colors.muted),
            ),
          ),
          Divider(height: 1, indent: 54, color: colors.divider),
          _buildCell(
            colors,
            leading: const Icon(Icons.schedule_outlined, size: 22),
            title: '添加时间',
            trailing: Text(
              addTime != null
                  ? '${addTime.year}-${addTime.month.toString().padLeft(2, '0')}-${addTime.day.toString().padLeft(2, '0')}'
                  : '-',
              style: TextStyle(fontSize: 15, color: colors.muted),
            ),
          ),
          Divider(height: 1, indent: 54, color: colors.divider),
          _buildCell(
            colors,
            leading: const Icon(Icons.block_outlined, size: 22),
            title: '加入黑名单',
            trailing: Switch(
              value: _friend?.blocked ?? false,
              onChanged: _actionRunning ? null : _toggleBlock,
            ),
          ),
          Divider(height: 1, indent: 54, color: colors.divider),
          _buildCell(
            colors,
            leading: const Icon(Icons.local_fire_department_outlined,
                size: 22),
            title: '阅后即焚',
            trailing: Text(
              _burnLabel,
              style: TextStyle(fontSize: 15, color: colors.muted),
            ),
            onTap: _actionRunning ? null : _showBurnPicker,
          ),
          Divider(height: 1, indent: 54, color: colors.divider),
          _buildCell(
            colors,
            leading: const Icon(Icons.push_pin_outlined, size: 22),
            title: '置顶聊天',
            trailing: Switch(
              value: _pinned,
              onChanged: _actionRunning ? null : _togglePinned,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCell(
    ThemeColors colors, {
    required Widget leading,
    required String title,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              leading,
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 16, color: colors.text),
                ),
              ),
              if (trailing != null) trailing,
              if (onTap != null)
                Icon(Icons.chevron_right, size: 20, color: colors.muted),
            ],
          ),
        ),
      ),
    );
  }

  /// 发消息（回聊天室，对齐 H5 主操作）。
  Widget _buildMessageButton(ThemeColors colors) {
    return SizedBox(
      height: 50,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.lime,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChatPage(
                type: ImConversationType.private,
                targetId: widget.userId,
                title: _displayName,
                avatar: _user?.avatar ?? '',
              ),
            ),
          );
        },
        icon: const Icon(Icons.chat_bubble_outline, size: 20),
        label: const Text('发消息', style: TextStyle(fontSize: 16)),
      ),
    );
  }

  /// 删除好友（红色，确认弹窗）。
  Widget _buildDeleteButton(ThemeColors colors) {
    return SizedBox(
      height: 50,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.red,
          side: const BorderSide(color: Colors.redAccent),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        onPressed: _actionRunning ? null : _deleteFriend,
        icon: const Icon(Icons.person_remove_outlined, size: 20),
        label: const Text('删除好友', style: TextStyle(fontSize: 16)),
      ),
    );
  }

  /// 陌生人：添加朋友（带来源上下文的申请）。
  Widget _buildAddFriendButton(ThemeColors colors) {
    return SizedBox(
      height: 50,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.lime,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        onPressed: _actionRunning ? null : _addFriend,
        icon: const Icon(Icons.person_add_alt_1_outlined, size: 20),
        label: const Text('添加朋友', style: TextStyle(fontSize: 16)),
      ),
    );
  }
}
