import 'dart:collection';
import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../models/reflow.dart';
import '../models/score.dart';
import 'timed_note.dart';

/// Converts detected notes to an editable score on an eighth-note grid.
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

  // Deduplicate detections of the same pitch and onset. A later attack of that
  // pitch ends the previous event, even if its detected release overlaps.
  final byPitch = <int, SplayTreeMap<int, int>>{};
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
    byPitch
        .putIfAbsent(note.midiNote, SplayTreeMap.new)
        .update(
          start,
          (previous) => math.max(end, previous),
          ifAbsent: () => end,
        );
  }

  final events = <_Note>[];
  for (final entry in byPitch.entries) {
    final timings = entry.value.entries.toList();
    for (var i = 0; i < timings.length; i++) {
      final timing = timings[i];
      final end = i + 1 < timings.length
          ? math.min(timing.value, timings[i + 1].key)
          : timing.value;
      events.add(_Note(entry.key, timing.key, end));
    }
  }
  if (events.isEmpty) {
    throw StateError('No usable notes were detected.');
  }

  events.sort((a, b) => a.start.compareTo(b.start));
  var previousEnd = 0;
  var polyphonic = false;
  for (final note in events) {
    if (note.start < previousEnd) {
      polyphonic = true;
      break;
    }
    previousEnd = note.end;
  }

  final measures = <Measure>[];
  final treble = <_Note>[];
  final bass = <_Note>[];
  for (final note in events) {
    // Keep a single melody on the treble staff. For piano chords, use both
    // staves so that the lower notes stay readable.
    (polyphonic && note.midi < 60 ? bass : treble).add(note);
  }
  _writeVoice(treble, 'treble', measures, slotsPerBar, timeSignature);
  _writeVoice(bass, 'bass', measures, slotsPerBar, timeSignature);

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

class _Note {
  const _Note(this.midi, this.start, this.end);

  final int midi;
  final int start;
  final int end;

  bool overlaps(_Note other) => start < other.end && other.start < end;
}

void _writeVoice(
  List<_Note> notes,
  String voiceId,
  List<Measure> measures,
  int slotsPerBar,
  TimeSignature meter,
) {
  final starts = SplayTreeMap<int, List<_Note>>();
  final byPitch = <int, List<_Note>>{};
  for (final note in notes) {
    starts.putIfAbsent(note.start, () => []).add(note);
    starts.putIfAbsent(note.end, () => []);
    byPitch.putIfAbsent(note.midi, () => []).add(note);
  }
  final written = {for (final note in notes) note: _spell(note, byPitch)};
  final altered = <String, List<_Note>>{};
  for (final entry in written.entries) {
    if (entry.value.accidental.isExplicit) {
      altered.putIfAbsent(_position(entry.value), () => []).add(entry.key);
    }
  }

  final chord = <_Note, Pitch>{};
  final accidentals = <String, Accidental>{};
  var cursor = 0;
  for (final boundary in starts.entries) {
    final end = boundary.key;
    final sounding = chord.entries.toList()
      ..sort((a, b) => a.key.midi.compareTo(b.key.midi));
    final continuing = [
      for (var i = 0; i < sounding.length; i++)
        if (sounding[i].key.end > end) i,
    ];
    while (cursor < end) {
      final bar = cursor ~/ slotsPerBar;
      final offset = cursor % slotsPerBar;
      if (offset == 0) accidentals.clear();
      if (bar == measures.length) {
        measures.add(Measure.empty(InstrumentType.piano));
      }
      final chunkEnd = math.min(end, cursor + slotsPerBar - offset);
      final rhythm = fillRests(
        offset / 8,
        (chunkEnd - cursor) / 8,
        meter.beats,
        meter.beatValue,
      );
      final voice = measures[bar].voice(voiceId);
      for (var i = 0; i < rhythm.length; i++) {
        final segment = rhythm[i];
        final continuesSegment = i < rhythm.length - 1 || chunkEnd < end;
        final fullTie = sounding.isNotEmpty && continuesSegment;
        voice.add(
          MusicNote(
            pitches: [for (final note in sounding) note.value],
            duration: segment.duration,
            dots: segment.dots,
            rest: sounding.isEmpty,
            tieToNext: fullTie,
            tiedPitchIndices: !fullTie && continuing.isNotEmpty
                ? continuing
                : null,
          ),
        );
      }
      for (final note in sounding) {
        final pitch = note.value;
        if (pitch.accidental.isExplicit) {
          accidentals[_position(pitch)] = pitch.accidental;
        }
      }
      cursor = chunkEnd;
    }

    if (end % slotsPerBar == 0) accidentals.clear();
    chord.removeWhere((note, _) => note.end == end);
    for (final note in boundary.value) {
      final pitch = written[note]!;
      final staffPosition = _position(pitch);
      final previous = accidentals[staffPosition];
      final overlapsAltered =
          altered[staffPosition]?.any(note.overlaps) ?? false;
      final needsNatural =
          (previous != null && previous != Accidental.natural) ||
          overlapsAltered;
      chord[note] = pitch.accidental == Accidental.none && needsNatural
          ? pitch.withAccidental(Accidental.natural)
          : pitch;
    }
  }
}

String _position(Pitch pitch) => '${pitch.step}${pitch.octave}';

Pitch _spell(_Note note, Map<int, List<_Note>> byPitch) {
  const steps = ['c', 'c', 'd', 'd', 'e', 'f', 'f', 'g', 'g', 'a', 'a', 'b'];
  const blackKeys = {1, 3, 6, 8, 10};
  final chroma = note.midi % 12;
  final octave = note.midi ~/ 12 - 1;
  if (!blackKeys.contains(chroma)) {
    return Pitch(step: steps[chroma], octave: octave);
  }
  // Use a flat if the sharp would share its staff position with a
  // simultaneous natural and the flat has a free position.
  final lowerOverlaps = byPitch[note.midi - 1]?.any(note.overlaps) ?? false;
  final higherOverlaps = byPitch[note.midi + 1]?.any(note.overlaps) ?? false;
  return lowerOverlaps && !higherOverlaps
      ? Pitch(
          step: steps[chroma + 1],
          octave: octave,
          accidental: Accidental.flat,
        )
      : Pitch(
          step: steps[chroma],
          octave: octave,
          accidental: Accidental.sharp,
        );
}
