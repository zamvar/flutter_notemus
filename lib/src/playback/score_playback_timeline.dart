import '../../core/barline.dart';
import '../../core/chord.dart';
import '../../core/measure.dart';
import '../../core/musical_element.dart';
import '../../core/note.dart';
import '../../core/repeat.dart';
import '../../core/rest.dart';
import '../../core/score.dart';
import '../../core/space.dart';
import '../../core/staff.dart';
import '../../core/time_signature.dart';
import '../../core/tuplet.dart';
import '../../core/volta_bracket.dart';
import '../../core/voice.dart';

class ScorePlaybackMeasureOccurrence {
  const ScorePlaybackMeasureOccurrence({
    required this.sourceMeasureIndex,
    required this.repeatPass,
    required this.startTick,
    required this.endTick,
    required this.measureNumber,
    required this.timeSignature,
  });

  final int sourceMeasureIndex;
  final int repeatPass;
  final int startTick;
  final int endTick;
  final int measureNumber;
  final TimeSignature? timeSignature;

  int get durationTicks => endTick - startTick;
}

/// Repeat-expanded, score-wide measure timing shared by MIDI and playback UI.
class ScorePlaybackTimeline {
  const ScorePlaybackTimeline._({
    required this.occurrences,
    required this.warnings,
    required this.totalTicks,
  });

  factory ScorePlaybackTimeline.fromStaff(
    Staff staff, {
    required int ticksPerQuarter,
    required int repeatDefaultTimes,
    required int maxRepeatCycles,
  }) {
    return ScorePlaybackTimeline.fromScore(
      Score.singleStaff(staff),
      ticksPerQuarter: ticksPerQuarter,
      repeatDefaultTimes: repeatDefaultTimes,
      maxRepeatCycles: maxRepeatCycles,
    );
  }

  factory ScorePlaybackTimeline.fromScore(
    Score score, {
    required int ticksPerQuarter,
    required int repeatDefaultTimes,
    required int maxRepeatCycles,
  }) {
    final staves = score.allStaves;
    if (staves.isEmpty) {
      return const ScorePlaybackTimeline._(
        occurrences: [],
        warnings: [],
        totalTicks: 0,
      );
    }

    final measureCount = staves.fold<int>(
      0,
      (maximum, staff) =>
          staff.measures.length > maximum ? staff.measures.length : maximum,
    );
    final warnings = <String>[];
    final order = _buildPlaybackOrder(
      staves,
      measureCount: measureCount,
      repeatDefaultTimes: repeatDefaultTimes,
      maxRepeatCycles: maxRepeatCycles,
      warnings: warnings,
    );
    final sourceTiming = _sourceMeasureTiming(staves, measureCount);
    final occurrences = <ScorePlaybackMeasureOccurrence>[];
    var cursor = 0;

    for (final reference in order) {
      final timing = sourceTiming[reference.measureIndex];
      final measureTicks = _measureLengthTicks(
        measures: _measuresAt(staves, reference.measureIndex),
        timeSignature: timing.timeSignature,
        ticksPerQuarter: ticksPerQuarter,
      );
      occurrences.add(
        ScorePlaybackMeasureOccurrence(
          sourceMeasureIndex: reference.measureIndex,
          repeatPass: reference.repeatPass,
          startTick: cursor,
          endTick: cursor + measureTicks,
          measureNumber: timing.measureNumber,
          timeSignature: timing.timeSignature,
        ),
      );
      cursor += measureTicks;
    }

    return ScorePlaybackTimeline._(
      occurrences: List.unmodifiable(occurrences),
      warnings: List.unmodifiable(warnings),
      totalTicks: cursor,
    );
  }

  final List<ScorePlaybackMeasureOccurrence> occurrences;
  final List<String> warnings;
  final int totalTicks;
}

class _PlaybackMeasureRef {
  const _PlaybackMeasureRef({
    required this.measureIndex,
    required this.repeatPass,
  });

  final int measureIndex;
  final int repeatPass;
}

class _RepeatSection {
  const _RepeatSection({
    required this.startMeasure,
    required this.endMeasure,
    required this.times,
  });

  final int startMeasure;
  final int endMeasure;
  final int times;
}

