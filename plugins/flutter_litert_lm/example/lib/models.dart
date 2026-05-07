/// Curated list of LiteRT-LM models that the example app can download.
///
/// Every entry below is **publicly downloadable without a HuggingFace token**
/// — none are gated under the Gemma license. Sizes are exact `Content-Length`
/// values from HuggingFace at authoring time. Sorted smallest to largest so
/// the picker shows the most phone-friendly options first.
class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.filename,
    required this.url,
    required this.sizeBytes,
    required this.gated,
    required this.license,
  });

  /// Stable identifier used as the on-disk filename and storage key.
  final String id;

  /// Human-friendly name shown in the picker.
  final String name;

  /// One-line description of the trade-off.
  final String description;

  /// Original filename on HuggingFace (informational).
  final String filename;

  /// Direct download URL (HuggingFace `resolve/main/...`).
  final String url;

  /// Total file size in bytes.
  final int sizeBytes;

  /// Whether the model is behind HuggingFace's Gemma license gate. Gated
  /// models require an `Authorization: Bearer <HF_TOKEN>` header.
  final bool gated;

  /// SPDX-style license tag, displayed on the card.
  final String license;

  /// Pretty-printed file size, e.g. "2.46 GB".
  String get sizeLabel {
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (sizeBytes >= gb) {
      return '${(sizeBytes / gb).toStringAsFixed(2)} GB';
    }
    if (sizeBytes >= mb) {
      return '${(sizeBytes / mb).toStringAsFixed(0)} MB';
    }
    return '${(sizeBytes / kb).toStringAsFixed(0)} KB';
  }
}

/// All models the example app knows about. All entries are public — no
/// HuggingFace token required.
const availableModels = <ModelInfo>[
  ModelInfo(
    id: 'qwen3-0.6b',
    name: 'Qwen 3 0.6B',
    description:
        'Smallest general-purpose chat model. Best pick for low-RAM phones.',
    filename: 'Qwen3-0.6B.litertlm',
    url:
        'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm',
    sizeBytes: 614235648,
    gated: false,
    license: 'Apache-2.0',
  ),
  ModelInfo(
    id: 'qwen2.5-1.5b-instruct-q8',
    name: 'Qwen 2.5 1.5B Instruct',
    description: 'Balanced quality/size sweet spot. int8 quant, 4K context.',
    filename: 'Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm',
    url:
        'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm',
    sizeBytes: 1604270080,
    gated: false,
    license: 'Apache-2.0',
  ),
  ModelInfo(
    id: 'deepseek-r1-distill-qwen-1.5b',
    name: 'DeepSeek R1 Distill Qwen 1.5B',
    description: 'Reasoning-style model with chain-of-thought. int8 quant.',
    filename:
        'DeepSeek-R1-Distill-Qwen-1.5B_multi-prefill-seq_q8_ekv4096.litertlm',
    url:
        'https://huggingface.co/litert-community/DeepSeek-R1-Distill-Qwen-1.5B/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B_multi-prefill-seq_q8_ekv4096.litertlm',
    sizeBytes: 1839620096,
    gated: false,
    license: 'MIT',
  ),
  ModelInfo(
    id: 'gemma-4-E2B-it',
    name: 'Gemma 4 E2B (Instruct)',
    description: 'Google Gemma 4 — strong general chat, larger footprint.',
    filename: 'gemma-4-E2B-it.litertlm',
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    sizeBytes: 2583085056,
    gated: false,
    license: 'Apache-2.0',
  ),
  ModelInfo(
    id: 'gemma-4-E4B-it',
    name: 'Gemma 4 E4B (Instruct)',
    description: 'Largest option, highest quality. Needs ~5 GB free RAM.',
    filename: 'gemma-4-E4B-it.litertlm',
    url:
        'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm',
    sizeBytes: 3654467584,
    gated: false,
    license: 'Apache-2.0',
  ),
];
