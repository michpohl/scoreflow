import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../models/score.dart';
import '../transcription/audio_transcriber.dart';
import '../transcription/melody_quantizer.dart';

enum _Phase { ready, starting, counting, recording, processing }

class RecordMelodyScreen extends StatefulWidget {
  const RecordMelodyScreen({super.key});

  @override
  State<RecordMelodyScreen> createState() => _RecordMelodyScreenState();
}

class _RecordMelodyScreenState extends State<RecordMelodyScreen> {
  static const _maxTake = Duration(seconds: 30);
  static const _meters = [
    TimeSignature(2, 4),
    TimeSignature(3, 4),
    TimeSignature.common,
  ];

  final _recorder = AudioRecorder();
  final _title = TextEditingController();
  final _tempo = TextEditingController(text: '100');
  final _samples = BytesBuilder(copy: false);
  final _clock = Stopwatch();
  StreamSubscription<Uint8List>? _subscription;
  Completer<void>? _streamDone;
  Timer? _timer;
  Object? _streamError;
  _Phase _phase = _Phase.ready;
  TimeSignature _meter = TimeSignature.common;
  String? _error;
  double _bpm = 100;
  int _beat = 1;

  double get _countInSeconds => _meter.beats * 60 / _bpm;

  Future<void> _start() async {
    if (_phase != _Phase.ready) return;
    final bpm = int.tryParse(_tempo.text.trim());
    if (bpm == null || bpm < 40 || bpm > 220) {
      setState(() => _error = 'Enter a tempo from 40 to 220 BPM.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _bpm = bpm.toDouble();
      _phase = _Phase.starting;
      _error = null;
      _beat = 1;
    });
    try {
      if (!await _recorder.hasPermission()) {
        _reset('Allow microphone access in your device settings to record.');
        return;
      }
      if (!mounted) return;
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: melodySampleRate,
          numChannels: 1,
        ),
      );
      if (!mounted) return;
      _streamDone = Completer<void>();
      _subscription = stream.listen(
        _samples.add,
        onError: (Object error) => _streamError = error,
        onDone: _streamDone!.complete,
      );
      _clock
        ..reset()
        ..start();
      setState(() => _phase = _Phase.counting);
      _timer = Timer.periodic(const Duration(milliseconds: 25), _tick);
    } catch (error) {
      debugPrint('Could not start melody recording: $error');
      await _cancel('Could not start the microphone. Try again.');
    }
  }

  void _tick(Timer timer) {
    final seconds = _clock.elapsedMicroseconds / Duration.microsecondsPerSecond;
    final elapsed = seconds - _countInSeconds;
    if (elapsed >= _maxTake.inSeconds) {
      unawaited(_finish());
      return;
    }
    final phase = elapsed < 0 ? _Phase.counting : _Phase.recording;
    final beat = (seconds * _bpm / 60).floor() % _meter.beats + 1;
    if (phase != _phase || beat != _beat) {
      setState(() {
        _phase = phase;
        _beat = beat;
      });
    }
  }

  Future<void> _finish() async {
    if (_phase != _Phase.recording) return;
    _timer?.cancel();
    setState(() => _phase = _Phase.processing);
    try {
      await _recorder.stop();
      await _streamDone?.future.timeout(const Duration(seconds: 2));
      if (_streamError case final error?) throw error;
      final bytes = _samples.takeBytes();
      final notes = await compute(transcribePcm16, bytes);
      if (!mounted) return;
      if (notes.isEmpty) {
        _reset('No clear notes found. Try a short melody in a quiet room.');
        return;
      }
      final title = _title.text.trim();
      final score = quantizeMelody(
        notes,
        title: title.isEmpty ? 'Recorded melody' : title,
        bpm: _bpm,
        timeSignature: _meter,
        countInSeconds: _countInSeconds,
      );
      Navigator.of(context).pop(score);
    } on StateError {
      _reset('No clear notes found. Start playing after the count-in.');
    } catch (error) {
      debugPrint('Could not transcribe melody: $error');
      await _cancel('Could not transcribe this recording. Try again.');
    }
  }

  Future<void> _cancel([String? message]) async {
    if (message == null &&
        _phase != _Phase.counting &&
        _phase != _Phase.recording) {
      return;
    }
    _timer?.cancel();
    if (mounted) setState(() => _phase = _Phase.processing);
    try {
      await _recorder.cancel();
    } catch (error) {
      debugPrint('Could not cancel melody recording: $error');
    } finally {
      _reset(message);
    }
  }

  void _reset(String? message) {
    _clock.stop();
    unawaited(_subscription?.cancel());
    _subscription = null;
    _streamDone = null;
    _streamError = null;
    _samples.clear();
    if (mounted) {
      setState(() {
        _phase = _Phase.ready;
        _error = message;
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_recorder.dispose());
    _title.dispose();
    _tempo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _phase == _Phase.ready;
    final recording = _phase == _Phase.recording;
    final counting = _phase == _Phase.counting;
    final busy = _phase == _Phase.processing || _phase == _Phase.starting;
    final status = switch (_phase) {
      _Phase.ready =>
        'Play or hum one note at a time. Start after the count-in.',
      _Phase.starting => 'Opening microphone…',
      _Phase.counting => 'Count-in · $_beat of ${_meter.beats}',
      _Phase.recording => 'Recording · Beat $_beat of ${_meter.beats}',
      _Phase.processing => 'Processing recording…',
    };

    return PopScope(
      canPop: ready,
      child: Scaffold(
        appBar: AppBar(title: const Text('Record melody')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              TextField(
                controller: _title,
                enabled: ready,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Score title'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _tempo,
                enabled: ready,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Tempo (BPM)'),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<TimeSignature>(
                initialValue: _meter,
                decoration: const InputDecoration(labelText: 'Time signature'),
                items: [
                  for (final meter in _meters)
                    DropdownMenuItem(value: meter, child: Text(meter.vex)),
                ],
                onChanged: ready
                    ? (meter) => setState(() => _meter = meter!)
                    : null,
              ),
              const SizedBox(height: 24),
              Text(status, style: Theme.of(context).textTheme.titleMedium),
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              if (busy)
                const LinearProgressIndicator()
              else if (ready || recording)
                FilledButton.icon(
                  onPressed: ready ? _start : _finish,
                  icon: Icon(ready ? Icons.mic : Icons.stop),
                  label: Text(
                    ready ? 'Start recording' : 'Stop and transcribe',
                  ),
                ),
              if (counting || recording)
                TextButton(
                  onPressed: () => _cancel(),
                  child: const Text('Cancel take'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
