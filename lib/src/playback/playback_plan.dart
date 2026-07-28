import 'dart:collection';
import 'dart:math' as math;

import '../../core/chord.dart';
import '../../core/musical_element.dart';
import '../../core/note.dart';
import '../../core/rest.dart';
import '../../core/score.dart';
import '../../core/space.dart';
import '../../core/tuplet.dart';
import '../../core/voice.dart';
import '../document/notemus_document.dart';
import '../midi/midi_mapper.dart';
import '../midi/midi_models.dart';
import 'score_playback_timeline.dart';

class PlaybackTempoChange {
  const PlaybackTempoChange({
    required this.tick,
    required this.bpm,
    required this.elapsed,
  });

  final int tick;
  final int bpm;
  final Duration elapsed;
}

class PlaybackMeasureOccurrence {
  const PlaybackMeasureOccurrence({
    required this.id,
    required this.occurrenceIndex,
    required this.sourceMeasureIndex,
    required this.measureNumber,
    required this.repeatPass,
    required this.startTick,
    required this.endTick,
    required this.start,
    required this.end,
    required this.sourceMeasureIds,
  });

  final String id;
  final int occurrenceIndex;
  final int sourceMeasureIndex;
  final int measureNumber;
  final int repeatPass;
  final int startTick;
  final int endTick;
  final Duration start;
  final Duration end;
  final List<String> sourceMeasureIds;

  int get durationTicks => endTick - startTick;
  Duration get duration => end - start;
}

/// One rendered source note at one repeat-expanded playback occurrence.
class PlaybackNoteOccurrence {
  const PlaybackNoteOccurrence({
    required this.id,
    required this.sourceNoteId,
    required this.measureOccurrenceId,
    required this.measureOccurrenceIndex,
    required this.staffIndex,
    required this.voiceNumber,
    required this.midiNote,
    required this.startTick,
    required this.endTick,
    required this.start,
    required this.end,
  });

  final String id;
  final String sourceNoteId;
  final String measureOccurrenceId;
  final int measureOccurrenceIndex;
  final int staffIndex;
  final int voiceNumber;
  final int midiNote;
  final int startTick;
  final int endTick;
  final Duration start;
  final Duration end;
}

/// A sounding MIDI note, ready for sample or synthesizer scheduling.
class PlaybackNoteEvent {
  const PlaybackNoteEvent({
    required this.staffIndex,
    required this.channel,
    required this.midiNote,
    required this.velocity,
    required this.startTick,
    required this.endTick,
    required this.start,
    required this.end,
    this.sourceNoteId,
    this.voiceNumber,
  });

  final int staffIndex;
  final int channel;
  final int midiNote;
  final int velocity;
  final int startTick;
  final int endTick;
  final Duration start;
  final Duration end;
  final String? sourceNoteId;
  final int? voiceNumber;

  Duration get duration => end - start;
}

class PlaybackPosition {
  const PlaybackPosition({
    required this.tick,
    required this.elapsed,
    required this.measure,
    required this.beat,
    required this.progress,
  });

  final int tick;
  final Duration elapsed;
  final PlaybackMeasureOccurrence measure;

  /// One-based quarter-note beat within [measure].
  final double beat;

  final double progress;
}

/// Immutable transport data derived once from the canonical score.
///
/// Rendering, seeking, playhead movement, mixer scheduling, and MIDI export can
/// all consume this object without independently interpreting MusicXML timing.
class PlaybackPlan {
  PlaybackPlan._({
    required this.sequence,
    required this.measures,
    required this.tempoChanges,
    required this.noteOccurrences,
    required this.noteEvents,
    required this.totalTicks,
    required this.duration,
    required this.warnings,
    required _TempoMap tempoMap,
  }) : _tempoMap = tempoMap;

  factory PlaybackPlan.fromDocument(
    NotemusDocument document, {
    MidiGenerationOptions options = const MidiGenerationOptions(),
  }) {
    return PlaybackPlan._build(
      document.score,
      document: document,
      options: options,
    );
  }