List<_PlaybackMeasureRef> _buildPlaybackOrder(
  List<Staff> staves, {
  required int measureCount,
  required int repeatDefaultTimes,
  required int maxRepeatCycles,
  required List<String> warnings,
}) {
  if (measureCount == 0) return const [];

  final sections = _detectRepeatSections(
    staves,
    measureCount: measureCount,
    repeatDefaultTimes: repeatDefaultTimes,
  );
  final sectionsByStart = <int, _RepeatSection>{
    for (final section in sections) section.startMeasure: section,
  };
  final order = <_PlaybackMeasureRef>[];
  var cursor = 0;

  while (cursor < measureCount) {
    final section = sectionsByStart[cursor];
    if (section == null) {
      order.add(_PlaybackMeasureRef(measureIndex: cursor, repeatPass: 1));
      cursor++;
      continue;
    }

    if (section.times > maxRepeatCycles) {
      warnings.add(
        'Repeat section at measure ${section.startMeasure + 1} capped at '
        '$maxRepeatCycles cycles.',
      );
    }
    final effectiveTimes = section.times.clamp(1, maxRepeatCycles);
    for (var pass = 1; pass <= effectiveTimes; pass++) {
      for (
        var measureIndex = section.startMeasure;
        measureIndex <= section.endMeasure;
        measureIndex++
      ) {
        if (_shouldPlayMeasureOnPass(staves, measureIndex, pass)) {
          order.add(
            _PlaybackMeasureRef(measureIndex: measureIndex, repeatPass: pass),
          );
        }
      }
    }
    cursor = section.endMeasure + 1;
  }

  return order;
}

List<_RepeatSection> _detectRepeatSections(
  List<Staff> staves, {
  required int measureCount,
  required int repeatDefaultTimes,
}) {
  final sections = <_RepeatSection>[];
  var currentStart = 0;

  for (var measureIndex = 0; measureIndex < measureCount; measureIndex++) {
    final measures = _measuresAt(staves, measureIndex);
    if (measures.any(_measureHasRepeatStart)) {
      currentStart = measureIndex;
    }
    if (!measures.any(_measureHasRepeatEnd)) continue;

    final explicitTimes = measures
        .map(_repeatTimes)
        .whereType<int>()
        .firstOrNull;
    final times = explicitTimes ?? repeatDefaultTimes;
    sections.add(
      _RepeatSection(
        startMeasure: currentStart,
        endMeasure: measureIndex,
        times: times <= 0 ? 1 : times,
      ),
    );
    currentStart = measureIndex + 1;
  }
  return sections;
}

bool _measureHasRepeatStart(Measure measure) {
  return measure.elements.any((element) {
    if (element is Barline) {
      return element.type == BarlineType.repeatForward ||
          element.type == BarlineType.repeatBoth;
    }
    return element is RepeatMark && element.type == RepeatType.start;
  });
}

bool _measureHasRepeatEnd(Measure measure) {
  return measure.elements.any((element) {
    if (element is Barline) {
      return element.type == BarlineType.repeatBackward ||
          element.type == BarlineType.repeatBoth;
    }
    return element is RepeatMark && element.type == RepeatType.end;
  });
}

int? _repeatTimes(Measure measure) {
  for (final element in measure.elements) {
    if (element is RepeatMark &&
        element.type == RepeatType.end &&
        element.times != null) {
      return element.times;
    }
  }
  return null;
}

bool _shouldPlayMeasureOnPass(List<Staff> staves, int measureIndex, int pass) {
  final voltaPasses = <int>{};
  for (final measure in _measuresAt(staves, measureIndex)) {
    voltaPasses.addAll(_extractVoltaPasses(measure));
  }
  return voltaPasses.isEmpty || voltaPasses.contains(pass);
}

Set<int> _extractVoltaPasses(Measure measure) {
  final result = <int>{};
  for (final element in measure.elements.whereType<VoltaBracket>()) {
    result.add(element.number);
    final label = element.label;
    if (label == null || label.trim().isEmpty) continue;

    final numbers = RegExp(r'\d+')
        .allMatches(label)
        .map((match) => int.tryParse(match.group(0) ?? ''))
        .whereType<int>()
        .toList();
    if (numbers.isEmpty) continue;
    if (label.contains('-') && numbers.length >= 2) {
      final minimum = numbers.reduce((a, b) => a < b ? a : b);
      final maximum = numbers.reduce((a, b) => a > b ? a : b);
      for (var value = minimum; value <= maximum; value++) {
        result.add(value);
      }
    } else {
      result.addAll(numbers);
    }
  }
  return result;
}

