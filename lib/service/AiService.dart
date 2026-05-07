import 'dart:async';
import 'dart:io';

import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'package:path_provider/path_provider.dart';

import 'NoteAccessSqlite.dart';
import '../model/Config.dart';

enum AiServiceState { uninitialized, loading, ready, error }

class AiModelInfo {
  final String name;
  final String fileName;
  final String downloadUrl;
  final String size;
  final int minRamGB;
  final bool supportsVision;
  final bool supportsAudio;

  const AiModelInfo({
    required this.name,
    required this.fileName,
    required this.downloadUrl,
    required this.size,
    required this.minRamGB,
    this.supportsVision = false,
    this.supportsAudio = false,
  });
}

class AiService {
  static final AiService instance = AiService._();
  AiService._();

  AiServiceState _state = AiServiceState.uninitialized;
  AiServiceState get state => _state;

  String _modelPath = '';
  String get modelPath => _modelPath;

  String _backend = 'gpu';
  String get backend => _backend;

  String _language = 'zh';
  String get language => _language;

  String get languageInstruction {
    return _language == 'zh'
        ? 'You MUST respond in Chinese (简体中文).'
        : 'You MUST respond in English.';
  }

  String get contextInfo {
    final now = DateTime.now();
    return 'Current date and time: ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}. $languageInstruction';
  }

  Future<void> setLanguage(String lang) async {
    _language = lang;
    db.setConfig(Config.aiLanguage, lang);
  }

  LiteLmEngine? _engine;
  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  static const List<AiModelInfo> availableModels = [
    AiModelInfo(
      name: 'Gemma 4 E4B-it',
      fileName: 'gemma-4-E4B-it.litertlm',
      downloadUrl:
          'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm?download=true',
      size: '3.66 GB',
      minRamGB: 8,
      supportsVision: true,
      supportsAudio: true,
    ),
    AiModelInfo(
      name: 'Gemma 4 E2B-it',
      fileName: 'gemma-4-E2B-it.litertlm',
      downloadUrl:
          'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm?download=true',
      size: '2.59 GB',
      minRamGB: 5,
      supportsVision: true,
      supportsAudio: true,
    ),
    AiModelInfo(
      name: 'Qwen3 4B',
      fileName: 'qwen3_4b_channelwise_int8_float32kv.litertlm',
      downloadUrl:
          'https://huggingface.co/litert-community/Qwen3-4B/resolve/main/qwen3_4b_channelwise_int8_float32kv.litertlm?download=true',
      size: '5.67 GB',
      minRamGB: 12,
    ),
    AiModelInfo(
      name: 'Qwen3 0.6B',
      fileName: 'Qwen3-0.6B.litertlm',
      downloadUrl:
          'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm?download=true',
      size: '586 MB',
      minRamGB: 3,
    ),
  ];

  bool get isReady => _state == AiServiceState.ready;

  bool get isVisionModel {
    if (!isReady || _modelPath.isEmpty) return false;
    return _isCurrentModelVision();
  }

  bool get isAudioModel {
    if (!isReady || _modelPath.isEmpty) return false;
    return _isCurrentModelAudio();
  }

  bool _isCurrentModelVision() {
    if (_modelPath.isEmpty) return false;
    for (final model in availableModels) {
      if (_modelPath.endsWith(model.fileName)) return model.supportsVision;
    }
    return false;
  }

  bool _isCurrentModelAudio() {
    if (_modelPath.isEmpty) return false;
    for (final model in availableModels) {
      if (_modelPath.endsWith(model.fileName)) return model.supportsAudio;
    }
    return false;
  }

