import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'NoteAccessSqlite.dart';
import '../model/Config.dart';

class AiService {
  static final AiService instance = AiService._();
  AiService._();

  String _host = '127.0.0.1';
  int _port = 8888;
  final String _basePath = '/v1';

  String get host => _host;
  int get port => _port;
  String get basePath => _basePath;
  String get baseUrl => 'http://$_host:$_port$_basePath';

  Future<void> loadConfig() async {
    try {
      final hostCfg = await db.getConfig(Config.aiHost);
      if (hostCfg.value != null && hostCfg.value!.isNotEmpty) {
        _host = hostCfg.value!;
      }
    } catch (_) {}
    try {
      final portCfg = await db.getConfig(Config.aiPort);
      if (portCfg.value != null && portCfg.value!.isNotEmpty) {
        _port = int.tryParse(portCfg.value!) ?? 8888;
      }
    } catch (_) {}
  }

  void updateConfig(String host, int port) {
    _host = host;
    _port = port;
    db.setConfig(Config.aiHost, host);
    db.setConfig(Config.aiPort, port.toString());
  }

  Future<bool> checkHealth() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/models'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<String> complete(List<Map<String, String>> messages) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl/chat/completions'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'messages': messages,
            'stream': false,
          }),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw AiServiceException('AI service error: ${response.statusCode}');
    }

    final json = jsonDecode(response.body);
    return json['choices'][0]['message']['content'] as String;
  }

  Stream<String> completeStream(List<Map<String, String>> messages) async* {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);

    try {
      final request =
          await client.postUrl(Uri.parse('$baseUrl/chat/completions'));
      request.headers.set('Content-Type', 'application/json');
      request.write(jsonEncode({
        'messages': messages,
        'stream': true,
      }));

      final response = await request.close();

      if (response.statusCode != 200) {
        throw AiServiceException('AI service error: ${response.statusCode}');
      }

      String buffer = '';
      await for (final chunk in response.transform(utf8.decoder)) {
        buffer += chunk;
        final lines = buffer.split('\n');
        buffer = lines.removeLast();

        for (final line in lines) {
          if (line.startsWith('data: ')) {
            final data = line.substring(6).trim();
            if (data == '[DONE]') return;
            try {
              final json = jsonDecode(data);
              final content =
                  json['choices']?[0]?['delta']?['content'] as String?;
              if (content != null && content.isNotEmpty) {
                yield content;
              }
            } catch (_) {}
          }
        }
      }

      if (buffer.isNotEmpty && buffer.startsWith('data: ')) {
        final data = buffer.substring(6).trim();
        if (data != '[DONE]') {
          try {
            final json = jsonDecode(data);
            final content =
                json['choices']?[0]?['delta']?['content'] as String?;
            if (content != null && content.isNotEmpty) {
              yield content;
            }
          } catch (_) {}
        }
      }
    } finally {
      client.close();
    }
  }
}

class AiServiceException implements Exception {
  final String message;
  AiServiceException(this.message);

  @override
  String toString() => message;
}
