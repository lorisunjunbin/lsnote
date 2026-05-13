import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_litert_lm/flutter_litert_lm.dart';

import '../model/Config.dart';
import '../model/McpServer.dart';
import '../model/McpTool.dart';
import 'NoteAccessSqlite.dart';

class McpService {
  static final McpService instance = McpService._();
  McpService._();

  List<McpServer> _servers = [];
  bool _isReady = false;
  String _contextCache = '';
  List<McpTool> _mcpTools = [];
  Map<String, McpServer> _toolServerMap = {};
  int _requestId = 0;
  void Function()? onContextReady;

  bool get isEnabled => _servers.any((s) => s.enabled && s.url.isNotEmpty);
  bool get isReady => _isReady;
  String get contextCache => _contextCache;
  List<McpServer> get servers => _servers;

  void setContextCache(String value) {
    _contextCache = value;
    onContextReady?.call();
  }

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
      final cfg = await db.getConfig(Config.mcpServers);
      if (cfg.value != null && cfg.value!.isNotEmpty) {
        final list = jsonDecode(cfg.value!) as List<dynamic>;
        _servers = list
            .whereType<Map<String, dynamic>>()
            .map((j) => McpServer.fromJson(j))
            .toList();
      } else {
        await _migrateOldConfig();
      }
    } catch (_) {
      await _migrateOldConfig();
    }
  }

  Future<void> _migrateOldConfig() async {
    try {
      final enabledCfg = await db.getConfig(Config.mcpEnabled);
      final urlCfg = await db.getConfig(Config.mcpServerUrl);
      final authCfg = await db.getConfig(Config.mcpAuthHeader);
      final url = urlCfg.value ?? '';
      if (url.isNotEmpty) {
        _servers = [
          McpServer(
            name: 'Default',
            url: url,
            token: authCfg.value ?? '',
            enabled: enabledCfg.value == '1',
          ),
        ];
        await saveServers();
      }
    } catch (_) {}
  }

  Future<void> saveServers() async {
    final json = jsonEncode(_servers.map((s) => s.toJson()).toList());
    await db.ensureConfig(Config.mcpServers, '[]');
    db.setConfig(Config.mcpServers, json);
  }

  Future<void> addServer(McpServer server) async {
    _servers.add(server);
    await saveServers();
  }

  Future<void> removeServer(int index) async {
    if (index >= 0 && index < _servers.length) {
      _servers.removeAt(index);
      await saveServers();
    }
  }

  Future<void> updateServer(int index, McpServer server) async {
    if (index >= 0 && index < _servers.length) {
      _servers[index] = server;
      await saveServers();
    }
  }

  Future<void> toggleServer(int index, bool enabled) async {
    if (index >= 0 && index < _servers.length) {
      _servers[index].enabled = enabled;
      await saveServers();
    }
  }

  static const List<String> _contextToolKeywords = [
    'weather', '天气',
    'holiday', 'almanac', 'huangli', '节日', '黄历', '农历',
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
    _toolServerMap = {};

    final enabledServers = _servers.where((s) => s.enabled && s.url.isNotEmpty);

    // Fetch tool lists from all servers in parallel
    await Future.wait(enabledServers.map((server) async {
      try {
        final toolsBody = jsonEncode({
          'jsonrpc': '2.0',
          'id': ++_requestId,
          'method': 'tools/list',
          'params': {},
        });
        final toolsJson = await _postWithFallback(server, toolsBody);
        final toolsResult = toolsJson['result'] as Map<String, dynamic>? ?? toolsJson;
        final toolsList = toolsResult['tools'] as List<dynamic>? ?? [];
        final serverTools = toolsList
            .whereType<Map<String, dynamic>>()
            .map((j) => McpTool.fromJson(j))
            .toList();
        _mcpTools.addAll(serverTools);
        for (final tool in serverTools) {
          _toolServerMap[tool.name] = server;
        }
      } catch (_) {}
    }));

    // Call context tools in parallel
    final contextTools = _mcpTools.where((t) => _isContextTool(t.name)).toList();
    final results = await Future.wait(contextTools.map((tool) async {
      try {
        final args = _buildDefaultArgs(tool);
        final result = await callTool(tool.name, args);
        if (result.isNotEmpty && !_isErrorResult(result)) {
          return '${tool.name}: $result';
        }
      } catch (_) {}
      return '';
    }));

    final raw = results.where((r) => r.isNotEmpty).join('\n').trim();
    _contextCache = _simplifyRawContext(raw);
    _isReady = _mcpTools.isNotEmpty;
  }

  bool _isErrorResult(String result) {
    final lower = result.toLowerCase();
    return lower.contains('error') ||
        lower.contains('invalid') ||
        lower.contains('failed') ||
        lower.contains('exception') ||
        lower.contains('格式不对') ||
        lower.contains('格式错误');
  }

  String _simplifyRawContext(String raw) {
    if (raw.isEmpty) return '';
    final lines = raw.split('\n');
    final buffer = StringBuffer();
    for (final line in lines) {
      final colonIdx = line.indexOf(': ');
      if (colonIdx < 0) {
        buffer.writeln(line);
        continue;
      }
      final label = line.substring(0, colonIdx);
      final value = line.substring(colonIdx + 2);
      // Try to parse JSON and flatten key values
      try {
        final json = jsonDecode(value);
        if (json is Map<String, dynamic>) {
          buffer.writeln('[$label]');
          json.forEach((k, v) {
            if (v != null && v.toString().isNotEmpty) {
              buffer.writeln('  $k: $v');
            }
          });
        } else {
          buffer.writeln('$label: $value');
        }
      } catch (_) {
        buffer.writeln('$label: $value');
      }
    }
    return buffer.toString().trim();
  }

  Map<String, dynamic> _buildDefaultArgs(McpTool tool) {
    final props = tool.inputSchema['properties'] as Map<String, dynamic>? ?? {};
    final required = tool.inputSchema['required'] as List<dynamic>? ?? [];
    final args = <String, dynamic>{};
    final today = DateTime.now().toIso8601String().substring(0, 10);
    for (final key in required) {
      if (props.containsKey(key)) {
        final prop = props[key] as Map<String, dynamic>;
        final type = prop['type'] as String? ?? 'string';
        if (type == 'string') {
          final k = (key as String).toLowerCase();
          if (k.contains('date')) {
            args[key] = today;
          } else {
            args[key] = '';
          }
        }
        if (type == 'number' || type == 'integer') args[key as String] = 0;
      }
    }
    return args;
  }

  String? getServerNameForTool(String toolName) => _toolServerMap[toolName]?.name;

  Future<String> callTool(String name, Map<String, dynamic> args) async {
    final server = _toolServerMap[name];
    if (server == null) throw Exception('No server found for tool: $name');
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': ++_requestId,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': args},
    });
    final result = await _postWithFallback(server, body);
    final content = result['result']?['content'] as List<dynamic>? ?? [];
    return content
        .whereType<Map<String, dynamic>>()
        .where((p) => p['type'] == 'text')
        .map((p) => p['text'] as String? ?? '')
        .join('\n');
  }

  Future<Map<String, dynamic>> _postWithFallback(
      McpServer server, String body) async {
    try {
      return await _post(server.url, server.token, body);
    } catch (e) {
      if (server.fallbackUrl.isNotEmpty) {
        return await _post(server.fallbackUrl, server.token, body);
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _post(String url, String token, String body) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse(url));
      request.headers.set('Content-Type', 'application/json; charset=utf-8');
      if (token.isNotEmpty) {
        request.headers.set('Authorization', 'Bearer $token');
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
