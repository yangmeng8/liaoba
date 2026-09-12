import 'package:flutter/material.dart';

import '../../../services/auth_manager.dart';
import '../../../services/notice_api.dart';
import '../../../shared/app_theme.dart';
import '../../../shared/widgets.dart';
import 'notice_detail_page.dart';
import 'notice_form_page.dart';

/// 通知公告列表页（对应 H5 /pages-system/notice/index，管理端 CRUD）：
/// 分页列表（下拉刷新 + 触底加载）+ 顶部筛选弹层（标题/状态）+
/// FAB 新增（权限）+ 点击卡片进详情；跨页刷新用 push 返回值替代事件总线。
class NoticeListPage extends StatefulWidget {
  const NoticeListPage({super.key});

  @override
  State<NoticeListPage> createState() => _NoticeListPageState();
}

class _NoticeListPageState extends State<NoticeListPage> {
  static const int _pageSize = 10;

  final ScrollController _scrollCtrl = ScrollController();

  /// 已加载列表数据（升序追加）。
  List<Notice> _list = [];

  /// 搜索条件：标题关键词 + 状态（null=全部）。
  String _titleFilter = '';
  int? _statusFilter;

  int _pageNo = 1;
  int _total = 0;
  bool _loading = false;
  bool _loadedOnce = false;

  bool get _hasMore => _list.length < _total;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 触底自动加载下一页。
  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.extentAfter < 120 && _hasMore && !_loading) {
      _loadMore();
    }
  }

  /// 重载第一页（下拉刷新 / 筛选变更 / 子页操作返回 true）。
  Future<void> _reload() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final page = await NoticeApi.getNoticePage(
        pageNo: 1,
        pageSize: _pageSize,
        title: _titleFilter,
        status: _statusFilter,
      );
      if (!mounted) return;
      setState(() {
        _list = page.list;
        _total = page.total;
        _pageNo = 1;
        _loadedOnce = true;
      });
    } catch (_) {
      // 失败保留旧数据不白屏（对应 H5 complete(false)）
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('加载失败，请重试')));
        setState(() => _loadedOnce = true);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 加载下一页。
  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final page = await NoticeApi.getNoticePage(
        pageNo: _pageNo + 1,
        pageSize: _pageSize,
        title: _titleFilter,
        status: _statusFilter,
      );
      if (!mounted) return;
      setState(() {
        _list.addAll(page.list);
        _total = page.total;
        _pageNo++;
      });
    } catch (_) {
      // 静默：翻页失败保留旧数据，用户下拉刷新可恢复
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 打开筛选弹层（对应 H5 SearchForm popup：标题输入 + 状态单选组）。
  Future<void> _openSearchForm() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.colors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _NoticeSearchSheet(
        initialTitle: _titleFilter,
        initialStatus: _statusFilter,
      ),
    );
    if (result == null) return;
    setState(() {
      _titleFilter = result['title'] as String;
      _statusFilter = result['status'] as int?;
    });
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final canCreate = AuthManager.instance.hasAccess('system:notice:create');
    return Scaffold(
      backgroundColor: colors.bg,
      floatingActionButton: canCreate
          ? FloatingActionButton(
              backgroundColor: colors.surface,
              foregroundColor: colors.surfaceText,
              onPressed: _create,
              child: const Icon(Icons.add),
            )
          : null,
      body: Column(
        children: [
          _buildHeader(colors),
          Expanded(
            child: _loadedOnce && _list.isEmpty && !_loading
                ? const EmptyState(label: '暂无公告')
                : RefreshIndicator(
                    onRefresh: _reload,
                    child: ListView.separated(
                      controller: _scrollCtrl,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 88),
                      itemCount: _list.length + (_loading ? 1 : 0),
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, color: colors.divider),
                      itemBuilder: (context, i) {
                        if (i == _list.length) {
                          return const Padding(
                            padding: EdgeInsets.all(14),
                            child: Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          );
                        }
                        return _NoticeCard(
                          notice: _list[i],
                          onTap: () => _openDetail(_list[i]),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 顶部：返回 + 标题 + 筛选按钮（选中条件时高亮提示）。
  Widget _buildHeader(ThemeColors colors) {
    final hasFilter = _titleFilter.isNotEmpty || _statusFilter != null;
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
                  '通知公告',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: colors.surfaceText,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: IconButton(
                  icon: Icon(
                    Icons.tune,
                    size: 24,
                    color: hasFilter ? colors.surfaceText : colors.muted,
                  ),
                  onPressed: _openSearchForm,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _create() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const NoticeFormPage()),
    );
    if (changed == true) _reload();
  }

  Future<void> _openDetail(Notice notice) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => NoticeDetailPage(id: notice.id),
      ),
    );
    if (changed == true) _reload();
  }
}

/// 公告卡片（对应 H5 列表行）：标题 + 状态标签 / 内容截断 / 类型标签 + 时间。
class _NoticeCard extends StatelessWidget {
  final Notice notice;
  final VoidCallback onTap;

  const _NoticeCard({required this.notice, required this.onTap});

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    final local = time.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: colors.card,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    notice.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: colors.text,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _DictTag(
                  text: notice.enabled ? '开启' : '关闭',
                  color: notice.enabled
                      ? const Color(0xFF07C160)
                      : const Color(0xFFFA5151),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              notice.content,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: colors.muted),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _DictTag(
                  text: NoticeType.label(notice.type),
                  color: notice.type == NoticeType.announcement
                      ? const Color(0xFFFA9D3B)
                      : const Color(0xFF1A95FF),
                ),
                const Spacer(),
                Text(
                  _formatTime(notice.createTime),
                  style: TextStyle(fontSize: 12, color: colors.muted),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 字典标签（对应 H5 dict-tag：淡底色圆角小标签）。
class _DictTag extends StatelessWidget {
  final String text;
  final Color color;

  const _DictTag({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: color),
      ),
    );
  }
}

/// 筛选弹层（对应 H5 search-form：标题输入 + 状态单选组，全部=null）。
class _NoticeSearchSheet extends StatefulWidget {
  final String initialTitle;
  final int? initialStatus;

  const _NoticeSearchSheet({
    required this.initialTitle,
    required this.initialStatus,
  });

  @override
  State<_NoticeSearchSheet> createState() => _NoticeSearchSheetState();
}

class _NoticeSearchSheetState extends State<_NoticeSearchSheet> {
  late final TextEditingController _titleCtrl;
  int? _status;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.initialTitle);
    _status = widget.initialStatus;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop({
      'title': _titleCtrl.text.trim(),
      'status': _status,
    });
  }

  void _reset() {
    Navigator.of(context).pop({'title': '', 'status': null});
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
            child: Text(
              '公告筛选',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _titleCtrl,
              decoration: InputDecoration(
                labelText: '公告标题',
                hintText: '请输入公告标题',
                isDense: true,
                border: const OutlineInputBorder(),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.divider),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text('公告状态',
                style: TextStyle(fontSize: 14, color: colors.muted)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Wrap(
              spacing: 10,
              children: [
                for (final (label, value) in [
                  ('全部', null),
                  ('开启', 0),
                  ('关闭', 1),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _status == value,
                    onSelected: (_) => setState(() => _status = value),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: _reset, child: const Text('重置')),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(onPressed: _submit, child: const Text('搜索')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
