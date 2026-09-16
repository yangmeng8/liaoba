import 'package:flutter/material.dart';

import '../../models/im_conversation.dart';
import '../../services/api_client.dart';
import '../../services/auth_api.dart';
import '../../services/auth_manager.dart';
import '../../services/im_api.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/im_avatar.dart';

/// 添加好友页：手机号搜索目标用户（/app-api/member/user/findUserByMobile）+
/// 好友备注（≤16，apply 的 displayName）+ 申请理由（≤255，自动填充「我是昵称」）。
class FriendApplyPage extends StatefulWidget {
  const FriendApplyPage({super.key});

  @override
  State<FriendApplyPage> createState() => _FriendApplyPageState();
}

class _FriendApplyPageState extends State<FriendApplyPage> {
  final _mobileCtrl = TextEditingController();
  final _remarkCtrl = TextEditingController();
  final _contentCtrl = TextEditingController();

  /// 已是好友的用户编号集合（搜索结果标记「已添加」用）。
  final Set<int> _friendIds = {};

  /// 搜索命中的目标用户（null=未选中）。
  SimpleUser? _target;

  bool _searching = false;
  bool _isFriend = false;
  bool _isSelf = false;

  /// 搜索提示（未找到 / 格式错误 / 失败原因）。
  String? _searchMsg;

  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _mobileCtrl.dispose();
    _remarkCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  /// 拉好友列表（标记「已添加」用，失败静默）+ 申请理由预填「我是昵称」。
  Future<void> _init() async {
    try {
      final friends = await ImApi.getFriendList();
      if (!mounted) return;
      _friendIds
        ..clear()
        ..addAll(friends
            .where((f) => f.status == ImCommonStatus.enable)
            .map((f) => f.friendUserId));
    } catch (_) {
      // 静默：仅影响「已添加」标记，不阻塞页面
    }
    final myNickname = AuthManager.instance.nickname ?? '';
    _contentCtrl.text = '我是$myNickname';
  }

  /// 手机号搜索目标用户。
  Future<void> _search() async {
    final mobile = _mobileCtrl.text.trim();
    if (mobile.isEmpty) {
      setState(() => _searchMsg = '请输入对方手机号');
      return;
    }
    if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(mobile)) {
      setState(() => _searchMsg = '手机号格式不正确');
      return;
    }
    setState(() {
      _searching = true;
      _searchMsg = null;
      _target = null;
    });
    try {
      final user = await AuthApi.findUserByMobile(mobile);
      if (!mounted) return;
      setState(() {
        _searching = false;
        _target = user;
        if (user == null) {
          _searchMsg = '未找到该手机号对应的用户';
        } else {
          _isSelf = user.id == (AuthManager.instance.userId ?? 0);
          _isFriend = _friendIds.contains(user.id);
          if (_isSelf) {
            _searchMsg = '不能添加自己为好友';
          } else if (_isFriend) {
            _searchMsg = '对方已经是你的好友';
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchMsg = ApiClient.errorMessage(e);
      });
    }
  }

  /// 提交好友申请。
  Future<void> _submit() async {
    if (_submitting) return;
    final target = _target;
    if (target == null) {
      _showMsg('请先通过手机号搜索并选择用户');
      return;
    }
    if (_isSelf) {
      _showMsg('不能添加自己为好友');
      return;
    }
    if (_isFriend) {
      _showMsg('对方已经是你的好友');
      return;
    }
    final content = _contentCtrl.text.trim();
    if (content.isEmpty) {
      _showMsg('请填写申请理由');
      return;
    }
    setState(() => _submitting = true);
    try {
      await ImApi.applyFriendRequest(
        toUserId: target.id,
        applyContent: content,
        displayName: _remarkCtrl.text.trim(),
        addSource: 1,
      );
      if (!mounted) return;
      _showMsg('申请已发送，等待对方处理');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _showMsg(ApiClient.errorMessage(e));
    }
  }

  void _showMsg(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      body: Column(
        children: [
          _buildHeader(colors),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildCard(colors, [
                  _buildSearchField(colors),
                  _buildDivider(colors),
                  _buildSearchResult(colors),
                ]),
                const SizedBox(height: 22),
                _buildCard(colors, [
                  _buildField(
                    colors,
                    label: '好友备注',
                    hint: '请输入好友备注（选填，对方不可见）',
                    controller: _remarkCtrl,
                    maxLength: 16,
                  ),
                  _buildDivider(colors),
                  _buildField(
                    colors,
                    label: '申请理由',
                    hint: '请输入申请理由',
                    controller: _contentCtrl,
                    maxLength: 255,
                    multiline: true,
                  ),
                ]),
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.lime,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(_submitting ? '提交中…' : '发送申请'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeColors colors) {
    return Container(
      color: colors.surface,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, size: 22),
                color: colors.surfaceText,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Text(
                  '添加好友',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: colors.surfaceText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard(ThemeColors colors, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildDivider(ThemeColors colors) =>
      Divider(height: 1, indent: 16, endIndent: 16, color: colors.divider);

  /// 手机号输入行：回车 / 点击「搜索」触发查找。
  Widget _buildSearchField(ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Text('手机号', style: TextStyle(fontSize: 15, color: colors.text)),
          const SizedBox(width: 16),
          Expanded(
            child: TextField(
              controller: _mobileCtrl,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: '输入对方手机号',
                isDense: true,
                counterText: '',
                border: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.divider),
                  borderRadius: BorderRadius.circular(8),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.divider),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          TextButton(
            onPressed: _searching ? null : _search,
            child: Text(
              _searching ? '搜索中' : '搜索',
              style: const TextStyle(fontSize: 15, color: AppColors.lime),
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索结果区：搜索中 / 提示 / 命中卡片三态。
  Widget _buildSearchResult(ThemeColors colors) {
    if (_searching) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(color: AppColors.lime, strokeWidth: 2.5),
          ),
        ),
      );
    }
    final t = _target;
    if (t == null) {
      final msg = _searchMsg ?? '输入对方手机号，点击搜索';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(msg, style: TextStyle(fontSize: 14, color: colors.muted)),
        ),
      );
    }
    final disabled = _isSelf || _isFriend;
    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            ImAvatar(src: t.avatar, name: t.nickname, size: 46),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.nickname.isEmpty ? '用户${t.id}' : t.nickname,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, color: colors.text),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '账号：${t.id}',
                    style: TextStyle(fontSize: 12, color: colors.muted),
                  ),
                ],
              ),
            ),
            if (_isFriend)
              Text('已添加', style: TextStyle(fontSize: 13, color: colors.muted))
            else if (!_isSelf)
              const Icon(Icons.check_circle, size: 20, color: AppColors.lime),
          ],
        ),
      ),
    );
  }

  Widget _buildField(
    ThemeColors colors, {
    required String label,
    required String hint,
    required TextEditingController controller,
    required int maxLength,
    bool multiline = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 15, color: colors.text)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            maxLength: maxLength,
            maxLines: multiline ? 3 : 1,
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              counterText: '',
              border: OutlineInputBorder(
                borderSide: BorderSide(color: colors.divider),
                borderRadius: BorderRadius.circular(8),
              ),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: colors.divider),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
