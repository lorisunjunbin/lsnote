import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_litert_lm/flutter_litert_lm.dart';

import '../model/Config.dart';
import '../model/McpTool.dart';
import 'NoteAccessSqlite.dart';

class McpService {
  static final McpService instance = McpService._();
  McpService._();

  String _serverUrl = '';
  String _authHeader = '';
  bool _enabled = false;
  bool _isReady = false;
  String _contextCache = '';
  List<McpTool> _mcpTools = [];
  int _requestId = 0;

  bool get isEnabled => _enabled && _serverUrl.isNotEmpty;
  bool get isReady => _isReady;
  String get contextCache => _contextCache;
  String get serverUrl => _serverUrl;
  String get authHeader => _authHeader;
  bool get enabled => _enabled;

  List<LiteLmTool> get tools {
    if (!isEnabled) return [];
    return _mcpTools.map((t) => LiteLmTool(
      name: t.name,
      description: t.description,
      parameters: t.inputSchema,
    )).toList();
  }

  Future<void> init() async {
    try {
      final enabledCfg = await db.getConfig(Config.mcpEnabled);
      final urlCfg = await db.getConfig(Config.mcpServerUrl);
      final authCfg = await db.getConfig(Config.mcpAuthHeader);
      _enabled = enabledCfg.value == '1';
      _serverUrl = urlCfg.value ?? '';
      _authHeader = authCfg.value ?? '';
    } catch (_) {}
  }

  Future<void> saveConfig({String? url, String? token, bool? enabled}) async {
    if (url != null) {
      _serverUrl = url;
      db.setConfig(Config.mcpServerUrl, url);
    }
    if (token != null) {
      _authHeader = token;
      db.setConfig(Config.mcpAuthHeader, token);
    }
    if (enabled != null) {
      _enabled = enabled;
      db.setConfig(Config.mcpEnabled, enabled ? '1' : '0');
    }
  }

  static const List<String> _contextToolKeywords = [
    'weather', 'holiday', 'time', 'date', 'calendar',
    '天气', '节日', '时间', '日历',
  ];

  bool _isContextTool(String name) {
    final lower = name.toLowerCase();
    return _contextToolKeywords.any((kw) => lower.contains(kw));
  }

  Future<void> fetchContextOnModelReady() async {
    if (!isEnabled) return;
    _isReady = false;
    _contextCache = '';
    _mcpTools = [];

    try {
      final toolsBody = jsonEncode({
        'jsonrpc': '2.0',
        'id': ++_requestId,
        'method': 'tools/list',
        'params': {},
      });
      final toolsJson = await _post(_serverUrl, toolsBody);
      final toolsResult = toolsJson['result'] as Map<String, dynamic>? ?? toolsJson;
      final toolsList = toolsResult['tools'] as List<dynamic>? ?? [];
      _mcpTools = toolsList
          .whereType<Map<String, dynamic>>()
          .map((j) => McpTool.fromJson(j))
          .toList();

      final contextBuffer = StringBuffer();
      for (final tool in _mcpTools) {
        if (!_isContextTool(tool.name)) continue;
        try {
          final args = _buildDefaultArgs(tool);
          final result = await callTool(tool.name, args);
          if (result.isNotEmpty) {
            contextBuffer.writeln('${tool.name}: $result');
          }
        } catch (_) {}
      }
      _contextCache = contextBuffer.toString().trim();
      _isReady = true;
    } catch (_) {}
  }

  Map<String, dynamic> _buildDefaultArgs(McpTool tool) {
    final props = tool.inputSchema['properties'] as Map<String, dynamic>? ?? {};
    final required = tool.inputSchema['required'] as List<dynamic>? ?? [];
    final args = <String, dynamic>{};
    for (final key in required) {
      if (props.containsKey(key)) {
        final prop = props[key] as Map<String, dynamic>;
        final type = prop['type'] as String? ?? 'string';
        if (type == 'string') args[key as String] = '';
        if (type == 'number' || type == 'integer') args[key as String] = 0;
      }
    }
    return args;
  }

  Future<String> callTool(String name, Map<String, dynamic> args) async {
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': ++_requestId,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': args},
    });
    final result = await _post(_serverUrl, body);
    final content = result['result']?['content'] as List<dynamic>? ?? [];
    return content
        .whereType<Map<String, dynamic>>()
        .where((p) => p['type'] == 'text')
        .map((p) => p['text'] as String? ?? '')
        .join('\n');
  }

  Future<Map<String, dynamic>> _post(String url, String body) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse(url));
      request.headers.set('Content-Type', 'application/json; charset=utf-8');
      if (_authHeader.isNotEmpty) {
        request.headers.set('Authorization', 'Bearer $_authHeader');
      }
      final bodyBytes = utf8.encode(body);
      request.headers.set('Content-Length', bodyBytes.length.toString());
      request.add(bodyBytes);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      final responseBody = await response.transform(utf8.decoder).join()
          .timeout(const Duration(seconds: 10));
      return jsonDecode(responseBody) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }
}
