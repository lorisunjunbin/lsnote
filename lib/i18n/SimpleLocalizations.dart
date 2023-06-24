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
