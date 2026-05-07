import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Snapshot of an in-flight download. Emitted by [ModelManager.download].
class DownloadProgress {
  const DownloadProgress({
    required this.received,
    required this.total,
  });

  final int received;
  final int total;

  double get fraction => total <= 0 ? 0 : received / total;
}

/// Resolves storage paths for downloaded `.litertlm` files and runs HTTP
/// downloads with progress reporting + cancellation.
///
/// Files are written to the app's documents directory under `models/`, which
/// survives across launches and is not visible to other apps. Downloads
/// stream to a `.part` file and are atomically renamed only on success, so a
/// partial/cancelled download will never be mistaken for a finished model.
class ModelManager {
  Directory? _cachedDir;

  /// Returns the directory where models are stored, creating it on first use.
  Future<Directory> _modelsDir() async {
    if (_cachedDir != null) return _cachedDir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/models');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _cachedDir = dir;
    return dir;
  }

  /// Absolute filesystem path the given [model] would live at when downloaded.
  Future<String> pathFor(ModelInfo model) async {
    final dir = await _modelsDir();
    return '${dir.path}/${model.id}.litertlm';
  }

  /// True if the model has been fully downloaded. We rely on the atomic
  /// `.part` → final rename in [download] for correctness, so checking that
  /// the final file exists is enough — no need to second-guess by comparing
  /// against a hardcoded byte count (which would break the moment HF
  /// re-publishes the same model with a different size).
  Future<bool> isDownloaded(ModelInfo model) async {
    final file = File(await pathFor(model));
    return file.existsSync();
  }

  /// Delete a downloaded model from disk. No-op if it isn't there.
  Future<void> delete(ModelInfo model) async {
    final file = File(await pathFor(model));
    if (file.existsSync()) {
      await file.delete();
    }
    final partial = File('${file.path}.part');
    if (partial.existsSync()) {
      await partial.delete();
    }
  }

  /// Download [model] from HuggingFace, streaming to a `.part` file and
  /// emitting progress on the returned stream. The download can be aborted by
  /// cancelling the stream subscription — the partial file is left in place
  /// (so a future improvement could resume via Range requests, but the
  /// example just deletes it on next attempt).
  ///
  /// [token] is an optional HuggingFace access token; required for gated
  /// models, ignored otherwise.
  ///
  /// HuggingFace gated downloads work in two hops: the first request to
  /// `huggingface.co/.../resolve/main/<file>` returns a 302 to a pre-signed
  /// CDN URL on `cdn-lfs.huggingface.co`. We follow redirects manually so
  /// that we can drop the `Authorization` header on cross-origin hops — the
  /// CDN URL is already signed and some CDNs reject extra auth headers.
  Stream<DownloadProgress> download(
    ModelInfo model, {
    String? token,
  }) async* {
    final cleanedToken = token?.trim();

    final finalPath = await pathFor(model);
    final partialPath = '$finalPath.part';
    final partialFile = File(partialPath);
    // Always start fresh — we don't yet support resume.
    if (partialFile.existsSync()) {
      await partialFile.delete();
    }

    final client = HttpClient();
    IOSink? sink;
    try {
      final response = await _resolveWithRedirects(
        client: client,
        url: Uri.parse(model.url),
        token: cleanedToken,
        gated: model.gated,
      );

      final total =
          response.contentLength > 0 ? response.contentLength : model.sizeBytes;
      var received = 0;
      sink = partialFile.openWrite();

      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        yield DownloadProgress(received: received, total: total);
      }

      await sink.flush();
      await sink.close();
      sink = null;

      // Atomically promote the .part file to its final name.
      await partialFile.rename(finalPath);
    } finally {
      // Best-effort cleanup if we threw mid-write.
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }

  /// Manually follow up to 5 redirects starting from [url], passing the HF
  /// `Authorization` header only on the original host. Returns the final
  /// 200 response (the body stream is unread, ready to be piped to disk).
  Future<HttpClientResponse> _resolveWithRedirects({
    required HttpClient client,
    required Uri url,
    required String? token,
    required bool gated,
  }) async {
    var current = url;
    final originHost = url.host;
    for (var hop = 0; hop < 6; hop++) {
      final request = await client.getUrl(current);
      // Don't let dart:io auto-follow — we need to control headers per hop.
      request.followRedirects = false;
      // Only attach the bearer token while we are still talking to the
      // original HF host. The CDN URL we get redirected to is already
      // signed; sending a stray Authorization there can trigger 400/403.
      if (token != null && token.isNotEmpty && current.host == originHost) {
        request.headers.set('Authorization', 'Bearer $token');
      }
      final response = await request.close();

      // Successful body response — return it for the caller to drain.
      if (response.statusCode == 200) {
        return response;
      }

      // Redirect — read Location, drain the body, loop.
      if (response.isRedirect) {
        final location = response.headers.value('location');
        await response.drain<void>();
        if (location == null) {
          throw HttpException(
            'Redirect with no Location header (status ${response.statusCode})',
          );
        }
        current = current.resolve(location);
        continue;
      }

      // Surface a useful error including any short error body HF returned.
      final body = await _readBodyPreview(response);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw HttpException(
          'Access denied (HTTP ${response.statusCode}). '
          '${gated ? "Make sure you accepted the model's license on its HuggingFace page and that the token has read permission. " : ""}'
          '${body.isNotEmpty ? "Server said: $body" : ""}',
        );
      }
      throw HttpException(
        'Download failed: HTTP ${response.statusCode}'
        '${body.isNotEmpty ? " — $body" : ""}',
      );
    }
    throw const HttpException('Too many redirects');
  }

  /// Read at most ~512 bytes of the response body so we can include the
  /// server's error message in our exception without buffering megabytes.
  Future<String> _readBodyPreview(HttpClientResponse response) async {
    try {
      final buffer = StringBuffer();
      var read = 0;
      await for (final chunk in response) {
        buffer.write(String.fromCharCodes(chunk));
        read += chunk.length;
        if (read >= 512) break;
      }
      return buffer.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
    } catch (_) {
      return '';
    }
  }
}
