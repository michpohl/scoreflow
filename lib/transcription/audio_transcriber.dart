import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../engine/engine_assets.dart';
import '../engine/engine_bootstrap.dart';
import 'timed_note.dart';

const melodySampleRate = 22050;

/// Runs the bundled Basic Pitch model in an isolated WebView. The WebView
/// loads its code and weights from the same loopback server as the score editor.
Future<List<TimedNote>> transcribePcm16(Uint8List bytes) async {
  if (bytes.length.isOdd) {
    throw const FormatException('The PCM recording is incomplete.');
  }
  if (bytes.every((byte) => byte == 0)) return [];

  await bootstrapEngine();
  final ready = Completer<InAppWebViewController?>();
  final index = resolveAsset('transcription/index.html');
  final webView = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(index)),
    initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
    onLoadStop: (controller, url) {
      if (!ready.isCompleted && url?.toString() == index) {
        ready.complete(controller);
      }
    },
    onReceivedError: (controller, request, error) {
      if (!ready.isCompleted && request.isForMainFrame != false) {
        ready.complete(null);
      }
    },
  );

  try {
    await webView.run();
    final controller = await ready.future.timeout(const Duration(seconds: 15));
    if (controller == null) {
      throw Exception('Could not load the transcription engine.');
    }

    // A full take can exceed Android's JavaScript message size limit.
    // Each chunk fits comfortably, including its UTF-16 representation.
    const chunkSize = 48 * 1024;
    final encoded = base64Encode(bytes);
    await controller.evaluateJavascript(source: 'window.scoreFlowPcm = [];');
    for (var start = 0; start < encoded.length; start += chunkSize) {
      final end = math.min(start + chunkSize, encoded.length);
      final chunk = encoded.substring(start, end);
      await controller.evaluateJavascript(
        source: 'window.scoreFlowPcm.push("$chunk");',
      );
    }

    final result = await controller
        .callAsyncJavaScript(
          functionBody: '''
            const pcm = window.scoreFlowPcm.join('');
            delete window.scoreFlowPcm;
            return await window.transcribePcm16(pcm);
          ''',
        )
        .timeout(const Duration(seconds: 120));
    if (result == null || result.error != null) {
      throw Exception('Transcription engine failed: ${result?.error}');
    }
    final events = result.value;
    if (events is! List) {
      throw const FormatException('Invalid transcription result.');
    }
    return events.map((event) {
      if (event case {
        'midiNote': final num midi,
        'startSeconds': final num start,
        'endSeconds': final num end,
      }) {
        return TimedNote(
          midiNote: midi.toInt(),
          startSeconds: start.toDouble(),
          endSeconds: end.toDouble(),
        );
      }
      throw const FormatException('Invalid transcribed note.');
    }).toList();
  } finally {
    await webView.dispose();
  }
}
