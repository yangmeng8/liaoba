import 'package:flutter/material.dart';

import '../shared/app_colors.dart';
import '../shared/app_theme.dart';

/// 版本更新弹框（与项目确认弹框同风格）。
///
/// 强制更新：不可关闭（barrier 不可点 + 系统返回键拦截），
/// 只有「立即更新」按钮；非强制更新另有「以后再说」按钮。
class VersionUpdateDialog extends StatelessWidget {
  const VersionUpdateDialog({
    super.key,
    required this.version,
    required this.description,
    required this.isForceUpdate,
    required this.onUpdate,
    this.onDismiss,
  });

  /// 新版本号（如 1.0.4）。
  final String version;

  /// 版本描述（多行文本，换行分隔）。
  final String description;

  /// 是否强制更新。
  final bool isForceUpdate;

  /// 「立即更新」回调。
  final VoidCallback onUpdate;

  /// 「以后再说」回调（强制更新时不显示按钮）。
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // 说明按换行分割成编号列表（空行过滤）
    final lines = description
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    return PopScope(
      // 强制更新拦截系统返回键/手势
      canPop: !isForceUpdate,
      child: Dialog(
        backgroundColor: colors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题行：发现新版本 + NEW 徽标
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '发现新版本',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: colors.text,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.lime,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'NEW',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'v$version',
                style: TextStyle(fontSize: 14, color: colors.muted),
              ),
              const SizedBox(height: 20),
              // 更新说明列表（超长可滚动，限高防溢出）
              if (lines.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < lines.length; i++)
                          Padding(
                            padding: EdgeInsets.only(
                                bottom: i < lines.length - 1 ? 8 : 0),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${i + 1}. ',
                                  style: TextStyle(
                                      fontSize: 14, color: colors.muted),
                                ),
                                Expanded(
                                  child: Text(
                                    lines[i],
                                    style: TextStyle(
                                      fontSize: 14,
                                      height: 1.5,
                                      color: colors.muted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 28),
              // 立即更新（lime 主按钮）
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton(
                  onPressed: onUpdate,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.lime,
                    foregroundColor: Colors.black,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(23),
                    ),
                  ),
                  child: const Text(
                    '立即更新',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              // 非强制更新：以后再说（描边次按钮）
              if (!isForceUpdate && onDismiss != null) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: ElevatedButton(
                    // 弹框自己负责关闭；onDismiss 仅供外部做清理/打点
                    onPressed: () {
                      Navigator.of(context).pop();
                      onDismiss?.call();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.bg,
                      foregroundColor: colors.text,
                      elevation: 0,
                      side: BorderSide(color: colors.divider),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(23),
                      ),
                    ),
                    child: const Text(
                      '以后再说',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
