import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_theme.dart';

/// 预置时长选项（从上到下；0=关）。
const List<(String, int)> _burnPresets = [
  ('关', 0),
  ('4个星期', 2419200),
  ('1个星期', 604800),
  ('1天', 86400),
  ('8小时', 28800),
  ('1小时', 3600),
  ('5分钟', 300),
  ('30秒', 30),
];

/// 自定义单位（秒数；左侧数字范围：秒/分钟 1-59、小时 1-23、天 1-6、周 1-4）。
const List<int> _burnUnitSeconds = [1, 60, 3600, 86400, 604800];
const List<String> _burnUnitLabels = ['秒', '分钟', '小时', '天', '周'];

bool _isPresetDuration(int d) => _burnPresets.any((p) => p.$2 == d);

/// 单位对应的数字上限：秒/分钟 1-59、小时 1-23、天 1-6、周 1-4。
int _maxNumberOfUnit(int unitIdx) => switch (unitIdx) {
      2 => 23, // 小时
      3 => 6, // 天
      4 => 4, // 周
      _ => 59,
    };

/// 阅后即焚选择弹框（用户资料页/群设置页共用）：
/// 一级（关 / 预置时长 / 自定义时间→）→ 二级自定义（左数字右单位双列）。
/// [currentDuration] 当前时长秒（0=关，勾选回显用）；
/// [onSet] 选中后的应用回调（接口调用与提示由调用方处理）。
Future<void> showBurnPickerSheet(
  BuildContext context, {
  required int currentDuration,
  required Future<void> Function(int duration) onSet,
}) async {
  final colors = context.colors;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: colors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 14, bottom: 6),
              child: Text('阅后即焚',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            for (final (label, d) in _burnPresets)
              _BurnOptionRow(
                colors: colors,
                label: label,
                value: d,
                isCustom: false,
                selected: currentDuration == d,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  onSet(d);
                },
              ),
            _BurnOptionRow(
              colors: colors,
              label: '自定义时间',
              value: currentDuration,
              isCustom: true,
              selected: currentDuration > 0 &&
                  !_isPresetDuration(currentDuration),
              onTap: () {
                Navigator.pop(sheetCtx);
                _showCustomBurnSheet(context,
                    currentDuration: currentDuration, onSet: onSet);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

/// 选项行（选中打绿勾；自定义带右箭头跳二级选择）。
class _BurnOptionRow extends StatelessWidget {
  final ThemeColors colors;
  final String label;
  final int value;
  final bool isCustom;
  final bool selected;
  final VoidCallback onTap;

  const _BurnOptionRow({
    required this.colors,
    required this.label,
    required this.value,
    required this.isCustom,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            const SizedBox(width: 20),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 16, color: colors.text)),
            ),
            if (isCustom)
              Icon(Icons.chevron_right, size: 20, color: colors.muted),
            if (selected) ...[
              const SizedBox(width: 4),
              const Icon(Icons.check, size: 20, color: Color(0xFF07C160)),
            ],
            const SizedBox(width: 20),
          ],
        ),
      ),
    );
  }
}

/// 二级弹框：自定义时间（左数字 1-59 / 右单位；小时 1-23、天 1-6、周 1-4，单位默认秒）。
Future<void> _showCustomBurnSheet(
  BuildContext context, {
  required int currentDuration,
  required Future<void> Function(int duration) onSet,
}) async {
  // 回显当前自定义值（可整除且在范围内才回显，否则默认 秒/1）
  var unitIdx = 0;
  var numIdx = 0;
  if (currentDuration > 0) {
    for (var i = 0; i < _burnUnitSeconds.length; i++) {
      final u = _burnUnitSeconds[i];
      if (currentDuration % u == 0) {
        final n = currentDuration ~/ u;
        if (n >= 1 && n <= _maxNumberOfUnit(i)) {
          unitIdx = i;
          numIdx = n - 1;
          break;
        }
      }
    }
  }
  final numCtrl = FixedExtentScrollController(initialItem: numIdx);
  final unitCtrl = FixedExtentScrollController(initialItem: unitIdx);
  final colors = context.colors;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: colors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 14, bottom: 6),
              child: Text('自定义时间',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            SizedBox(
              height: 200,
              child: Row(
                children: [
                  // 左：数字（秒/分钟 1-59、小时 1-23、天 1-6、周 1-4 随单位联动）
                  Expanded(
                    child: CupertinoPicker(
                      scrollController: numCtrl,
                      itemExtent: 40,
                      onSelectedItemChanged: (_) {},
                      children: [
                        for (var i = 1; i <= _maxNumberOfUnit(unitIdx); i++)
                          Center(
                            child: Text('$i',
                                style: TextStyle(
                                    fontSize: 20, color: colors.text)),
                          ),
                      ],
                    ),
                  ),
                  // 右：单位（默认秒）
                  Expanded(
                    child: CupertinoPicker(
                      scrollController: unitCtrl,
                      itemExtent: 40,
                      onSelectedItemChanged: (i) {
                        // 切单位：数字范围变化并重置到 1
                        numCtrl.jumpToItem(0);
                        setSheet(() => unitIdx = i);
                      },
                      children: [
                        for (final l in _burnUnitLabels)
                          Center(
                            child: Text(l,
                                style: TextStyle(
                                    fontSize: 20, color: colors.text)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
              child: SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.lime,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () {
                    Navigator.pop(sheetCtx);
                    onSet((numCtrl.selectedItem + 1) *
                        _burnUnitSeconds[unitIdx]);
                  },
                  child: const Text('确定', style: TextStyle(fontSize: 16)),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  numCtrl.dispose();
  unitCtrl.dispose();
}
