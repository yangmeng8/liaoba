import 'package:flutter/material.dart';

import '../../../services/api_client.dart';
import '../../../services/auth_manager.dart';
import '../../../services/notice_api.dart';
import '../../../shared/app_theme.dart';
import 'notice_form_page.dart';

/// 公告详情页（对应 H5 /pages-system/notice/detail）：
/// 只读展示 + 底部编辑/删除（权限驱动显隐）；操作成功 pop(true) 通知列表刷新。
class NoticeDetailPage extends StatefulWidget {
  final int id;

  const NoticeDetailPage({super.key, required this.id});

  @override
  State<NoticeDetailPage> createState() => _NoticeDetailPageState();
}

class _NoticeDetailPageState extends State<NoticeDetailPage> {
  bool _loading = true;
  String? _error;
  Notice? _notice;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final notice = await NoticeApi.getNotice(id: widget.id);
      if (!mounted) return;
      setState(() => _notice = notice);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ApiClient.errorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 删除：二次确认 → DELETE → 提示 → 返回列表（pop true 触发刷新）。
  Future<void> _delete() async {
    if (_deleting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('提示'),
        content: const Text('是否确认删除该公告？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      await NoticeApi.deleteNotice(id: widget.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('删除成功')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(ApiClient.errorMessage(e))));
    }
  }

  /// 编辑：跳表单页；表单保存成功 pop(true) 逐层传回列表刷新。
  Future<void> _edit() async {
    final notice = _notice;
    if (notice == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => NoticeFormPage(id: notice.id),
      ),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final canUpdate = AuthManager.instance.hasAccess('system:notice:update');
    final canDelete = AuthManager.instance.hasAccess('system:notice:delete');
    return Scaffold(
      backgroundColor: colors.bg,
      body: Column(
        children: [
          _buildHeader(colors),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _buildError(colors)
                    : _buildBody(colors),
          ),
          if (!_loading && _notice != null && (canUpdate || canDelete))
            _buildActions(colors, canUpdate, canDelete),
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
                  '公告详情',
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

  Widget _buildError(ThemeColors colors) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(_error ?? '加载失败',
              style: TextStyle(color: colors.muted, fontSize: 15)),
          const SizedBox(height: 16),
          FilledButton(onPressed: _load, child: const Text('重试')),
        ],
      ),
    );
  }

  /// 只读字段组（对应 H5 wd-cell-group：编号/标题/内容/类型/状态/备注/创建时间）。
  Widget _buildBody(ThemeColors colors) {
    final n = _notice!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              _cell(colors, '编号', '${n.id}'),
              _divider(colors),
              _cell(colors, '标题', n.title),
              _divider(colors),
              _cell(colors, '类型', NoticeType.label(n.type)),
              _divider(colors),
              _cell(colors, '状态', n.enabled ? '开启' : '关闭'),
              _divider(colors),
              _cell(colors, '创建时间', _formatTime(n.createTime), multiline: false),
              _divider(colors),
              _cell(colors, '备注', n.remark.isEmpty ? '-' : n.remark),
              _divider(colors),
              // 内容支持富文本 HTML，清洗标签后按多行文本展示
              _cell(colors, '内容', _plainContent(n.content)),
            ],
          ),
        ),
      ],
    );
  }

  /// 富文本内容转纯文本：去标签 + 反转义常见实体 + 段落换行。
  String _plainContent(String html) {
    var text = html
        .replaceAllMapped(
          RegExp(r'<br\s*/?>|</p>|</div>', caseSensitive: false),
          (_) => '\n',
        )
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"');
    return text.trim();
  }

  Widget _divider(ThemeColors colors) =>
      Divider(height: 1, indent: 16, endIndent: 16, color: colors.divider);

  Widget _cell(ThemeColors colors, String label, String value,
      {bool multiline = true}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(label,
                style: TextStyle(fontSize: 14, color: colors.muted)),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              style: TextStyle(
                fontSize: 15,
                color: colors.text,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(ThemeColors colors, bool canUpdate, bool canDelete) {
    return Container(
      color: colors.surface,
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 12,
        bottom: MediaQuery.of(context).padding.bottom + 16,
      ),
      child: Row(
        children: [
          if (canUpdate)
            Expanded(
              child: OutlinedButton(
                onPressed: _edit,
                child: const Text('编辑'),
              ),
            ),
          if (canUpdate && canDelete) const SizedBox(width: 12),
          if (canDelete)
            Expanded(
              child: FilledButton(
                onPressed: _deleting ? null : _delete,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFA5151),
                  foregroundColor: Colors.white,
                ),
                child: Text(_deleting ? '删除中…' : '删除'),
              ),
            ),
        ],
      ),
    );
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    final local = time.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
  }
}
