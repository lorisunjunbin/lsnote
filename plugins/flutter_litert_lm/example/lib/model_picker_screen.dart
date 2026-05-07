import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';

import 'chat_screen.dart';
import 'model_manager.dart';
import 'models.dart';

/// Landing screen of the example app: lists curated models, lets the user
/// download whichever they want, and pushes the chat screen once a model
/// is ready to load.
class ModelPickerScreen extends StatefulWidget {
  const ModelPickerScreen({super.key});

  @override
  State<ModelPickerScreen> createState() => _ModelPickerScreenState();
}

class _ModelPickerScreenState extends State<ModelPickerScreen> {
  final _manager = ModelManager();

  /// Per-model state — null if not currently downloading.
  final Map<String, _DownloadState> _downloads = {};

  /// Set of model ids known to be present on disk.
  final Set<String> _downloaded = {};

  /// Inference backend used when launching the chat screen. Defaults to CPU
  /// because the Android emulator has no OpenCL — GPU only works on real
  /// devices, and NPU only on supported chipsets. On iOS the picker is
  /// locked to CPU (no Metal accelerator is available).
  LiteLmBackend _backend = LiteLmBackend.cpu;

  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _refreshDownloaded();
  }

  @override
  void dispose() {
    for (final state in _downloads.values) {
      state.subscription.cancel();
    }
    super.dispose();
  }

  Future<void> _refreshDownloaded() async {
    final present = <String>{};
    for (final m in availableModels) {
      if (await _manager.isDownloaded(m)) {
        present.add(m.id);
      }
    }
    if (!mounted) return;
    setState(() {
      _downloaded
        ..clear()
        ..addAll(present);
      _initialized = true;
    });
  }

  Future<void> _startDownload(ModelInfo model) async {
    String? token;
    if (model.gated) {
      token = await _promptForToken(model);
      if (token == null) return; // user cancelled
    }

    final completer = Completer<void>();
    late StreamSubscription<DownloadProgress> sub;
    sub = _manager.download(model, token: token).listen(
      (progress) {
        if (!mounted) return;
        setState(() {
          _downloads[model.id] = _DownloadState(
            subscription: sub,
            received: progress.received,
            total: progress.total,
          );
        });
      },
      onError: (Object err) {
        if (!mounted) return;
        setState(() => _downloads.remove(model.id));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $err')),
        );
        completer.complete();
      },
      onDone: () async {
        if (!mounted) return;
        setState(() => _downloads.remove(model.id));
        await _refreshDownloaded();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${model.name} downloaded')),
        );
        completer.complete();
      },
    );

    setState(() {
      _downloads[model.id] = _DownloadState(
        subscription: sub,
        received: 0,
        total: model.sizeBytes,
      );
    });

    await completer.future;
  }

  void _cancelDownload(ModelInfo model) {
    final state = _downloads[model.id];
    if (state == null) return;
    state.subscription.cancel();
    setState(() => _downloads.remove(model.id));
  }

  Future<void> _deleteModel(ModelInfo model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete model?'),
        content: Text(
          'This will remove ${model.name} (${model.sizeLabel}) from device storage. '
          'You can re-download it later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _manager.delete(model);
    await _refreshDownloaded();
  }

  Future<void> _useModel(ModelInfo model) async {
    final path = await _manager.pathFor(model);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          model: model,
          modelPath: path,
          backend: _backend,
        ),
      ),
    );
  }

  Future<String?> _promptForToken(ModelInfo model) async {
    final controller = TextEditingController();
    final token = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('HuggingFace token required'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${model.name} is gated under the Gemma license. '
              'Accept the terms on the model page and paste a HuggingFace '
              'access token (read-only is enough).',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'hf_...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    controller.dispose();
    return (token == null || token.isEmpty) ? null : token;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter Lite LM'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(20),
          child: Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              'Pick a model to download and run on-device',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
      ),
      body: !_initialized
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _BackendSelector(
                  selected: _backend,
                  onChanged: (b) => setState(() => _backend = b),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: availableModels.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final model = availableModels[index];
                      return _ModelCard(
                        model: model,
                        isDownloaded: _downloaded.contains(model.id),
                        download: _downloads[model.id],
                        onDownload: () => _startDownload(model),
                        onCancel: () => _cancelDownload(model),
                        onDelete: () => _deleteModel(model),
                        onUse: () => _useModel(model),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

/// Compact segmented control for picking the inference backend.
///
/// On iOS we only expose CPU: the LiteRT-LM Metal GPU accelerator is not
/// shipped as a prebuilt iOS binary yet (tracked upstream in LiteRT-LM
/// issue #1050), so selecting GPU/NPU on iOS would just fail at load time
/// with an "Engine type not found" error. On Android the picker shows all
/// three backends — CPU works everywhere, GPU needs OpenCL on a real
/// device, and NPU needs a chip-specific model variant.
class _BackendSelector extends StatelessWidget {
  const _BackendSelector({
    required this.selected,
    required this.onChanged,
  });

  final LiteLmBackend selected;
  final ValueChanged<LiteLmBackend> onChanged;

  @override
  Widget build(BuildContext context) {
    final isIOS = Platform.isIOS;

    if (isIOS) {
      // iOS: CPU is the only backend that's available right now. Show a
      // read-only chip so the user understands the choice without seeing
      // disabled buttons that look broken.
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Inference backend',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 6),
            Chip(
              avatar: const Icon(Icons.memory, size: 18),
              label: const Text('CPU (XNNPACK)'),
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            ),
            const SizedBox(height: 4),
            Text(
              'iOS: LiteRT-LM ships no Metal GPU accelerator yet. CPU is '
              'the only supported backend on iPhone for now.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Inference backend',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 6),
          SegmentedButton<LiteLmBackend>(
            segments: const [
              ButtonSegment(
                value: LiteLmBackend.cpu,
                label: Text('CPU'),
                icon: Icon(Icons.memory),
              ),
              ButtonSegment(
                value: LiteLmBackend.gpu,
                label: Text('GPU'),
                icon: Icon(Icons.bolt),
              ),
              ButtonSegment(
                value: LiteLmBackend.npu,
                label: Text('NPU'),
                icon: Icon(Icons.developer_board),
              ),
            ],
            selected: {selected},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
          const SizedBox(height: 4),
          Text(
            selected == LiteLmBackend.cpu
                ? 'Works everywhere, including the Android emulator.'
                : selected == LiteLmBackend.gpu
                    ? 'Real devices only — emulator has no OpenCL.'
                    : 'Requires a chip-specific NPU model variant.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _DownloadState {
  _DownloadState({
    required this.subscription,
    required this.received,
    required this.total,
  });

  final StreamSubscription<DownloadProgress> subscription;
  final int received;
  final int total;

  double get fraction => total <= 0 ? 0 : received / total;
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.model,
    required this.isDownloaded,
    required this.download,
    required this.onDownload,
    required this.onCancel,
    required this.onDelete,
    required this.onUse,
  });

  final ModelInfo model;
  final bool isDownloaded;
  final _DownloadState? download;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onDelete;
  final VoidCallback onUse;

  String _formatBytes(int bytes) {
    const mb = 1024 * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    return '${(bytes / mb).toStringAsFixed(0)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDownloading = download != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    model.name,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(
                  model.sizeLabel,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              model.description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    model.license,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
                if (model.gated) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: theme.colorScheme.tertiary,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    'Token required',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            if (isDownloading) ...[
              LinearProgressIndicator(value: download!.fraction),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${_formatBytes(download!.received)} / ${_formatBytes(download!.total)}'
                    '  (${(download!.fraction * 100).toStringAsFixed(1)}%)',
                    style: theme.textTheme.bodySmall,
                  ),
                  TextButton(
                    onPressed: onCancel,
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ] else if (isDownloaded) ...[
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: onUse,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Chat'),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                  ),
                ],
              ),
            ] else
              FilledButton.tonalIcon(
                onPressed: onDownload,
                icon: const Icon(Icons.download),
                label: const Text('Download'),
              ),
          ],
        ),
      ),
    );
  }
}