  factory PlaybackPlan.fromScore(
    Score score, {
    MidiGenerationOptions options = const MidiGenerationOptions(),
  }) {
    return PlaybackPlan._build(score, options: options);
  }

  factory PlaybackPlan._build(
    Score score, {
    NotemusDocument? document,
    required MidiGenerationOptions options,
  }) {
    final timeline = ScorePlaybackTimeline.fromScore(
      score,
      ticksPerQuarter: options.ticksPerQuarter,
      repeatDefaultTimes: options.repeatDefaultTimes,
      maxRepeatCycles: options.maxRepeatCycles,
    );
    final sequence = MidiMapper.fromScore(score, options: options);
    final tempoMap = _TempoMap.fromSequence(
      sequence,
      fallbackBpm: options.defaultBpm,
    );
    final measures = <PlaybackMeasureOccurrence>[
      for (
        var occurrenceIndex = 0;
        occurrenceIndex < timeline.occurrences.length;
        occurrenceIndex++
      )
        _toPublicMeasure(
          timeline.occurrences[occurrenceIndex],
          occurrenceIndex: occurrenceIndex,
          document: document,
          tempoMap: tempoMap,
        ),
    ];
    final noteOccurrences = _buildNoteOccurrences(
      score: score,
      document: document,
      measures: measures,
      options: options,
      tempoMap: tempoMap,
    );
    final noteEvents = _buildNoteEvents(
      sequence,
      noteOccurrences: noteOccurrences,
      tempoMap: tempoMap,
      staffCount: score.staffCount,
    );
    final totalTicks = math.max(timeline.totalTicks, sequence.totalTicks);

    return PlaybackPlan._(
      sequence: sequence,
      measures: List.unmodifiable(measures),
      tempoChanges: tempoMap.publicChanges,
      noteOccurrences: List.unmodifiable(noteOccurrences),
      noteEvents: List.unmodifiable(noteEvents),
      totalTicks: totalTicks,
      duration: tempoMap.durationAtTick(totalTicks),
      warnings: List.unmodifiable({...timeline.warnings, ...sequence.warnings}),
      tempoMap: tempoMap,
    );
  }

  final MidiSequence sequence;
  final List<PlaybackMeasureOccurrence> measures;
  final List<PlaybackTempoChange> tempoChanges;
  final List<PlaybackNoteOccurrence> noteOccurrences;
  final List<PlaybackNoteEvent> noteEvents;
  final int totalTicks;
  final Duration duration;
  final List<String> warnings;
  final _TempoMap _tempoMap;

  Duration durationAtTick(int tick) {
    return _tempoMap.durationAtTick(tick.clamp(0, totalTicks).toInt());
  }

  int tickAt(Duration elapsed) {
    return _tempoMap.tickAt(elapsed).clamp(0, totalTicks).toInt();
  }

  PlaybackPosition? positionAt(Duration elapsed) {
    if (measures.isEmpty) return null;
    final clamped = elapsed < Duration.zero
        ? Duration.zero
        : elapsed > duration
        ? duration
        : elapsed;
    final tick = tickAt(clamped);
    final measure = _measureAtTick(tick);
    final beat = 1.0 + (tick - measure.startTick) / sequence.ticksPerQuarter;
    return PlaybackPosition(
      tick: tick,
      elapsed: clamped,
      measure: measure,
      beat: beat
          .clamp(1.0, 1.0 + measure.durationTicks / sequence.ticksPerQuarter)
          .toDouble(),
      progress: duration == Duration.zero
          ? 0
          : clamped.inMicroseconds / duration.inMicroseconds,
    );
  }

  List<PlaybackMeasureOccurrence> occurrencesForMeasure(
    int sourceMeasureIndex,
  ) {
    return List.unmodifiable(
      measures.where(
        (measure) => measure.sourceMeasureIndex == sourceMeasureIndex,
      ),
    );
  }

  Duration? timeForMeasure(int sourceMeasureIndex, {int occurrence = 0}) {
    final matches = occurrencesForMeasure(sourceMeasureIndex);
    return occurrence >= 0 && occurrence < matches.length
        ? matches[occurrence].start
        : null;
  }

