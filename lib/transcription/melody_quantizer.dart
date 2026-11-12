import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../models/reflow.dart';
import '../models/score.dart';
import 'timed_note.dart';

/// Converts a monophonic recording to an editable score on an eighth-note grid.
/// BPM is in quarter notes, including for time signatures with an eighth-note
/// denominator. The editor supplies the final bar's trailing rest padding.
Score quantizeMelody(
  List<TimedNote> notes, {
  required String title,
  required double bpm,
  required TimeSignature timeSignature,
  double countInSeconds = 0,
}) {
  if (!bpm.isFinite || bpm < 1) {
    throw ArgumentError.value(bpm, 'bpm', 'Expected a positive tempo.');
  }
  if (timeSignature.beats < 1 ||
      !const [1, 2, 4, 8].contains(timeSignature.beatValue)) {
    throw ArgumentError.value(timeSignature.vex, 'timeSignature');
  }
  if (!countInSeconds.isFinite || countInSeconds < 0) {
    throw ArgumentError.value(countInSeconds, 'countInSeconds');
  }

  final tempo = bpm.round();
  final slotsPerBar = 8 * timeSignature.beats ~/ timeSignature.beatValue;
  int slot(double seconds) =>
      math.max(0, ((seconds - countInSeconds) * tempo / 30).round());

  // Multiple detections that quantize to the same onset cannot coexist in a
  // monophonic score. Keep the one sustained longest.
  final byStart = <int, ({int end, TimedNote note})>{};
  for (final note in notes) {
    if (note.midiNote < 21 ||
        note.midiNote > 108 ||
        !note.startSeconds.isFinite ||
        !note.endSeconds.isFinite ||
        note.endSeconds - math.max(note.startSeconds, countInSeconds) < 0.045) {
      continue;
    }
    final start = slot(note.startSeconds);
    final end = math.max(start + 1, slot(note.endSeconds));
    final previous = byStart[start];
    if (previous == null || note.endSeconds > previous.note.endSeconds) {
      byStart[start] = (end: end, note: note);
    }
  }
  if (byStart.isEmpty) {
    throw StateError('No usable notes were detected.');
  }

  final starts = byStart.keys.toList()..sort();
  final measures = <Measure>[];
  final accidentals = <String, Accidental>{};
  const pitchNames = [
    'c',
    'c#',
    'd',
    'd#',
    'e',
    'f',
    'f#',
    'g',
    'g#',
    'a',
    'a#',
    'b',
  ];
  var position = 0;

  void appendUntil(int end, {Pitch? pitch}) {
    while (position < end) {
      final offset = position % slotsPerBar;
      if (offset == 0) {
        measures.add(Measure.empty(InstrumentType.piano));
        accidentals.clear();
      }
      final chunkEnd = math.min(end, position + slotsPerBar - offset);
      final voice = measures.last.voice('treble');
      final rhythm = fillRests(
        offset / 8,
        (chunkEnd - position) / 8,
        timeSignature.beats,
        timeSignature.beatValue,
      );
      for (var i = 0; i < rhythm.length; i++) {
        final segment = rhythm[i];
        voice.add(
          MusicNote(
            pitches: pitch == null ? const [] : [pitch],
            duration: segment.duration,
            dots: segment.dots,
            rest: pitch == null,
            tieToNext:
                pitch != null && (i < rhythm.length - 1 || chunkEnd < end),
          ),
        );
      }
      if (pitch != null && pitch.accidental.isExplicit) {
        accidentals['${pitch.step}${pitch.octave}'] = pitch.accidental;
      }
      position = chunkEnd;
    }
  }

  for (var i = 0; i < starts.length; i++) {
    final start = starts[i];
    final event = byStart[start]!;
    appendUntil(start);
    final midi = event.note.midiNote;
    final name = pitchNames[midi % 12];
    final step = name[0];
    final octave = midi ~/ 12 - 1;
    final cancelsSharp =
        start % slotsPerBar != 0 &&
        accidentals['$step$octave'] == Accidental.sharp;
    final accidental = name.endsWith('#')
        ? Accidental.sharp
        : cancelsSharp
        ? Accidental.natural
        : Accidental.none;
    final end = i + 1 < starts.length
        ? math.min(event.end, starts[i + 1])
        : event.end;
    appendUntil(
      end,
      pitch: Pitch(step: step, octave: octave, accidental: accidental),
    );
  }

  final now = DateTime.now();
  return Score(
    id: const Uuid().v4(),
    title: title.trim().isEmpty ? 'Recorded melody' : title.trim(),
    instrument: InstrumentType.piano,
    timeSignature: timeSignature,
    tempo: tempo,
    measures: measures,
    createdAt: now,
    updatedAt: now,
  );
}
