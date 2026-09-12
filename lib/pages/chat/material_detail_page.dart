import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/im_conversation.dart';
import '../../services/api_client.dart';
import '../../services/im_api.dart';
import '../../shared/app_theme.dart';

/// 频道素材详情页（对应 H5 /material/index）：
/// 气泡点击后按 materialId 拉取正文；title/summary/封面/富文本内容/外链。
class MaterialDetailPage extends StatefulWidget {
  final int id;

  const MaterialDetailPage({super.key, required this.id});

  @override
  State<MaterialDetailPage> createState() => _MaterialDetailPageState();
}

class _MaterialDetailPageState extends State<MaterialDetailPage> {
  bool _loading = true;
  ImChannelMaterial? _detail;
  String? _error;

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
      final detail = await ImApi.getChannelMaterial(id: widget.id);
      if (!mounted) return;
      setState(() => _detail = detail);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ApiClient.errorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 复制外链（无浏览器跳转依赖，复制后由用户自行打开）。
  Future<void> _copyUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('链接已复制，请在浏览器打开')));
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
                : _detail == null
                    ? _buildEmpty(colors)
                    : _buildBody(colors),
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
                  '频道消息',
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

  Widget _buildEmpty(ThemeColors colors) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(_error ?? '频道消息不存在',
              style: TextStyle(color: colors.muted, fontSize: 15)),
          if (_error != null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(ThemeColors colors) {
    final d = _detail!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
      children: [
        Text(
          d.title.isEmpty ? '频道消息' : d.title,
          style: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w600,
            height: 1.4,
            color: colors.text,
          ),
        ),
        if (d.summary.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            d.summary,
            style: TextStyle(fontSize: 14, height: 1.5, color: colors.muted),
          ),
        ],
        if (d.coverUrl.isNotEmpty) ...[
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              d.coverUrl,
              height: 180,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox(height: 180),
            ),
          ),
        ],
        if (d.content.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            _plainContent(d.content),
            style: TextStyle(fontSize: 15, height: 1.7, color: colors.text),
          ),
        ],
        if (d.url.isNotEmpty) ...[
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => _copyUrl(d.url),
            child: Text(
              '查看原文',
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF576B95),
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
        if (d.content.isEmpty && d.url.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 60),
            child: Center(
              child: Text('暂无正文', style: TextStyle(color: colors.muted)),
            ),
          ),
      ],
    );
  }

  /// 富文本转纯文本（去标签 + 实体反转义 + 段落换行；与公告详情同款算法）。
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
}
