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

  test('cancels accidentals in a monophonic take', () {
    final score = convert([
      note(66, 0, 0.5),
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

  test('keeps simultaneous pitches and splits a piano chord across staves', () {
    final score = convert([
      note(55, 0, 0.5),
      note(67, 0, 0.5),
      note(60, 0, 0.5),
      note(64, 0, 0.5),
    ]);
    final bar = score.measures.single;
    expect(bar.voice('bass').single.keys, ['g/3']);
    expect(bar.voice('treble').single.keys, ['c/4', 'e/4', 'g/4']);
    expect(bar.voice('treble').single.duration, 'q');
    expect(bar.voice('treble').single.tieToNext, isFalse);
  });

  test('ties each continuing pitch through staggered attacks and releases', () {
    final score = convert([
      note(60, 0, 1.5),
      note(64, 0.5, 1),
      note(67, 0.5, 1.5),
    ]);
    final chordSequence = Score.decode(
      score.encode(),
    ).measures.single.voice('treble');
    expect(chordSequence.map((n) => n.keys), [
      ['c/4'],
      ['c/4', 'e/4', 'g/4'],
      ['c/4', 'g/4'],
    ]);
    expect(chordSequence.map((n) => n.tiedPitchIndices), [
      [0],
      [0, 2],
      null,
    ]);
  });

  test('keeps partial ties across barlines without tying new attacks', () {
    final score = convert([
      note(60, 1.5, 2.5),
      note(64, 1.5, 2),
      note(67, 2, 2.5),
    ]);
    final before = score.measures.first.voice('treble').last;
    final after = score.measures.last.voice('treble').single;
    expect(before.keys, ['c/4', 'e/4']);
    expect(before.tiedPitchIndices, [0]);
    expect(after.keys, ['c/4', 'g/4']);
  });

  test('preserves a same-pitch reattack when detected releases overlap', () {
    final score = convert([note(60, 0, 0.7), note(60, 0.5, 1), note(64, 0, 1)]);
    final melody = score.measures.single.voice('treble');
    expect(melody.map((n) => n.keys), [
      ['c/4', 'e/4'],
      ['c/4', 'e/4'],
    ]);
    expect(melody.first.tiedPitchIndices, [1]);
    expect(melody.last.tiedPitchIndices, isNull);
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
