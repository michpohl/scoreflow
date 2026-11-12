import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreflow/models/score.dart';
import 'package:scoreflow/transcription/audio_transcriber.dart';
import 'package:scoreflow/transcription/melody_quantizer.dart';

void main() {
  test('turns recorded PCM into editable pitches, durations, and rests', () {
    const takeSeconds = 3.5;
    final pcm = ByteData((takeSeconds * melodySampleRate).round() * 2);
    for (var i = 0; i < pcm.lengthInBytes ~/ 2; i++) {
      final time = i / melodySampleRate;
      final frequency = switch (time) {
        >= 2.0 && < 2.5 => 440.0,
        >= 2.75 && < 3.25 => 523.251,
        _ => 0.0,
      };
      final sample = 12000 * math.sin(2 * math.pi * frequency * time);
      pcm.setInt16(i * 2, sample.round(), Endian.little);
    }

    final score = quantizeMelody(
      transcribePcm16(pcm.buffer.asUint8List()),
      title: 'Test take',
      bpm: 120,
      timeSignature: TimeSignature.common,
      countInSeconds: 2,
    );
    final restored = Score.decode(score.encode());
    final melody = restored.measures.single.voice('treble');
    expect(melody.where((note) => !note.rest).map((note) => note.keys.single), [
      'a/4',
      'c/5',
      'c/5',
    ]);
    expect(melody[1].rest, isTrue);
    expect(melody[1].duration, '8');
  });

  test('silence yields no notes', () {
    expect(transcribePcm16(Uint8List(melodySampleRate * 2)), isEmpty);
  });
}
