import 'package:flutter/material.dart';

import '../../models/im_conversation.dart';
import '../../services/api_client.dart';
import '../../services/im_api.dart';
import '../../shared/app_theme.dart';
import '../../shared/im_avatar.dart';

/// 进群申请管理页（对齐 H5 group-request-list，群主/管理员视角）：
/// 待处理置顶可同意/拒绝；已处理记录置灰仅展示。
class GroupRequestPage extends StatefulWidget {
  final int groupId;

  const GroupRequestPage({super.key, required this.groupId});

  @override
  State<GroupRequestPage> createState() => _GroupRequestPageState();
}

class _GroupRequestPageState extends State<GroupRequestPage> {
  bool _loading = true;
  String? _error;
  List<ImGroupRequest> _requests = [];
  bool _handling = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list =
          await ImApi.getGroupRequestList(groupId: widget.groupId);
      if (!mounted) return;
      // 待处理在前，其余按申请时间倒序
      list.sort((a, b) {
        if (a.pending != b.pending) return a.pending ? -1 : 1;
        final at = a.createTime ?? DateTime(2000);
        final bt = b.createTime ?? DateTime(2000);
        return bt.compareTo(at);
      });
      setState(() => _requests = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ApiClient.errorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _agree(ImGroupRequest r) async {
    if (_handling) return;
    setState(() => _handling = true);
    try {
      await ImApi.agreeGroupRequest(id: r.id);
      _showMsg('已同意');
      await _load();
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    } finally {
      if (mounted) setState(() => _handling = false);
    }
  }

  Future<void> _refuse(ImGroupRequest r) async {
    if (_handling) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('提示'),
        content: Text('确定拒绝"${r.shownName}"的进群申请吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('拒绝'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _handling = true);
    try {
      await ImApi.refuseGroupRequest(id: r.id);
      _showMsg('已拒绝');
      await _load();
    } catch (e) {
      _showMsg(ApiClient.errorMessage(e));
    } finally {
      if (mounted) setState(() => _handling = false);
    }
  }

  String _formatTime(DateTime? t) {
    if (t == null) return '';
    final local = t.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      body: Column(
        children: [
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
                      '进群申请',
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
            FilledButton(onPressed: _load, child: const Text('重新加载')),
          ],
        ),
      );
    }
    if (_requests.isEmpty) {
      return Center(
        child: Text('暂无进群申请',
            style: TextStyle(fontSize: 14, color: colors.muted)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _requests.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: colors.divider),
      itemBuilder: (context, index) {
        final r = _requests[index];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: ImAvatar(src: r.userAvatar, name: r.shownName, size: 40),
          title: Text(r.shownName,
              style: TextStyle(fontSize: 15, color: colors.text)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (r.applyContent.isNotEmpty)
                Text(r.applyContent,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: colors.muted)),
              Text(
                _formatTime(r.createTime),
                style: TextStyle(fontSize: 12, color: colors.muted),
              ),
            ],
          ),
          trailing: r.pending
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OutlinedButton(
                      onPressed: _handling ? null : () => _refuse(r),
                      child: const Text('拒绝'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _handling ? null : () => _agree(r),
                      child: const Text('同意'),
                    ),
                  ],
                )
              : Text(
                  r.handleResultLabel,
                  style: TextStyle(fontSize: 13, color: colors.muted),
                ),
        );
      },
    );
  }
}