  int firstNoteEventIndexAtOrAfter(Duration elapsed) {
    var low = 0;
    var high = noteEvents.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (noteEvents[middle].start < elapsed) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  PlaybackMeasureOccurrence _measureAtTick(int tick) {
    var low = 0;
    var high = measures.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final measure = measures[middle];
      if (tick < measure.startTick) {
        high = middle - 1;
      } else if (tick >= measure.endTick && middle < measures.length - 1) {
        low = middle + 1;
      } else {
        return measure;
      }
    }
    return measures.last;
  }
}

PlaybackMeasureOccurrence _toPublicMeasure(
  ScorePlaybackMeasureOccurrence source, {
  required int occurrenceIndex,
  required NotemusDocument? document,
  required _TempoMap tempoMap,
}) {
  final id =
      'measure-${source.sourceMeasureIndex + 1}:'
      'pass-${source.repeatPass}:occurrence-${occurrenceIndex + 1}';
  final sourceMeasureIds = document == null
      ? const <String>[]
      : [
          for (final reference in document.measures)
            if (reference.measureIndex == source.sourceMeasureIndex)
              reference.id,
        ];
  return PlaybackMeasureOccurrence(
    id: id,
    occurrenceIndex: occurrenceIndex,
    sourceMeasureIndex: source.sourceMeasureIndex,
    measureNumber: source.measureNumber,
    repeatPass: source.repeatPass,
    startTick: source.startTick,
    endTick: source.endTick,
    start: tempoMap.durationAtTick(source.startTick),
    end: tempoMap.durationAtTick(source.endTick),
    sourceMeasureIds: List.unmodifiable(sourceMeasureIds),
  );
}

List<PlaybackNoteOccurrence> _buildNoteOccurrences({
  required Score score,
  required NotemusDocument? document,
  required List<PlaybackMeasureOccurrence> measures,
  required MidiGenerationOptions options,
  required _TempoMap tempoMap,
}) {
  if (document == null) return const [];

  final result = <PlaybackNoteOccurrence>[];
  final staves = score.allStaves;
  for (final occurrence in measures) {
    for (var staffIndex = 0; staffIndex < staves.length; staffIndex++) {
      final staff = staves[staffIndex];
      if (occurrence.sourceMeasureIndex >= staff.measures.length) continue;
      final measure = staff.measures[occurrence.sourceMeasureIndex];

      void appendElements(
        List<MusicalElement> elements, {
        required int voiceNumber,
      }) {
        var localTick = occurrence.startTick;

        int visit(MusicalElement element, double multiplier) {
          if (element is Note) {
            final writtenTicks = _durationTicks(
              element.duration.realValue,
              multiplier: multiplier,
              ticksPerQuarter: options.ticksPerQuarter,
            );
            final noteRef = document.noteRef(element);
            if (noteRef != null) {
              final graceTicks = element.isGraceNote
                  ? math.max(
                      1,
                      (writtenTicks * options.graceDurationScale).round(),
                    )
                  : writtenTicks;
              final startTick = element.isGraceNote
                  ? math.max(occurrence.startTick, localTick - graceTicks)
                  : localTick;
              final endTick = startTick + graceTicks;
              result.add(
                PlaybackNoteOccurrence(
                  id:
                      '${occurrence.id}:'
                      '${noteRef.id}:note-occurrence-${result.length + 1}',
                  sourceNoteId: noteRef.id,
                  measureOccurrenceId: occurrence.id,
                  measureOccurrenceIndex: occurrence.occurrenceIndex,
                  staffIndex: staffIndex,
                  voiceNumber: voiceNumber,
                  midiNote: element.pitch.midiNumber.clamp(0, 127),
                  startTick: startTick,
                  endTick: endTick,
                  start: tempoMap.durationAtTick(startTick),
                  end: tempoMap.durationAtTick(endTick),
                ),
              );
            }
            return element.isGraceNote ? 0 : writtenTicks;
          }
          if (element is Chord) {
            final ticks = _durationTicks(
              element.duration.realValue,
              multiplier: multiplier,
              ticksPerQuarter: options.ticksPerQuarter,
            );
            for (final note in element.notes) {
              final noteRef = document.noteRef(note);
              if (noteRef == null) continue;
              result.add(
                PlaybackNoteOccurrence(
                  id:
                      '${occurrence.id}:'
                      '${noteRef.id}:note-occurrence-${result.length + 1}',
                  sourceNoteId: noteRef.id,
                  measureOccurrenceId: occurrence.id,
                  measureOccurrenceIndex: occurrence.occurrenceIndex,
                  staffIndex: staffIndex,
                  voiceNumber: voiceNumber,
                  midiNote: note.pitch.midiNumber.clamp(0, 127),
                  startTick: localTick,
                  endTick: localTick + ticks,
                  start: tempoMap.durationAtTick(localTick),
                  end: tempoMap.durationAtTick(localTick + ticks),
                ),
              );
            }
            return ticks;
          }
          if (element is Rest) {
            return _durationTicks(
              element.duration.realValue,
              multiplier: multiplier,
              ticksPerQuarter: options.ticksPerQuarter,
            );
          }
          if (element is Space) {
            return _durationTicks(
              element.musicalValue,
              multiplier: multiplier,
              ticksPerQuarter: options.ticksPerQuarter,
            );
          }
          if (element is Tuplet) {
            final tupletMultiplier = multiplier * element.ratio.modifier;
            for (final child in element.elements) {
              final childTicks = visit(child, tupletMultiplier);
              localTick += childTicks;
            }
            return 0;
          }
          return 0;
        }

        for (final element in elements) {
          localTick += visit(element, 1.0);
        }
      }

      if (measure is MultiVoiceMeasure) {
        appendElements(measure.elements, voiceNumber: 1);
        for (final voice in measure.sortedVoices) {
          appendElements(voice.elements, voiceNumber: voice.number);
        }
      } else {
        appendElements(measure.elements, voiceNumber: 1);
      }
    }
  }
  result.sort((a, b) {
    final tick = a.startTick.compareTo(b.startTick);
    if (tick != 0) return tick;
    final staff = a.staffIndex.compareTo(b.staffIndex);
    if (staff != 0) return staff;
    return a.voiceNumber.compareTo(b.voiceNumber);
  });
  return result;
}

