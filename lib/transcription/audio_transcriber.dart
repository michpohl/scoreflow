import 'dart:math' as math;
import 'dart:typed_data';

import 'timed_note.dart';

const melodySampleRate = 16000;

/// Detects a single melodic line from mono, little-endian PCM16 at 16 kHz.
/// Run in an isolate on mobile to keep the interface responsive.
List<TimedNote> transcribePcm16(Uint8List bytes) {
  if (bytes.length.isOdd) {
    throw const FormatException('The PCM recording is incomplete.');
  }

  // Average pairs of samples to halve the cost of pitch detection.
  final data = ByteData.sublistView(bytes);
  final samples = Float32List(bytes.length ~/ 4);
  for (var i = 0; i < samples.length; i++) {
    final offset = i * 4;
    final first = data.getInt16(offset, Endian.little);
    final second = data.getInt16(offset + 2, Endian.little);
    samples[i] = (first + second) / 65536;
  }
  return _transcribe(samples, melodySampleRate / 2);
}

List<TimedNote> _transcribe(Float32List samples, double sampleRate) {
  final hop = (sampleRate * .01).round();
  final comparisonLength = (sampleRate * .027).round();
  final minimumLag = (sampleRate / 1400).floor();
  final maximumLag = (sampleRate / 55).ceil();
  final windowLength = comparisonLength + maximumLag;
  if (samples.length < windowLength) return [];

  var peak = 0.0;
  for (final sample in samples) {
    peak = math.max(peak, sample.abs());
  }
  final silenceThreshold = math.max(.003, peak * .035);
  final differences = Float64List(maximumLag + 1);
  final notes = <TimedNote>[];
  int? currentPitch;
  int? pendingPitch;
  var start = 0;
  var pendingStart = 0;
  var pendingFrames = 0;

  void finishNote(int end) {
    final pitch = currentPitch;
    if (pitch != null && end - start >= sampleRate * .055) {
      notes.add(
        TimedNote(
          midiNote: pitch,
          startSeconds: start / sampleRate,
          endSeconds: end / sampleRate,
        ),
      );
    }
  }

  for (var offset = 0; offset + windowLength <= samples.length; offset += hop) {
    final center = offset + windowLength ~/ 2;
    final pitch = _detectPitch(
      samples,
      offset,
      comparisonLength,
      minimumLag,
      differences,
      sampleRate,
      silenceThreshold,
    );
    if (pitch == currentPitch) {
      pendingFrames = 0;
      continue;
    }
    // Wait for a stable change before treating vibrato or noise as a new note.
    if (pendingFrames == 0 || pitch != pendingPitch) {
      pendingPitch = pitch;
      pendingStart = offset == 0 ? 0 : center;
      pendingFrames = 1;
      continue;
    }
    pendingFrames++;
    if (pendingFrames >= 3) {
      finishNote(pendingStart);
      currentPitch = pitch;
      start = pendingStart;
      pendingFrames = 0;
    }
  }
  finishNote(samples.length);
  return notes;
}

int? _detectPitch(
  Float32List samples,
  int offset,
  int length,
  int minimumLag,
  Float64List differences,
  double sampleRate,
  double silenceThreshold,
) {
  var sum = 0.0;
  var energy = 0.0;
  for (var index = offset; index < offset + length; index++) {
    final sample = samples[index];
    sum += sample;
    energy += sample * sample;
  }
  final mean = sum / length;
  if (energy / length - mean * mean < silenceThreshold * silenceThreshold) {
    return null;
  }

  // YIN: find the first sufficiently deep trough in the cumulative
  // mean-normalized squared difference between lagged copies of the signal.
  var cumulative = 0.0;
  var bestLag = minimumLag;
  for (var lag = 1; lag < differences.length; lag++) {
    var difference = 0.0;
    for (var index = offset; index < offset + length; index++) {
      final delta = samples[index] - samples[index + lag];
      difference += delta * delta;
    }
    cumulative += difference;
    differences[lag] = cumulative == 0 ? 1 : difference * lag / cumulative;
    if (lag > minimumLag && differences[lag] < differences[bestLag]) {
      bestLag = lag;
    }
    if (lag > minimumLag &&
        differences[lag - 1] < .16 &&
        differences[lag] >= differences[lag - 1]) {
      bestLag = lag - 1;
      break;
    }
  }
  if (differences[bestLag] > .24) return null;

  var period = bestLag.toDouble();
  if (bestLag > minimumLag && bestLag + 1 < differences.length) {
    final left = differences[bestLag - 1];
    final center = differences[bestLag];
    final right = differences[bestLag + 1];
    final curvature = left - 2 * center + right;
    if (curvature > 0) period += (left - right) / (2 * curvature);
  }
  final frequency = sampleRate / period;
  return (69 + 12 * math.log(frequency / 440) / math.ln2).round();
}
