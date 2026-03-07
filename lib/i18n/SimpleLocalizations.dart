import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;

class SimpleLocalizations {
  static Map<String, Map<String, String>> _localizedValues = {
    'en': {
      'title': 'LSNOTE',
      'reason': 'Authenticate before enter',
      'search': 'Search',
      'titleLabel': 'Title',
      'contentLabel': 'Content',
      'export_import': 'Export/Import',
      'confirmLabel': 'O-,-K',
      'cancelLabel': 'Cancel',
      'contentChanged': 'Content modified',
      'noticed': 'Noticed',
      'confirm': 'Pls confirm',
      'confirm2delete': 'Click YES to Delete:\n',
      'confirmYes': 'YES',
      'colorPicker': 'Theme color chooser',
      'colorPickerClose': 'Dismiss',
      'signInTitle': 'Fingerprint Authentication',
      'guess': 'GUESS',
      'win': 'Correct!',
      'take': 'Take',
      'step': 'steps',
      'in': 'in',
      'second': 's',
      'start': 'Start',
      'amazing': 'Amazing!',
      'awesome': 'Awesome!',
      'wonderful': 'Wonderful!',
      'justsoso': 'Just So so~',
      'numberpuzzles': 'Number Puzzles',
      'exportToJSON': 'Export to JSON',
      'importFromJSON': 'Import from JSON',
      'messageLabel': 'Message',
      'successImportLabel': 'successfully imported: ',
      'backupExportToFileTooltip': 'Export to File',
      'backupCompressJsonTooltip': 'Compress JSON',
      'backupFormatJsonTooltip': 'Format JSON',
      'backupValidateJsonTooltip': 'Validate JSON',
      'backupLastExportPrefix': 'Last export: ',
      'backupChooseFolderDialogTitle': 'Choose folder to save backup',
      'backupChooseLocationDialogTitle': 'Choose location to save backup',
      'backupOpenAction': 'Open',
      'backupExportCancelledNoFolder': 'Export cancelled. No folder selected.',
      'backupNoWritePermissionFallbackCancelled':
          'No write permission for selected folder, and fallback save was cancelled.',
      'backupExportedPrefix': 'Exported: ',
      'backupExportFailedPrefix': 'Export failed: ',
      'backupCannotOpenPrefix': 'Cannot open: ',
      'backupFileNotFound': 'File not found',
      'backupOpenLocationFailedPrefix': 'Failed to open location: ',
      'backupEditorEmpty': 'Editor is empty.',
      'backupInvalidJsonPrefix': 'Invalid JSON: ',
      'backupValidJsonStatusPrefix': 'Valid JSON. Items ready to import: ',
      'backupJsonValidSnackPrefix': 'JSON is valid. Items: ',
      'backupInvalidNoteJsonPrefix': 'Invalid note JSON: ',
      'backupJsonInvalidPrefix': 'JSON is invalid: ',
      'backupImportFailedPrefix': 'Import failed: ',
      'backupTopLevelArrayRequired': 'Top level JSON must be an array.',
      'backupItemNotJsonObjectPrefix': 'Item is not a JSON object. Index: ',
      'backupLastExportedPrefix': 'Last export: ',
      'backupCopyPathTooltip': 'Copy path',
      'backupPathCopied': 'Export path copied.',
      'backupNoPathToCopy': 'No export path to copy.',
    },
    'zh': {
      'title': 'LS记事本',
      'reason': '打开记事本',
      'search': '查找',
      'titleLabel': '标题',
      'contentLabel': '内容',
      'export_import': '备份',
      'confirmLabel': '确定',
      'cancelLabel': '取消',
      'contentChanged': '内容变更',
      'noticed': '知道了',
      'confirm': '请确认',
      'confirm2delete': '点击 确认 删除:\n',
      'confirmYes': '确认',
      'colorPicker': '主题颜色',
      'colorPickerClose': '关了',
      'signInTitle': '指纹身份验证',
      'guess': '猜一猜',
      'win': '猜对了',
      'take': '第',
      'step': '次',
      'in': ',',
      'second': '秒',
      'start': '开始',
      'amazing': '好幸运!',
      'awesome': '真聪明！',
      'wonderful': '漂亮~!',
      'justsoso': '一般般~',
      'numberpuzzles': '猜 数 字',
      'exportToJSON': '导出JSON',
      'importFromJSON': '导入JSON',
      'messageLabel': '信 息',
      'successImportLabel': '成功导入: ',
      'backupExportToFileTooltip': '导出到文件',
      'backupCompressJsonTooltip': '压缩 JSON',
      'backupFormatJsonTooltip': '格式化 JSON',
      'backupValidateJsonTooltip': '校验 JSON',
      'backupLastExportPrefix': '最近导出: ',
      'backupChooseFolderDialogTitle': '选择备份保存目录',
      'backupChooseLocationDialogTitle': '选择备份保存位置',
      'backupOpenAction': '打开',
      'backupExportCancelledNoFolder': '已取消导出，未选择目录。',
      'backupNoWritePermissionFallbackCancelled': '所选目录无写入权限，且已取消兜底保存。',
      'backupExportedPrefix': '导出成功: ',
      'backupExportFailedPrefix': '导出失败: ',
      'backupCannotOpenPrefix': '无法打开: ',
      'backupFileNotFound': '文件不存在',
      'backupOpenLocationFailedPrefix': '打开位置失败: ',
      'backupEditorEmpty': '编辑器为空。',
      'backupInvalidJsonPrefix': 'JSON 无效: ',
      'backupValidJsonStatusPrefix': 'JSON 有效，可导入条目数: ',
      'backupJsonValidSnackPrefix': 'JSON 校验通过，条目数: ',
      'backupInvalidNoteJsonPrefix': '笔记 JSON 无效: ',
      'backupJsonInvalidPrefix': 'JSON 校验失败: ',
      'backupImportFailedPrefix': '导入失败: ',
      'backupTopLevelArrayRequired': '最外层 JSON 必须是数组。',
      'backupItemNotJsonObjectPrefix': '条目不是 JSON 对象，索引: ',
      'backupLastExportedPrefix': '最近导出: ',
      'backupCopyPathTooltip': '复制路径',
      'backupPathCopied': '导出路径已复制。',
      'backupNoPathToCopy': '没有可复制的导出路径。',
    }
  };

  String? getText(String key) => _localizedValues[locale.languageCode]?[key];

  SimpleLocalizations(this.locale);

  final Locale locale;

  static SimpleLocalizations? of(BuildContext context) {
    return Localizations.of<SimpleLocalizations>(context, SimpleLocalizations);
  }
}

class SimpleLocalizationsDelegate
    extends LocalizationsDelegate<SimpleLocalizations> {
  const SimpleLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => ['en', 'zh'].contains(locale.languageCode);

  @override
  Future<SimpleLocalizations> load(Locale locale) {
    return SynchronousFuture<SimpleLocalizations>(SimpleLocalizations(locale));
  }

  @override
  bool shouldReload(SimpleLocalizationsDelegate old) => false;
}
