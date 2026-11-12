import 'package:flutter_test/flutter_test.dart';
import 'package:scoreflow/models/reflow.dart';
import 'package:scoreflow/models/score.dart';
import 'package:scoreflow/transcription/melody_quantizer.dart';
import 'package:scoreflow/transcription/timed_note.dart';

TimedNote note(int pitch, double start, double end) =>
    TimedNote(midiNote: pitch, startSeconds: start, endSeconds: end);

Score convert(List<TimedNote> notes, {double countInSeconds = 0}) =>
    quantizeMelody(
      notes,
      title: 'Test melody',
      bpm: 120,
      timeSignature: TimeSignature.common,
      countInSeconds: countInSeconds,
    );

void main() {
  test(
    'drops the count-in and quantizes notes and rests from the downbeat',
    () {
      final score = convert([
        note(68, 0.25, 0.50),
        note(60, 1.24, 1.49),
        note(62, 1.75, 2.24),
      ], countInSeconds: 1);
      final melody = score.measures.single.voice('treble');
      expect(score.title, 'Test melody');
      expect(score.tempo, 120);
      expect(melody.map((n) => n.duration), ['8', '8', '8', '8', '8']);
      expect(melody.map((n) => n.keys), [
        [],
        ['c/4'],
        [],
        ['d/4'],
        ['d/4'],
      ]);
      expect(melody[3].tieToNext, isTrue);
      expect(score.measures.single.voice('bass'), isEmpty);
    },
  );

  test('ties sustained notes across barlines and preserves them on save', () {
    final score = convert([note(66, 1.75, 2.50)]);
    final decoded = Score.decode(score.encode());
    expect(decoded.measures, hasLength(2));
    final first = decoded.measures.first.voice('treble');
    final second = decoded.measures.last.voice('treble');
    expect(first.fold(0.0, (total, n) => total + noteTime(n)), 1);
    expect(first.last.keys, ['f#/4']);
    expect(first.last.tieToNext, isTrue);
    expect(second.single.keys, ['f#/4']);
    expect(second.single.duration, 'q');
    expect(second.single.tieToNext, isFalse);
  });

  test('cancels accidentals and caps a sustain at the next note', () {
    final score = convert([
      note(66, 0, 0.8),
      note(65, 0.5, 1),
      note(22, 1.25, 1.26),
    ]);
    final melody = score.measures.single.voice('treble');
    expect(melody.map((n) => n.keys), [
      ['f#/4'],
      ['fn/4'],
    ]);
    expect(melody.map((n) => n.duration), ['q', 'q']);
  });

  test('reports recordings without usable notes', () {
    expect(
      () => convert([note(127, 0, 0.5), note(60, 0.5, 0.51)]),
      throwsStateError,
    );
  });

  test('uses quarter-note BPM in 6/8', () {
    final score = quantizeMelody(
      [note(60, 0, 1.75)],
      title: 'Compound meter',
      bpm: 120,
      timeSignature: const TimeSignature(6, 8),
    );
    expect(score.measures, hasLength(2));
    final first = score.measures.first.voice('treble');
    expect(first.map((n) => (n.duration, n.dots)), [('q', 1), ('q', 1)]);
    expect(first.every((n) => n.tieToNext), isTrue);
    expect(score.measures.last.voice('treble').single.duration, '8');
  });
}
