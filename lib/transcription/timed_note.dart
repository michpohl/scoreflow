/// A detected note in recording time, before rhythm quantization.
class TimedNote {
  const TimedNote({
    required this.midiNote,
    required this.startSeconds,
    required this.endSeconds,
  });

  final int midiNote;
  final double startSeconds;
  final double endSeconds;
}