  Future<String> get _modelDir async {
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  Future<String?> get localModelPath async {
    if (_modelPath.isNotEmpty) {
      final file = File(_modelPath);
      if (await file.exists()) return file.path;
    }
    return null;
  }

  Future<int> get modelFileSize async {
    if (_modelPath.isEmpty) return 0;
    final file = File(_modelPath);
    if (await file.exists()) return await file.length();
    return 0;
  }

  Future<void> deleteModel() async {
    await _engine?.dispose();
    _engine = null;
    _state = AiServiceState.uninitialized;

    if (_modelPath.isNotEmpty) {
      final file = File(_modelPath);
      if (await file.exists()) await file.delete();
    }
    _modelPath = '';
    _errorMessage = null;
    db.setConfig(Config.aiModelPath, '');
  }

  Stream<double> downloadModel(AiModelInfo model) async* {
    final dir = await _modelDir;
    final filePath = '$dir/${model.fileName}';
    final tempPath = '$filePath.tmp';

    final tempFile = File(tempPath);
    int existingBytes = 0;
    if (await tempFile.exists()) {
      existingBytes = await tempFile.length();
    }

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(model.downloadUrl));
      if (existingBytes > 0) {
        request.headers.set('Range', 'bytes=$existingBytes-');
      }
      final response = await request.close();

      if (response.statusCode != 200 &&
          response.statusCode != 206 &&
          response.statusCode != 302) {
        throw AiServiceException('Download failed: ${response.statusCode}');
      }

      // If server doesn't support Range, start over
      if (existingBytes > 0 && response.statusCode == 200) {
        existingBytes = 0;
      }

      final contentLength = response.contentLength;
      final totalBytes =
          contentLength > 0 ? contentLength + existingBytes : -1;
      int receivedBytes = existingBytes;

      final sink = tempFile.openWrite(
        mode: existingBytes > 0 ? FileMode.append : FileMode.write,
      );

      await for (final chunk in response) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          yield receivedBytes / totalBytes;
        }
      }

      await sink.flush();
      await sink.close();

      await tempFile.rename(filePath);

      _modelPath = filePath;
      db.setConfig(Config.aiModelPath, filePath);

      yield 1.0;
    } finally {
      client.close();
    }
  }

  Future<void> loadConfig() async {
    try {
      final cfgPath = await db.getConfig(Config.aiModelPath);
      if (cfgPath.value != null && cfgPath.value!.isNotEmpty) {
        _modelPath = cfgPath.value!;
      }
      final cfgBackend = await db.getConfig(Config.aiBackend);
      if (cfgBackend.value != null && cfgBackend.value!.isNotEmpty) {
        _backend = cfgBackend.value!;
      }
      final cfgLang = await db.getConfig(Config.aiLanguage);
      if (cfgLang.value != null && cfgLang.value!.isNotEmpty) {
        _language = cfgLang.value!;
      }
    } catch (_) {}
  }

  Future<bool> initialize({String? modelPath, String? backend}) async {
    if (modelPath != null) {
      _modelPath = modelPath;
      db.setConfig(Config.aiModelPath, modelPath);
    }
    if (backend != null) {
      _backend = backend;
      db.setConfig(Config.aiBackend, backend);
    }

    if (_modelPath.isEmpty) {
      _state = AiServiceState.uninitialized;
      return false;
    }

    _state = AiServiceState.loading;
    _errorMessage = null;

    try {
      await _engine?.dispose();
      _engine = await LiteLmEngine.create(
        LiteLmEngineConfig(
          modelPath: _modelPath,
          backend: _backend == 'gpu' ? LiteLmBackend.gpu : LiteLmBackend.cpu,
        ),
      );
      _state = AiServiceState.ready;
      return true;
    } catch (e) {
      if (_backend == 'gpu') {
        try {
          _engine = await LiteLmEngine.create(
            LiteLmEngineConfig(
              modelPath: _modelPath,
              backend: LiteLmBackend.cpu,
            ),
          );
          _backend = 'cpu';
          db.setConfig(Config.aiBackend, 'cpu');
          _state = AiServiceState.ready;
          return true;
        } catch (fallbackError) {
          _errorMessage = fallbackError.toString();
          _state = AiServiceState.error;
          return false;
        }
      }
      _errorMessage = e.toString();
      _state = AiServiceState.error;
      return false;
    }
  }

  Stream<String> completeStream(String systemPrompt, String userMessage) async* {
    if (_engine == null || _state != AiServiceState.ready) {
      throw AiServiceException('AI engine not ready');
    }

    final conversation = await _engine!.createConversation(
      LiteLmConversationConfig(
        systemInstruction: systemPrompt,
        samplerConfig: const LiteLmSamplerConfig(
          temperature: 0.7,
          topK: 40,
          topP: 0.95,
        ),
      ),
    );

    try {
      await for (final delta in conversation.sendMessageStream(userMessage)) {
        yield delta.text;
      }
    } finally {
      await conversation.dispose();
    }
  }

  Future<String> completeMultimodal(
      String systemPrompt, String imagePath, String? userText) async {
    if (_state != AiServiceState.ready || _modelPath.isEmpty) {
      throw AiServiceException('AI engine not ready');
    }
    if (!_isCurrentModelVision()) {
      throw AiServiceException('Current model does not support vision');
    }
    final file = File(imagePath);
    if (!await file.exists()) {
      throw AiServiceException('Image file not found');
    }
    final bytes = await file.readAsBytes();

    final visionEngine = await LiteLmEngine.create(
      LiteLmEngineConfig(
        modelPath: _modelPath,
        backend: _backend == 'gpu' ? LiteLmBackend.gpu : LiteLmBackend.cpu,
        visionBackend: LiteLmBackend.cpu,
        maxNumImages: 1,
      ),
    );
    try {
      final conversation = await visionEngine.createConversation(
        LiteLmConversationConfig(
          systemInstruction: systemPrompt,
          samplerConfig: const LiteLmSamplerConfig(
            temperature: 0.7,
            topK: 40,
            topP: 0.95,
          ),
        ),
      );
      try {
        final contents = <LiteLmContent>[
          LiteLmContent.imageBytes(bytes),
          if (userText != null && userText.isNotEmpty)
            LiteLmContent.text(userText),
        ];
        final response = await conversation.sendMultimodalMessage(contents);
        return response.text;
      } finally {
        await conversation.dispose();
      }
    } finally {
      await visionEngine.dispose();
    }
  }

  Future<String> completeAudio(
      String systemPrompt, String audioPath, String? userText) async {
    if (_state != AiServiceState.ready || _modelPath.isEmpty) {
      throw AiServiceException('AI engine not ready');
    }
    if (!_isCurrentModelAudio()) {
      throw AiServiceException('Current model does not support audio');
    }
    final file = File(audioPath);
    if (!await file.exists()) {
      throw AiServiceException('Audio file not found');
    }
    final bytes = await file.readAsBytes();

    final audioEngine = await LiteLmEngine.create(
      LiteLmEngineConfig(
        modelPath: _modelPath,
        backend: _backend == 'gpu' ? LiteLmBackend.gpu : LiteLmBackend.cpu,
        audioBackend: LiteLmBackend.cpu,
      ),
    );
    try {
      final conversation = await audioEngine.createConversation(
        LiteLmConversationConfig(
          systemInstruction: systemPrompt,
          samplerConfig: const LiteLmSamplerConfig(
            temperature: 0.7,
            topK: 40,
            topP: 0.95,
          ),
        ),
      );
      try {
        final contents = <LiteLmContent>[
          LiteLmContent.audioBytes(bytes),
          if (userText != null && userText.isNotEmpty)
            LiteLmContent.text(userText),
        ];
        final response = await conversation.sendMultimodalMessage(contents);
        return response.text;
      } finally {
        await conversation.dispose();
      }
    } finally {
      await audioEngine.dispose();
    }
  }

  Future<LiteLmConversation> createChatConversation(
      {String? systemInstruction}) async {
    if (_engine == null || _state != AiServiceState.ready) {
      throw AiServiceException('AI engine not ready');
    }

    return await _engine!.createConversation(
      LiteLmConversationConfig(
        systemInstruction: systemInstruction ?? 'You are a helpful assistant.',
        samplerConfig: const LiteLmSamplerConfig(
          temperature: 0.7,
          topK: 40,
          topP: 0.95,
        ),
      ),
    );
  }

  static Future<double?> getDeviceRamGB() async {
    try {
      if (Platform.isAndroid) {
        final meminfo = await File('/proc/meminfo').readAsString();
        final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(meminfo);
        if (match != null) {
          return int.parse(match.group(1)!) / (1024 * 1024);
        }
      } else if (Platform.isMacOS) {
        final result = await Process.run('sysctl', ['-n', 'hw.memsize']);
        if (result.exitCode == 0) {
          final bytes = int.tryParse(result.stdout.toString().trim());
          if (bytes != null) return bytes / (1024 * 1024 * 1024);
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<AiModelInfo?> getRecommendedModel() async {
    final ramGB = await getDeviceRamGB();
    if (ramGB == null) return null;
    if (ramGB >= 8) return availableModels[0];
    if (ramGB >= 5) return availableModels[1];
    return availableModels[3];
  }

  Future<bool> isModelDownloaded(AiModelInfo model) async {
    final dir = await _modelDir;
    final file = File('$dir/${model.fileName}');
    return file.exists();
  }

  Future<List<AiModelInfo>> getDownloadedModels() async {
    final results = <AiModelInfo>[];
    for (final model in availableModels) {
      if (await isModelDownloaded(model)) results.add(model);
    }
    return results;
  }

  Future<void> deleteModelFile(AiModelInfo model) async {
    final dir = await _modelDir;
    final file = File('$dir/${model.fileName}');
    if (await file.exists()) await file.delete();
    if (_modelPath.endsWith(model.fileName)) {
      await _engine?.dispose();
      _engine = null;
      _state = AiServiceState.uninitialized;
      _modelPath = '';
      db.setConfig(Config.aiModelPath, '');
    }
  }

  Future<bool> activateModel(AiModelInfo model) async {
    final dir = await _modelDir;
    final filePath = '$dir/${model.fileName}';
    final file = File(filePath);
    if (!await file.exists()) return false;
    await _engine?.dispose();
    _engine = null;
    _modelPath = filePath;
    db.setConfig(Config.aiModelPath, filePath);
    return await initialize();
  }

  Stream<double> switchModel(AiModelInfo newModel) async* {
    if (await isModelDownloaded(newModel)) {
      await activateModel(newModel);
      yield 1.0;
      return;
    }
    await _engine?.dispose();
    _engine = null;
    _state = AiServiceState.uninitialized;
    yield* downloadModel(newModel);
  }

  Future<void> dispose() async {
    await _engine?.dispose();
    _engine = null;
    _state = AiServiceState.uninitialized;
  }
}

class AiServiceException implements Exception {
  final String message;
  AiServiceException(this.message);

  @override
  String toString() => message;
}