int _durationTicks(
  double wholeNoteValue, {
  required double multiplier,
  required int ticksPerQuarter,
}) {
  return math.max(
    1,
    (wholeNoteValue * 4.0 * multiplier * ticksPerQuarter).round(),
  );
}

List<PlaybackNoteEvent> _buildNoteEvents(
  MidiSequence sequence, {
  required List<PlaybackNoteOccurrence> noteOccurrences,
  required _TempoMap tempoMap,
  required int staffCount,
}) {
  final anchorsByKey = <(int, int, int), Queue<PlaybackNoteOccurrence>>{};
  for (final occurrence in noteOccurrences) {
    anchorsByKey
        .putIfAbsent((
          occurrence.staffIndex,
          occurrence.midiNote,
          occurrence.startTick,
        ), Queue.new)
        .add(occurrence);
  }

  final result = <PlaybackNoteEvent>[];
  for (var staffIndex = 0; staffIndex < staffCount; staffIndex++) {
    final trackIndex = staffIndex + 1;
    if (trackIndex >= sequence.tracks.length) break;
    final track = sequence.tracks[trackIndex];
    final pending = <(int, int), Queue<MidiEvent>>{};

    void close(MidiEvent event) {
      final note = event.note;
      if (note == null) return;
      final starts = pending[(event.channel, note)];
      if (starts == null || starts.isEmpty) return;
      final startEvent = starts.removeFirst();
      final endTick = math.max(startEvent.tick + 1, event.tick);
      final anchors = anchorsByKey[(staffIndex, note, startEvent.tick)];
      final anchor = anchors == null || anchors.isEmpty
          ? null
          : anchors.removeFirst();
      result.add(
        PlaybackNoteEvent(
          staffIndex: staffIndex,
          channel: startEvent.channel,
          midiNote: note,
          velocity: startEvent.velocity ?? 96,
          startTick: startEvent.tick,
          endTick: endTick,
          start: tempoMap.durationAtTick(startEvent.tick),
          end: tempoMap.durationAtTick(endTick),
          sourceNoteId: anchor?.sourceNoteId,
          voiceNumber: anchor?.voiceNumber,
        ),
      );
    }

    for (final event in track.events) {
      final note = event.note;
      if (note == null) continue;
      if (event.type == MidiEventType.noteOn && (event.velocity ?? 0) > 0) {
        pending.putIfAbsent((event.channel, note), Queue.new).add(event);
      } else if (event.type == MidiEventType.noteOff ||
          (event.type == MidiEventType.noteOn && (event.velocity ?? 0) == 0)) {
        close(event);
      }
    }
  }

  result.sort((a, b) {
    final start = a.startTick.compareTo(b.startTick);
    if (start != 0) return start;
    final staff = a.staffIndex.compareTo(b.staffIndex);
    if (staff != 0) return staff;
    return a.midiNote.compareTo(b.midiNote);
  });
  return result;
}

