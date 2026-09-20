import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

/// pro_image_editor 汉化配置（涂鸦/文字/裁剪旋转/滤镜/调节/模糊/表情），
/// 迁移自 app_im 的 asset_picker_viewer_builder_delegate。
ProImageEditorConfigs get proImageEditorChinaI18nConfigs =>
    ProImageEditorConfigs(
      i18n: I18n(
        cancel: '取消',
        undo: '撤销',
        redo: '重做',
        done: '完成',
        remove: '删除',
        doneLoadingMsg: '正在应用更改…',
        importStateHistoryMsg: '初始化编辑器',
        various: const I18nVarious(
          loadingDialogMsg: '请稍候…',
          closeEditorWarningTitle: '关闭图片编辑器？',
          closeEditorWarningMessage: '确定要关闭吗？未保存的修改将会丢失。',
          closeEditorWarningConfirmBtn: '确定',
          closeEditorWarningCancelBtn: '取消',
        ),
        paintEditor: const I18nPaintEditor(
          bottomNavigationBarText: '涂鸦',
          moveAndZoom: '缩放',
          freestyle: '自由绘制',
          arrow: '箭头',
          line: '直线',
          rectangle: '矩形',
          circle: '圆形',
          blur: '模糊',
          pixelate: '像素化',
          lineWidth: '线宽',
          eraser: '橡皮擦',
          undo: '撤销',
          redo: '重做',
          done: '完成',
          back: '返回',
          smallScreenMoreTooltip: '更多',
          opacity: '透明度',
          color: '颜色',
          strokeWidth: '线宽',
          fill: '填充',
          cancel: '取消',
        ),
        textEditor: const I18nTextEditor(
          inputHintText: '输入文字',
          bottomNavigationBarText: '文字',
          back: '返回',
          done: '完成',
          textAlign: '对齐',
          fontScale: '字号',
          backgroundMode: '背景',
          smallScreenMoreTooltip: '更多',
        ),
        cropRotateEditor: const I18nCropRotateEditor(
          bottomNavigationBarText: '裁剪/旋转',
          rotate: '旋转',
          flip: '翻转',
          ratio: '比例',
          back: '返回',
          done: '完成',
          cancel: '取消',
          undo: '撤销',
          redo: '重做',
          smallScreenMoreTooltip: '更多',
          reset: '重置',
        ),
        filterEditor: const I18nFilterEditor(
          bottomNavigationBarText: '滤镜',
          back: '返回',
          done: '完成',
        ),
        tuneEditor: const I18nTuneEditor(
          bottomNavigationBarText: '调节',
          back: '返回',
          done: '完成',
          brightness: '亮度',
          contrast: '对比度',
          saturation: '饱和度',
          exposure: '曝光',
          hue: '色相',
          temperature: '色温',
          sharpness: '锐度',
          fade: '褪色',
          luminance: '亮度',
          undo: '撤销',
          redo: '重做',
        ),
        blurEditor: const I18nBlurEditor(
          bottomNavigationBarText: '模糊',
          back: '返回',
          done: '完成',
        ),
        emojiEditor: const I18nEmojiEditor(
          bottomNavigationBarText: '表情',
          search: '搜索',
          categoryRecent: '最近',
          categorySmileys: '笑脸与人物',
          categoryAnimals: '动物与自然',
          categoryFood: '食物与饮料',
          categoryActivities: '活动',
          categoryTravel: '旅行与地点',
          categoryObjects: '物品',
          categorySymbols: '符号',
          categoryFlags: '旗帜',
        ),
        stickerEditor: const I18nStickerEditor(
          bottomNavigationBarText: '贴纸',
        ),
        layerInteraction: const I18nLayerInteraction(
          remove: '删除',
          edit: '编辑',
          rotateScale: '旋转与缩放',
        ),
      ),
    );

/// 打开图片编辑器编辑 [filePath]：
/// 点「完成」返回编辑后字节；关闭/取消返回 null。
///
/// Completer 防重复 pop（pro_image_editor 点完成会先后回调
/// onImageEditingComplete 与 onCloseEditor，两处都 pop 会多关一层页面）。
Future<Uint8List?> pushImageEditor(BuildContext context, String filePath) {
  final completer = Completer<Uint8List?>();
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (editorContext) => ProImageEditor.file(
        filePath,
        configs: proImageEditorChinaI18nConfigs,
        callbacks: ProImageEditorCallbacks(
          onImageEditingComplete: (Uint8List bytes) async {
            if (!completer.isCompleted) completer.complete(bytes);
          },
          onCloseEditor: (EditorMode mode) {
            // 子编辑器（涂鸦/文字页）关闭：只关子页，不动主编辑器
            if (mode != EditorMode.main) {
              if (Navigator.canPop(editorContext)) {
                Navigator.of(editorContext).pop();
              }
              return;
            }
            // 主编辑器关闭：完成→已带 bytes；直接关→null
            if (!completer.isCompleted) completer.complete(null);
            Navigator.of(editorContext).pop();
          },
        ),
      ),
    ),
  );
  return completer.future;
}

/// 编辑后字节写入临时文件，返回路径。
Future<String> saveEditedImage(Uint8List bytes) async {
  final path = p.join(
    (await getTemporaryDirectory()).path,
    'edited_${DateTime.now().millisecondsSinceEpoch}.jpg',
  );
  await File(path).writeAsBytes(bytes);
  return path;
}
