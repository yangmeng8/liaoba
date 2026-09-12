import 'package:flutter/material.dart';

import '../../../services/api_client.dart';
import '../../../services/notice_api.dart';
import '../../../shared/app_theme.dart';

/// 公告表单页（对应 H5 /pages-system/notice/form，新增/编辑二态复用）：
/// 无 id 新增（状态默认开启）/ 有 id 编辑（拉取回填）；
/// 校验：标题必填、内容必填、类型必选、备注 ≤200 字。
class NoticeFormPage extends StatefulWidget {
  /// 编辑目标编号（null=新增）。
  final int? id;

  const NoticeFormPage({super.key, this.id});

  @override
  State<NoticeFormPage> createState() => _NoticeFormPageState();
}

class _NoticeFormPageState extends State<NoticeFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _contentCtrl = TextEditingController();
  final _remarkCtrl = TextEditingController();

  /// 公告类型（1=通知 2=公告）。
  int _type = NoticeType.notification;

  /// 公告状态（0=开启 1=关闭；新增默认开启，对齐 H5）。
  int _status = 0;

  bool _loading = false; // 编辑回填期间展示 loading
  bool _submitting = false;

  bool get _isEdit => widget.id != null;

  @override
  void initState() {
    super.initState();
    if (widget.id != null) {
      _loading = true; // 编辑需先拉详情回填
      _loadForEdit();
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _contentCtrl.dispose();
    _remarkCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadForEdit() async {
    try {
      final n = await NoticeApi.getNotice(id: widget.id!);
      if (!mounted) return;
      setState(() {
        _titleCtrl.text = n.title;
        _contentCtrl.text = n.content;
        _remarkCtrl.text = n.remark;
        _type = n.type;
        _status = n.status;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(ApiClient.errorMessage(e))));
      Navigator.of(context).pop();
      return;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 提交：校验 → 有 id 走 update / 无 id 走 create → 提示 → pop(true)。
  Future<void> _submit() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _submitting = true);
    final notice = Notice(
      id: widget.id ?? 0,
      title: _titleCtrl.text.trim(),
      content: _contentCtrl.text.trim(),
      type: _type,
      status: _status,
      remark: _remarkCtrl.text.trim(),
      createTime: null,
    );
    try {
      if (_isEdit) {
        await NoticeApi.updateNotice(notice: notice);
      } else {
        await NoticeApi.createNotice(notice: notice);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(_isEdit ? '编辑成功' : '新增成功')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(ApiClient.errorMessage(e))));
    }
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
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Form(
                    key: _formKey,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _buildCard(colors, [
                          _buildTitleField(colors),
                          _divider(colors),
                          _buildContentField(colors),
                        ]),
                        const SizedBox(height: 14),
                        _buildCard(colors, [
                          _buildTypePicker(colors),
                          _divider(colors),
                          _buildStatusPicker(colors),
                        ]),
                        const SizedBox(height: 14),
                        _buildCard(colors, [
                          _buildRemarkField(colors),
                        ]),
                        const SizedBox(height: 22),
                        FilledButton(
                          onPressed: _submitting ? null : _submit,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: Text(_submitting ? '提交中…' : '确 定'),
                        ),
                      ],
                    ),
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
                  _isEdit ? '编辑通知公告' : '新增通知公告',
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

  Widget _divider(ThemeColors colors) =>
      Divider(height: 1, indent: 16, endIndent: 16, color: colors.divider);

  /// 公告标题（必填）。
  Widget _buildTitleField(ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: TextFormField(
        controller: _titleCtrl,
        decoration: InputDecoration(
          labelText: '公告标题',
          hintText: '请输入公告标题',
          border: InputBorder.none,
        ),
        validator: (v) =>
            (v ?? '').trim().isEmpty ? '公告标题不能为空' : null,
      ),
    );
  }

  /// 公告内容（必填，多行）。
  Widget _buildContentField(ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: TextFormField(
        controller: _contentCtrl,
        maxLines: 5,
        minLines: 4,
        keyboardType: TextInputType.multiline,
        decoration: const InputDecoration(
          labelText: '公告内容',
          hintText: '请输入公告内容',
          alignLabelWithHint: true,
          border: InputBorder.none,
        ),
        validator: (v) =>
            (v ?? '').trim().isEmpty ? '公告内容不能为空' : null,
      ),
    );
  }

  /// 公告类型（radio 按钮组：通知/公告，必选默认通知）。
  Widget _buildTypePicker(ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Text('公告类型',
              style: TextStyle(fontSize: 15, color: colors.text)),
          const Spacer(),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: NoticeType.notification, label: Text('通知')),
              ButtonSegment(
                  value: NoticeType.announcement, label: Text('公告')),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
        ],
      ),
    );
  }

  /// 公告状态（radio 按钮组：开启/关闭，默认开启）。
  Widget _buildStatusPicker(ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Text('公告状态',
              style: TextStyle(fontSize: 15, color: colors.text)),
          const Spacer(),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('开启')),
              ButtonSegment(value: 1, label: Text('关闭')),
            ],
            selected: {_status},
            onSelectionChanged: (s) => setState(() => _status = s.first),
          ),
        ],
      ),
    );
  }

  /// 备注（≤200 字，带计数）。
  Widget _buildRemarkField(ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: TextFormField(
        controller: _remarkCtrl,
        maxLength: 200,
        maxLines: 2,
        decoration: const InputDecoration(
          labelText: '备注',
          hintText: '请输入备注（选填）',
          alignLabelWithHint: true,
          border: InputBorder.none,
          counterText: '',
        ),
        buildCounter: (_, {required currentLength, required isFocused, maxLength}) =>
            Text('$currentLength/200',
                style: TextStyle(fontSize: 12, color: colors.muted)),
        validator: (v) =>
            (v ?? '').length > 200 ? '备注不能超过 200 字' : null,
      ),
    );
  }
}
