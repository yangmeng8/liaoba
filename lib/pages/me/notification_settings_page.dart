import 'package:flutter/material.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';

/// 通知设置页面。
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState
    extends State<NotificationSettingsPage> {
  bool _dnd = false;
  bool _inAppSound = true;
  // 当前通知铃声展示名称（实际应读持久化存储）
  String _ringtone = '默认';

  Future<void> _pickRingtone() async {
    // TODO: 跳转到铃声选择页/系统铃声选择器，选中后回写 _ringtone
    // 示例：直接用弹窗模拟
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.colors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final colors = Theme.of(ctx).extension<ThemeColors>()!;
        final options = const ['默认', '叮咚', '风铃', '清脆', '无声'];
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  '选择通知铃声',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: colors.text),
                ),
                const SizedBox(height: 12),
                ...options.map((name) => InkWell(
                      onTap: () => Navigator.of(ctx).pop(name),
                      child: Container(
                        height: 52,
                        alignment: Alignment.centerLeft,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: name == options.last
                                  ? Colors.transparent
                                  : colors.divider,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(name,
                                  style: TextStyle(
                                      fontSize: 16, color: colors.text)),
                            ),
                            if (name == _ringtone)
                              const Icon(Icons.check,
                                  color: AppColors.lime, size: 24),
                          ],
                        ),
                      ),
                    )),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null) setState(() => _ringtone = picked);
  }

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
                      '通知设置',
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

          // 设置项卡片
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
                        title: '通知铃声',
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_ringtone,
                                style: TextStyle(
                                    fontSize: 16, color: colors.muted)),
                            const SizedBox(width: 4),
                            Icon(Icons.chevron_right,
                                size: 26, color: colors.muted),
                          ],
                        ),
                        colors: colors,
                        showDivider: true,
                        onTap: _pickRingtone,
                      ),
                      _RowItem(
                        title: '消息免打扰',
                        trailing: Switch(
                          value: _dnd,
                          activeThumbColor: colors.card,
                          activeTrackColor: AppColors.lime,
                          trackOutlineColor: const WidgetStatePropertyAll(
                              Colors.transparent),
                          inactiveThumbColor: colors.card,
                          inactiveTrackColor: colors.divider,
                          onChanged: (v) => setState(() => _dnd = v),
                        ),
                        colors: colors,
                        showDivider: true,
                      ),
                      _RowItem(
                        title: '应用内消息提示音',
                        trailing: Switch(
                          value: _inAppSound,
                          activeThumbColor: colors.card,
                          activeTrackColor: AppColors.lime,
                          trackOutlineColor: const WidgetStatePropertyAll(
                              Colors.transparent),
                          inactiveThumbColor: colors.card,
                          inactiveTrackColor: colors.divider,
                          onChanged: (v) => setState(() => _inAppSound = v),
                        ),
                        colors: colors,
                        showDivider: false,
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
