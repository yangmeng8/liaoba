import 'package:flutter/material.dart';
import '../../shared/app_theme.dart';

/// 个性签名编辑页。
class SignatureEditPage extends StatefulWidget {
  final String initialSignature;

  const SignatureEditPage({super.key, this.initialSignature = ''});

  @override
  State<SignatureEditPage> createState() => _SignatureEditPageState();
}

class _SignatureEditPageState extends State<SignatureEditPage> {
  late final TextEditingController _controller;
  static const int _maxLength = 50;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialSignature);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _hasChanged => _controller.text.trim() != widget.initialSignature;

  void _onSave() {
    if (!_hasChanged) {
      Navigator.of(context).pop();
      return;
    }
    // TODO: 调用接口保存签名，成功后 pop 并回传
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final length = _controller.text.length;

    return Scaffold(
      backgroundColor: colors.bg,
      body: Column(
        children: [
          // 顶栏：返回 + 标题 + 右侧"保存"
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
                      '个性签名',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: colors.surfaceText,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: TextButton(
                          onPressed: _hasChanged ? _onSave : null,
                          child: Text(
                            '保存',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: _hasChanged
                                  ? colors.surfaceText
                                  : colors.muted,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 输入框
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              children: [
                Container(
                  constraints: const BoxConstraints(minHeight: 160),
                  decoration: BoxDecoration(
                    color: colors.card,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: TextField(
                    controller: _controller,
                    maxLength: _maxLength,
                    maxLines: null,
                    minLines: 5,
                    textAlignVertical: TextAlignVertical.top,
                    style: TextStyle(fontSize: 16, color: colors.text),
                    decoration: InputDecoration(
                      counterText: '$length/$_maxLength',
                      counterStyle: TextStyle(color: colors.muted),
                      hintText: '请输入您的个性签名',
                      hintStyle: TextStyle(color: colors.muted),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.all(18),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
