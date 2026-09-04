import 'package:flutter/material.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';

/// 昵称编辑页。
class NicknameEditPage extends StatefulWidget {
  final String initialNickname;

  const NicknameEditPage({super.key, this.initialNickname = '李猛'});

  @override
  State<NicknameEditPage> createState() => _NicknameEditPageState();
}

class _NicknameEditPageState extends State<NicknameEditPage> {
  late final TextEditingController _controller;
  static const int _maxLength = 14;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialNickname);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _hasChanged => _controller.text.trim() != widget.initialNickname;
  bool get _isEmpty => _controller.text.trim().isEmpty;

  void _onSave() {
    if (_isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('昵称不能为空')),
      );
      return;
    }
    if (!_hasChanged) {
      Navigator.of(context).pop();
      return;
    }
    // TODO: 调用接口保存昵称，成功后 pop 并回传
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
          // 顶栏
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
                      '昵称',
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

          // 内容区
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              children: [
                // 输入框卡片
                Container(
                  decoration: BoxDecoration(
                    color: colors.card,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: TextField(
                    controller: _controller,
                    maxLength: _maxLength,
                    style: TextStyle(fontSize: 17, color: colors.text),
                    decoration: InputDecoration(
                      counterText: '$length/$_maxLength',
                      counterStyle: TextStyle(color: colors.muted),
                      hintText: '请输入昵称',
                      hintStyle: TextStyle(color: colors.muted),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 18,
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),

                // 提示：info 图标 + 文字
                Padding(
                  padding: const EdgeInsets.only(top: 16, left: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: colors.divider,
                        ),
                        child: Icon(
                          Icons.info_outline,
                          size: 14,
                          color: colors.muted,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '修改成功后，7天内无法再次修改',
                          style: TextStyle(fontSize: 14, color: colors.muted),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 40),

                // 保存按钮
                SizedBox(
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _onSave,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.lime,
                      foregroundColor: Colors.black,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    child: const Text(
                      '保存',
                      style:
                          TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
                    ),
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
