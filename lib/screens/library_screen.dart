import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../data/score_repository.dart';
import '../models/score.dart';
import '../widgets/instrument_icon.dart';
import 'editor_screen.dart';
import 'record_melody_screen.dart';

/// «Кабинет» — локальная библиотека партитур: список, создание, удаление.
class LibraryScreen extends StatefulWidget {
  final ScoreRepository repository;
  const LibraryScreen({super.key, required this.repository});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late Future<List<Score>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _future = widget.repository.listAll();
    });
  }

  Future<void> _openEditor(Score score) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            EditorScreen(scoreId: score.id, repository: widget.repository),
      ),
    );
    if (mounted) _reload(); // обновляем список (мог измениться заголовок/дата)
  }

  Future<void> _createScore() async {
    final result = await showDialog<_NewScoreSpec>(
      context: context,
      builder: (_) => const _NewScoreDialog(),
    );
    if (result == null) return;

    final score = Score.create(
      id: const Uuid().v4(),
      title: result.title,
      instrument: result.instrument,
      timeSignature: result.timeSignature,
      now: DateTime.now(),
    );
    await widget.repository.save(score);
    if (mounted) await _openEditor(score);
  }

  Future<void> _confirmDelete(Score score) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete score?'),
        content: Text('“${score.title}” will be permanently deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.repository.delete(score.id);
      _reload();
    }
  }

  Future<void> _recordMelody() async {
    final score = await Navigator.of(context).push<Score>(
      MaterialPageRoute(builder: (_) => const RecordMelodyScreen()),
    );
    if (score == null || !mounted) return;
    try {
      await widget.repository.save(score);
    } on Exception {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save the recorded score.')),
      );
      return;
    }
    if (mounted) await _openEditor(score);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ScoreFlow · Library'),
        actions: [
          if (!kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS))
            IconButton(
              icon: const Icon(Icons.mic),
              tooltip: 'Record music',
              onPressed: _recordMelody,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createScore,
        icon: const Icon(Icons.add),
        label: const Text('New score'),
      ),
      body: FutureBuilder<List<Score>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final scores = snap.data ?? const <Score>[];
          if (scores.isEmpty) return const _EmptyState();
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: scores.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _ScoreCard(
                score: scores[i],
                onOpen: () => _openEditor(scores[i]),
                onDelete: () => _confirmDelete(scores[i]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ScoreCard extends StatelessWidget {
  final Score score;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  const _ScoreCard({
    required this.score,
    required this.onOpen,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: CircleAvatar(
          child: InstrumentIcon(score.instrument),
        ),
        title: Text(
          score.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${score.instrument.label} · ${score.timeSignature.vex} · '
          '${score.measures.length} '
          '${score.measures.length == 1 ? 'measure' : 'measures'}',
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          onPressed: onDelete,
        ),
        onTap: onOpen,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.library_music_outlined,
              size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          const Text('No scores yet'),
          const SizedBox(height: 4),
          Text('Tap New score to create one.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Результат диалога создания партитуры.
class _NewScoreSpec {
  final String title;
  final InstrumentType instrument;
  final TimeSignature timeSignature;
  _NewScoreSpec(this.title, this.instrument, this.timeSignature);
}

class _NewScoreDialog extends StatefulWidget {
  const _NewScoreDialog();
  @override
  State<_NewScoreDialog> createState() => _NewScoreDialogState();
}

class _NewScoreDialogState extends State<_NewScoreDialog> {
  /// Готовые размеры. `null` — режим «свой» с ручным вводом.
  static const _presets = <TimeSignature?>[
    TimeSignature(4, 4),
    TimeSignature(3, 4),
    TimeSignature(2, 4),
    TimeSignature(6, 8),
    null,
  ];

  /// Допустимые знаменатели (длительность доли) в музыкальной нотации.
  static const _beatValues = [1, 2, 4, 8, 16];

  final _titleCtrl = TextEditingController();
  final _beatsCtrl = TextEditingController(text: '4');
  InstrumentType _instrument = InstrumentType.piano;
  TimeSignature? _preset = TimeSignature.common;
  int _customBeatValue = 4;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _beatsCtrl.dispose();
    super.dispose();
  }

  bool get _isCustom => _preset == null;

  /// Итоговый размер: пресет или собранный из полей ручного ввода.
  TimeSignature get _timeSignature {
    if (!_isCustom) return _preset!;
    final beats = int.tryParse(_beatsCtrl.text.trim()) ?? 0;
    return TimeSignature(beats, _customBeatValue);
  }

  bool get _isValid {
    final ts = _timeSignature;
    return ts.beats >= 1 && ts.beats <= 32;
  }

  String _presetLabel(TimeSignature? p) => p == null ? 'Custom' : p.vex;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New score'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            TextField(
              controller: _titleCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Title',
                hintText: 'e.g. Etude No. 1',
              ),
            ),
            const SizedBox(height: 16),
            Text('Instrument', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final i in InstrumentType.values)
                  ChoiceChip(
                    avatar: InstrumentIcon(i, size: 18),
                    label: Text(i.label),
                    selected: _instrument == i,
                    onSelected: (_) => setState(() => _instrument = i),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text('Time signature',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final p in _presets)
                  ChoiceChip(
                    label: Text(_presetLabel(p)),
                    selected: _preset == p,
                    onSelected: (_) => setState(() => _preset = p),
                  ),
              ],
            ),
            if (_isCustom) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 84,
                    child: TextField(
                      controller: _beatsCtrl,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Beats',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text('/', style: TextStyle(fontSize: 24)),
                  ),
                  SizedBox(
                    width: 96,
                    child: DropdownButtonFormField<int>(
                      initialValue: _customBeatValue,
                      isDense: true,
                      decoration: const InputDecoration(
                        labelText: 'Beat unit',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final v in _beatValues)
                          DropdownMenuItem(value: v, child: Text('$v')),
                      ],
                      onChanged: (v) =>
                          setState(() => _customBeatValue = v ?? 4),
                    ),
                  ),
                ],
              ),
              if (!_isValid)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Enter 1 to 32 beats',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isValid
              ? () => Navigator.pop(
                    context,
                    _NewScoreSpec(_titleCtrl.text, _instrument, _timeSignature),
                  )
              : null,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