class _TempoMap {
  _TempoMap._(this._segments, this.publicChanges, this.ticksPerQuarter);

  factory _TempoMap.fromSequence(
    MidiSequence sequence, {
    required int fallbackBpm,
  }) {
    final byTick = <int, int>{0: fallbackBpm.clamp(1, 1000)};
    if (sequence.tracks.isNotEmpty) {
      for (final event in sequence.tracks.first.events) {
        if (event.type == MidiEventType.tempo &&
            event.bpm != null &&
            event.bpm! > 0) {
          byTick[event.tick] = event.bpm!;
        }
      }
    }

    final ticks = byTick.keys.toList()..sort();
    final segments = <_TempoSegment>[];
    final changes = <PlaybackTempoChange>[];
    var elapsedMicroseconds = 0.0;
    for (var index = 0; index < ticks.length; index++) {
      final tick = ticks[index];
      if (index > 0) {
        final previous = segments.last;
        elapsedMicroseconds +=
            (tick - previous.tick) *
            60000000.0 /
            (previous.bpm * sequence.ticksPerQuarter);
      }
      final bpm = byTick[tick]!;
      final elapsed = Duration(microseconds: elapsedMicroseconds.round());
      segments.add(
        _TempoSegment(
          tick: tick,
          bpm: bpm,
          elapsedMicroseconds: elapsedMicroseconds,
        ),
      );
      changes.add(PlaybackTempoChange(tick: tick, bpm: bpm, elapsed: elapsed));
    }
    return _TempoMap._(
      List.unmodifiable(segments),
      List.unmodifiable(changes),
      sequence.ticksPerQuarter,
    );
  }

  final List<_TempoSegment> _segments;
  final List<PlaybackTempoChange> publicChanges;
  final int ticksPerQuarter;

  Duration durationAtTick(int tick) {
    final segment = _segmentForTick(tick);
    final microseconds =
        segment.elapsedMicroseconds +
        (tick - segment.tick) * 60000000.0 / (segment.bpm * ticksPerQuarter);
    return Duration(microseconds: microseconds.round());
  }

  int tickAt(Duration elapsed) {
    final microseconds = math.max(0, elapsed.inMicroseconds);
    var segment = _segments.first;
    for (var index = 1; index < _segments.length; index++) {
      if (_segments[index].elapsedMicroseconds > microseconds) break;
      segment = _segments[index];
    }
    final delta =
        (microseconds - segment.elapsedMicroseconds) *
        segment.bpm *
        ticksPerQuarter /
        60000000.0;
    return segment.tick + delta.round();
  }

  _TempoSegment _segmentForTick(int tick) {
    var low = 0;
    var high = _segments.length - 1;
    while (low < high) {
      final middle = (low + high + 1) >> 1;
      if (_segments[middle].tick <= tick) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return _segments[low];
  }
}

class _TempoSegment {
  const _TempoSegment({
    required this.tick,
    required this.bpm,
    required this.elapsedMicroseconds,
  });

  final int tick;
  final int bpm;
  final double elapsedMicroseconds;
}