List<({int measureNumber, TimeSignature? timeSignature})> _sourceMeasureTiming(
  List<Staff> staves,
  int measureCount,
) {
  final result = <({int measureNumber, TimeSignature? timeSignature})>[];
  TimeSignature? activeTimeSignature;

  for (var measureIndex = 0; measureIndex < measureCount; measureIndex++) {
    final measures = _measuresAt(staves, measureIndex);
    final explicitTimeSignature = measures
        .map((measure) => measure.timeSignature)
        .whereType<TimeSignature>()
        .firstOrNull;
    activeTimeSignature = explicitTimeSignature ?? activeTimeSignature;
    final explicitNumber = measures
        .map((measure) => measure.number)
        .whereType<int>()
        .firstOrNull;
    result.add((
      measureNumber: explicitNumber ?? measureIndex + 1,
      timeSignature: activeTimeSignature,
    ));
  }
  return result;
}

List<Measure> _measuresAt(List<Staff> staves, int measureIndex) {
  return [
    for (final staff in staves)
      if (measureIndex < staff.measures.length) staff.measures[measureIndex],
  ];
}

int _measureLengthTicks({
  required List<Measure> measures,
  required TimeSignature? timeSignature,
  required int ticksPerQuarter,
}) {
  final sourceDuration = measures
      .map((measure) => measure.sourceDuration)
      .whereType<double>()
      .where((duration) => duration > 0)
      .fold<double>(
        0,
        (maximum, duration) => duration > maximum ? duration : maximum,
      );
  if (sourceDuration > 0) {
    return _positiveTicks(sourceDuration * 4.0, ticksPerQuarter);
  }

  final contentDuration = measures.fold<double>(0, (maximum, measure) {
    final duration = _measureLengthInQuarterNotes(measure);
    return duration > maximum ? duration : maximum;
  });
  final hasImplicitMeasure = measures.any((measure) => measure.isImplicit);
  if (hasImplicitMeasure && contentDuration > 0) {
    return _positiveTicks(contentDuration, ticksPerQuarter);
  }

  final nominalDuration = timeSignature == null
      ? 0.0
      : timeSignature.numerator * (4.0 / timeSignature.denominator);
  final duration = contentDuration > nominalDuration
      ? contentDuration
      : nominalDuration;
  return _positiveTicks(duration > 0 ? duration : 4.0, ticksPerQuarter);
}

int _positiveTicks(double quarterNotes, int ticksPerQuarter) {
  final ticks = (quarterNotes * ticksPerQuarter).round();
  return ticks <= 0 ? ticksPerQuarter : ticks;
}

double _measureLengthInQuarterNotes(Measure measure) {
  if (measure is MultiVoiceMeasure) {
    var maximum = 0.0;
    for (final voice in measure.sortedVoices) {
      final duration = _elementsLengthInQuarterNotes(voice.elements, 1.0);
      if (duration > maximum) maximum = duration;
    }
    if (maximum > 0) return maximum;
  }
  return _elementsLengthInQuarterNotes(measure.elements, 1.0);
}

double _elementsLengthInQuarterNotes(
  List<MusicalElement> elements,
  double tupletMultiplier,
) {
  var total = 0.0;
  for (final element in elements) {
    if (element is Note) {
      if (!element.isGraceNote) {
        total += element.duration.realValue * 4.0 * tupletMultiplier;
      }
    } else if (element is Rest) {
      total += element.duration.realValue * 4.0 * tupletMultiplier;
    } else if (element is Space) {
      total += element.musicalValue * 4.0 * tupletMultiplier;
    } else if (element is Chord) {
      total += element.duration.realValue * 4.0 * tupletMultiplier;
    } else if (element is Tuplet) {
      total += _elementsLengthInQuarterNotes(
        element.elements,
        tupletMultiplier * element.ratio.modifier,
      );
    }
  }
  return total;
}
