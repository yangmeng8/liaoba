import 'package:flutter/material.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';

/// 聊天设置页面。
class ChatSettingsPage extends StatefulWidget {
  const ChatSettingsPage({super.key});

  @override
  State<ChatSettingsPage> createState() => _ChatSettingsPageState();
}

class _ChatSettingsPageState extends State<ChatSettingsPage> {
  bool _useReceiver = false;

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

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
                      '聊天设置',
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

          // 设置项卡片（带圆角）
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: colors.card,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      _RowItem(
                        title: '聊天列表',
                        trailing: Icon(Icons.chevron_right,
                            size: 26, color: colors.muted),
                        colors: colors,
                        showDivider: true,
                        onTap: () {
                          // TODO: 跳转到聊天列表相关设置
                          _toast('聊天列表设置');
                        },
                      ),
                      _RowItem(
                        title: '使用听筒播放语音消息',
                        trailing: Switch(
                          value: _useReceiver,
                          activeThumbColor: colors.card,
                          activeTrackColor: AppColors.lime,
                          trackOutlineColor:
                              const WidgetStatePropertyAll(Colors.transparent),
                          inactiveThumbColor: colors.card,
                          inactiveTrackColor: colors.divider,
                          onChanged: (v) => setState(() => _useReceiver = v),
                        ),
                        colors: colors,
                        showDivider: true,
                      ),
                      _RowItem(
                        title: '清除聊天记录',
                        trailing: Icon(Icons.chevron_right,
                            size: 26, color: colors.muted),
                        colors: colors,
                        showDivider: false,
                        onTap: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) =>
                                _ClearChatConfirmDialog(colors: colors),
                          );
                          if (ok == true) {
                            // TODO: 调用清除聊天记录接口
                            _toast('聊天记录已清除');
                          }
                        },
                      ),
                    ],
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

/// 单条设置行。
class _RowItem extends StatelessWidget {
  final String title;
  final Widget trailing;
  final ThemeColors colors;
  final bool showDivider;
  final VoidCallback? onTap;

  const _RowItem({
    required this.title,
    required this.trailing,
    required this.colors,
    required this.showDivider,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final row = Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        border: showDivider
            ? Border(bottom: BorderSide(color: colors.divider))
            : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(fontSize: 18, color: colors.text),
            ),
          ),
          trailing,
        ],
      ),
    );
    return onTap == null
        ? row
        : InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(20),
            child: row,
          );
  }
}

/// 清除聊天记录二次确认弹窗。
class _ClearChatConfirmDialog extends StatelessWidget {
  final ThemeColors colors;
  const _ClearChatConfirmDialog({required this.colors});

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: colors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '提示',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: colors.text,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                '确定要清除所有聊天记录吗？清除后无法恢复。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: colors.muted),
              ),
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: colors.bg,
                          foregroundColor: colors.text,
                          elevation: 0,
                          side: BorderSide(color: colors.divider),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(23),
                          ),
                        ),
                        child: Text(
                          '取消',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: colors.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.lime,
                          foregroundColor: Colors.black,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(23),
                          ),
                        ),
                        child: const Text(
                          '确定',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}
