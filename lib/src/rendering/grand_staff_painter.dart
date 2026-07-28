// lib/src/rendering/grand_staff_painter.dart
//
import 'dart:math' as math;

// Multi-staff rendering for one or more [StaffGroup]s (grand staff, SATB, or a
// full multi-section score). Lays out each staff, aligns them on a shared
// horizontal grid (content start and barlines line up across all staves),
// stacks them vertically, wraps into stacked systems when the music is too wide
// for one line, and draws each group's brace/bracket plus continuous system
// barlines (and cross-staff beams).

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../layout/layout_engine.dart';
import '../smufl/smufl_metadata_loader.dart';
import '../theme/music_score_theme.dart';
import 'renderers/bracket_renderer.dart';
import 'staff_coordinate_system.dart';
import 'staff_position_calculator.dart';
import 'staff_renderer.dart';

/// Layout output for one staff in the group.
class _StaffLayout {
  final List<PositionedElement> elements;
  final LayoutEngine engine;
  _StaffLayout(this.elements, this.engine);
}

/// Musical position used by the rendered score playhead.
class ScorePlaybackPosition {
  /// MusicXML measure number, normally starting at 1.
  final int measureNumber;

  /// Zero-based source measure index from the canonical MusicXML document.
  /// This is more reliable than [measureNumber] when a score repeats numbers,
  /// starts with a pickup, or uses non-sequential labels.
  final int? sourceMeasureIndex;

  /// One-based beat within the measure.
  final double beat;

  const ScorePlaybackPosition({
    required this.measureNumber,
    required this.beat,
    this.sourceMeasureIndex,
  });
}

/// A tap on the horizontal space occupied by a rendered measure.
class ScoreMeasureTap {
  /// MusicXML measure number, or the one-based measure index when the source
  /// did not provide explicit numbers.
  final int measureNumber;

  /// Zero-based source measure index, preserved for scores with duplicate
  /// displayed measure numbers.
  final int? sourceMeasureIndex;

  /// Screen position of the tap, useful for contextual UI.
  final Offset globalPosition;

  const ScoreMeasureTap({
    required this.measureNumber,
    required this.globalPosition,
    this.sourceMeasureIndex,
  });
}

class _PlayheadPlacement {
  final int systemIndex;
  final double x;

  const _PlayheadPlacement({required this.systemIndex, required this.x});
}

class _RhythmicAnchor {
  final double beat;
  final double x;

  const _RhythmicAnchor({required this.beat, required this.x});
}

/// Renders one or more [StaffGroup]s as a unified, vertically-stacked,
/// horizontally-aligned system (a grand staff, an SATB choir, or a full
/// multi-section score). All staves across all groups share one horizontal
/// grid; each group carries its own brace/bracket.
class GrandStaffPainter extends CustomPainter {
  /// The staff groups, top to bottom. A single group is the common grand-staff
  /// case; multiple groups form an orchestral/ensemble score.
  final List<StaffGroup> groups;
  final double staffSpace;
  final SmuflMetadata metadata;
  final MusicScoreTheme theme;
  final double availableWidth;
  final ({int start, int end})? measureRange;
  final bool wrapSystems;
  final bool fitSystemsToWidth;

  /// Baseline-to-baseline vertical distance between adjacent staves.
  final double staffGap;

  /// One aligned list of per-staff layouts per system (the group wraps into
  /// systems when it doesn't fit on one line; every staff breaks at the same
  /// measures so barlines line up).
  late final List<List<_StaffLayout>> _systems;
  late final List<double> _systemScales;
  late final List<double> _systemNaturalWidths;

  /// Inclusive source-measure ranges used for each rendered system.
  ///
  /// Consumers that paginate a score can use these ranges to keep the same
  /// line breaks as the painter instead of guessing how many measures fit.
  late final List<({int start, int end})> _systemRanges;

  List<({int start, int end})> get systemRanges =>
      List.unmodifiable(_systemRanges);

  int get systemCount => _systems.length;
  double get bracePadding => _bracePad;
  double get totalWidth {
    if (fitSystemsToWidth) return availableWidth;
    final naturalWidth = _systemNaturalWidths.fold<double>(
      0,
      (maximum, width) => math.max(maximum, width),
    );
    return math.max(availableWidth, naturalWidth);
  }

  double systemScaleAt(int index) => _systemScales[index];

  Rect systemBounds(int index) {
    assert(index >= 0 && index < systemCount);
    return Rect.fromLTWH(
      0,
      index * systemBlockHeight,
      totalWidth,
      systemBlockHeight + (index == systemCount - 1 ? staffSpace * 2.0 : 0),
    );
  }

  double heightForSystemRange(int firstSystem, int lastSystem) {
    if (systemCount == 0) return 0;
    final first = firstSystem.clamp(0, systemCount - 1);
    final last = lastSystem.clamp(first, systemCount - 1);
    return (last - first + 1) * systemBlockHeight + staffSpace * 2.0;
  }

  /// Source notes represented by the current layout.
  ///
  /// This supports conservation tests while the public immutable score-layout
  /// API is being introduced.
  @visibleForTesting
  Set<Note> get debugRenderedNotes {
    final notes = Set<Note>.identity();
    for (final system in _systems) {
      for (final layout in system) {
        for (final positioned in layout.elements) {
          for (final candidate in _positionedNotes(
            positioned.element,
            positioned.position.dx,
          )) {
            notes.add(candidate.note);
          }
        }
      }
    }
    return Set<Note>.unmodifiable(notes);
  }

  /// Positioned elements grouped by system and staff for geometry regression
  /// tests. The returned lists are snapshots and do not expose mutable layout
  /// state.
  @visibleForTesting
  List<List<List<PositionedElement>>> get debugPositionedElements => [
    for (final system in _systems)
      [
        for (final staff in system)
          List<PositionedElement>.unmodifiable(staff.elements),
      ],
  ];

  /// Left padding reserved for the brace/bracket (and group name).
  late final double _bracePad;

  /// All staves across all groups, top to bottom.
  late final List<Staff> _allStaves;
  late final Map<int, int> _measureIndicesByNumber;
  late final bool _hasExplicitMeasureNumbers;

  /// Total painted height (all systems stacked).
  double get totalHeight =>
      _systems.length * systemBlockHeight + staffSpace * 2.0;

  /// Baseline-to-baseline distance between the tops of consecutive systems.
  double get systemBlockHeight =>
      (_allStaves.length - 1) * staffGap +
      staffSpace * 4.0 + // bottom staff lower half + margin
      staffSpace * 6.0; // inter-system gap

  GrandStaffPainter({
    StaffGroup? staffGroup,
    List<StaffGroup>? groups,
    required this.staffSpace,
    required this.metadata,
    required this.theme,
    required this.availableWidth,
    this.measureRange,
    this.wrapSystems = true,
    this.fitSystemsToWidth = true,
    double? staffGap,
  }) : assert(
         staffGroup != null || groups != null,
         'Provide either staffGroup or groups',
       ),
       groups = groups ?? [staffGroup!],
       staffGap = staffGap ?? staffSpace * 11.0 {
    _allStaves = [for (final g in this.groups) ...g.staves];
    final measureIndicesByNumber = <int, int>{};
    var hasExplicitMeasureNumbers = false;
    for (final staff in _allStaves) {
      for (var index = 0; index < staff.measures.length; index++) {
        final number = staff.measures[index].number;
        if (number == null) continue;
        hasExplicitMeasureNumbers = true;
        measureIndicesByNumber.putIfAbsent(number, () => index);
      }
    }
    _measureIndicesByNumber = measureIndicesByNumber;
    _hasExplicitMeasureNumbers = hasExplicitMeasureNumbers;
    _bracePad = _calculateBracePad();
    final requestedRange = measureRange;
    if (requestedRange == null && wrapSystems) {
      _systemRanges = _computeSystemRanges();
    } else if (requestedRange == null) {
      final measureCount = _allStaves
          .map((staff) => staff.measures.length)
          .fold<int>(0, math.max);
      _systemRanges = measureCount == 0
          ? const []
          : [(start: 0, end: measureCount - 1)];
    } else {
      final measureCount = _allStaves
          .map((staff) => staff.measures.length)
          .fold<int>(0, math.max);
      if (measureCount == 0) {
        _systemRanges = const [];
      } else {
        final start = requestedRange.start.clamp(0, measureCount - 1);
        final end = requestedRange.end.clamp(start, measureCount - 1);
        _systemRanges = [(start: start, end: end)];
      }
    }
    _systems = [
      for (final range in _systemRanges) _layoutSystem(range.start, range.end),
    ];
    _systemNaturalWidths = _calculateSystemNaturalWidths();
    _systemScales = _calculateSystemScales();
  }

  /// Lays out + aligns one system's measures (inclusive [a]..[b]) across staves.
  List<_StaffLayout> _layoutSystem(int a, int b) {
    final layouts = <_StaffLayout>[];
    for (final staff in _allStaves) {
      final slice = _systemStaff(staff, a, b);
      layouts.add(
        _layoutSubStaff(
          slice.staff,
          initialSystemElements: slice.initialSystemElements,
          initialTimeSignature: slice.initialTimeSignature,
        ),
      );
    }
    _alignStaves(layouts);
    return layouts;
  }

  _StaffLayout _layoutSubStaff(
    Staff staff, {
    required List<MusicalElement> initialSystemElements,
    required TimeSignature? initialTimeSignature,
  }) {
    final engine = LayoutEngine(
      staff,
      // Very wide so a system never wraps internally — breaks are decided here.
      availableWidth: (availableWidth - _bracePad) * 1000,
      staffSpace: staffSpace,
      metadata: metadata,
      initialSystemElements: initialSystemElements,
      initialTimeSignature: initialTimeSignature,
    );
    final result = engine.layoutWithSignature();
    return _StaffLayout(result.elements, engine);
  }

  /// Builds a sub-[Staff] holding measures [a]..[b] of [staff]; for a system
  /// that doesn't start the piece, the prevailing clef and key are restated at
  /// the start (Gould/Verovio).
  ({
    Staff staff,
    List<MusicalElement> initialSystemElements,
    TimeSignature? initialTimeSignature,
  })
  _systemStaff(Staff staff, int a, int b) {
    Clef? clef;
    KeySignature? key;
    TimeSignature? timeSignature;
    for (var i = 0; i < a && i < staff.measures.length; i++) {
      for (final e in _allElements(staff.measures[i])) {
        if (e is Clef) clef = e;
        if (e is KeySignature) key = e;
        if (e is TimeSignature) timeSignature = e;
      }
    }
    if (staff.measures.isEmpty || a >= staff.measures.length) {
      return (
        staff: Staff(
          lineCount: staff.lineCount,
          name: staff.name,
          abbreviation: staff.abbreviation,
        ),
        initialSystemElements: const [],
        initialTimeSignature: timeSignature,
      );
    }

    final end = math.min(b + 1, staff.measures.length);
    final measures = staff.measures.sublist(a, end);
    final firstElements = _allElements(measures.first).toList();
    final initialSystemElements = <MusicalElement>[
      if (a > 0 &&
          !firstElements.any((element) => element is Clef) &&
          clef != null)
        clef,
      if (a > 0 &&
          !firstElements.any((element) => element is KeySignature) &&
          key != null &&
          key.count != 0)
        key,
    ];

    return (
      staff: Staff(
        measures: measures,
        lineCount: staff.lineCount,
        name: staff.name,
        abbreviation: staff.abbreviation,
      ),
      initialSystemElements: initialSystemElements,
      initialTimeSignature: timeSignature,
    );
  }

  Iterable<MusicalElement> _allElements(Measure measure) sync* {
    yield* measure.elements;
    if (measure is MultiVoiceMeasure) {
      for (final voice in measure.sortedVoices) {
        yield* voice.elements;
      }
    }
  }

  double _calculateBracePad() {
    var width = staffSpace * 2.2;
    for (final staff in _allStaves) {
      final label = staff.name;
      if (label == null || label.isEmpty) continue;
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(fontSize: staffSpace * 1.1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      width = math.max(width, painter.width + staffSpace * 1.2);
    }
    return width;
  }

  /// Per-measure widths laid out unwrapped, used to decide shared breaks.
  List<double> _measureWidths(Staff staff) {
    final engine = LayoutEngine(
      staff,
      availableWidth: 1000000,
      staffSpace: staffSpace,
      metadata: metadata,
    );
    final els = engine.layout();
    final widths = <double>[];
    var prev = 0.0;
    for (final pe in els) {
      if (pe.element is Barline) {
        widths.add(pe.position.dx - prev);
        prev = pe.position.dx;
      }
    }
    return widths;
  }

  /// Greedy system breaks shared by all staves: pack measures (by their widest
  /// per-staff width) into lines no wider than the usable width.
  List<({int start, int end})> _computeSystemRanges() {
    final nMeasures = _allStaves
        .map((s) => s.measures.length)
        .fold<int>(0, (a, b) => a > b ? a : b);
    if (nMeasures == 0) return const [];

    final widths = List<double>.filled(nMeasures, 0);
    for (final staff in _allStaves) {
      final w = _measureWidths(staff);
      for (var i = 0; i < w.length && i < nMeasures; i++) {
        if (w[i] > widths[i]) widths[i] = w[i];
      }
    }

    final usable = math.max(1.0, (availableWidth - _bracePad) - staffSpace);
    final lead = staffSpace * 4.0; // restated clef+key allowance per new system
    // Choose breaks from the scale the line would actually need. This keeps
    // the decision responsive to page width and measure density, instead of
    // making six measures fit by shrinking the whole system excessively.
    const minimumReadableScale = 0.72;
    final ranges = <({int start, int end})>[];
    var start = 0;
    var running = 0.0;
    for (var i = 0; i < nMeasures; i++) {
      final w = widths[i];
      final candidateWidth = running + w;
      final candidateScale = usable / math.max(usable, candidateWidth);
      if (i > start && candidateScale < minimumReadableScale) {
        ranges.add((start: start, end: i - 1));
        start = i;
        running = lead + w;
      } else {
        running += w + (i == start && start > 0 ? lead : 0);
      }
    }
    ranges.add((start: start, end: nMeasures - 1));
    return ranges;
  }

  List<double> _calculateSystemNaturalWidths() {
    return [
      for (final system in _systems)
        () {
          var requiredWidth = 0.0;
          for (final layout in system) {
            for (final element in layout.elements) {
              requiredWidth = math.max(requiredWidth, element.position.dx);
            }
          }
          return _bracePad + requiredWidth + staffSpace * 2.0;
        }(),
    ];
  }

  List<double> _calculateSystemScales() {
    if (!fitSystemsToWidth) {
      return List<double>.filled(_systems.length, 1.0);
    }
    final usable = math.max(1.0, availableWidth - _bracePad);
    return [
      for (final naturalWidth in _systemNaturalWidths)
        math.min(1.0, usable / math.max(usable, naturalWidth - _bracePad)),
    ];
  }

  // --- Horizontal alignment -------------------------------------------------

  /// Per-staff anchor X positions: the system left margin, the content-start
  /// (first note/rest/chord) and each barline X. Returns the anchors and the
  /// indices into [elements] that mark each barline.
  List<double> _anchorsOf(List<PositionedElement> elements) {
    final anchors = <double>[];
    double? contentStart;
    for (final pe in elements) {
      final e = pe.element;
      if (contentStart == null && (e is Note || e is Rest || e is Chord)) {
        contentStart = pe.position.dx;
      }
      if (e is Barline) {
        anchors.add(pe.position.dx);
      }
    }
    // anchors currently = barline Xs; prepend content start.
    return [contentStart ?? 0.0, ...anchors];
  }

  /// Aligns every staff so their content-start and barlines share the same X
  /// (the maximum across staves), remapping each staff's elements with a
  /// piecewise-linear map between the per-staff and shared anchors.
  void _alignStaves(List<_StaffLayout> layouts) {
    if (layouts.isEmpty) return;

    final perStaffAnchors = [for (final l in layouts) _anchorsOf(l.elements)];
    // Number of shared anchors = min across staves (align the common prefix).
    var anchorCount = perStaffAnchors.first.length;
    for (final a in perStaffAnchors) {
      if (a.length < anchorCount) anchorCount = a.length;
    }
    if (anchorCount == 0) return;

    // Shared anchor = max across staves at each index (widest wins → no clash).
    final shared = <double>[];
    for (var k = 0; k < anchorCount; k++) {
      var maxX = perStaffAnchors.first[k];
      for (final a in perStaffAnchors) {
        if (a[k] > maxX) maxX = a[k];
      }
      shared.add(maxX);
    }

    // Remap each staff's element X by piecewise-linear interpolation between
    // its own anchors and the shared anchors. The first segment is from the
    // system left margin (constant) to the first anchor.
    const double leftMargin = 0.0; // both spaces share the same left origin
    for (var s = 0; s < layouts.length; s++) {
      final anchors = perStaffAnchors[s];
      double remap(double x) {
        // Segment 0: [leftMargin, anchors[0]] -> [leftMargin, shared[0]].
        if (x <= anchors[0]) {
          final lo = leftMargin, hi = anchors[0];
          final sLo = leftMargin, sHi = shared[0];
          if (hi - lo < 1e-6) return sLo;
          return sLo + (x - lo) / (hi - lo) * (sHi - sLo);
        }
        for (var k = 0; k < anchorCount - 1; k++) {
          if (x <= anchors[k + 1]) {
            final lo = anchors[k], hi = anchors[k + 1];
            final sLo = shared[k], sHi = shared[k + 1];
            if (hi - lo < 1e-6) return sLo;
            return sLo + (x - lo) / (hi - lo) * (sHi - sLo);
          }
        }
        // Beyond the last shared anchor: shift by the last anchor's delta.
        return x + (shared[anchorCount - 1] - anchors[anchorCount - 1]);
      }

      final remapped = <PositionedElement>[];
      for (final pe in layouts[s].elements) {
        final nx = remap(pe.position.dx);
        remapped.add(
          PositionedElement(
            pe.element,
            Offset(nx, pe.position.dy),
            system: pe.system,
            voiceNumber: pe.voiceNumber,
          ),
        );
        // Keep the engine's note-X map (used by beams) in sync.
        if (pe.element is Note) {
          layouts[s].engine.overrideNoteX(pe.element as Note, nx);
        }
      }
      layouts[s] = _StaffLayout(remapped, layouts[s].engine);
    }
  }

  // --- Painting -------------------------------------------------------------

  @override
  void paint(Canvas canvas, Size size) {
    paintSystemRange(canvas, size);
  }

  void paintSystemRange(
    Canvas canvas,
    Size size, {
    int firstSystem = 0,
    int? lastSystem,
  }) {
    if (metadata.isNotLoaded || _systems.isEmpty) return;
    final first = firstSystem.clamp(0, _systems.length - 1);
    final last = (lastSystem ?? _systems.length - 1).clamp(
      first,
      _systems.length - 1,
    );

    // Shift the whole system right to leave room for the brace/bracket.
    canvas.save();
    canvas.translate(_bracePad, 0);

    final baseline0 = staffSpace * 5.0;
    for (var sysIdx = first; sysIdx <= last; sysIdx++) {
      final layouts = _systems[sysIdx];
      if (layouts.isEmpty) continue;
      canvas.save();
      canvas.translate(0, (sysIdx - first) * systemBlockHeight);
      canvas.scale(_systemScales[sysIdx], 1.0);
      _paintSystem(canvas, size, layouts, baseline0, sysIdx);
      canvas.restore();
    }
    canvas.restore();
  }

  void _paintSystem(
    Canvas canvas,
    Size size,
    List<_StaffLayout> layouts,
    double baseline0,
    int systemIndex,
  ) {
    // Notes drawn by the cross-staff beam pass (skipped by their home staff).
    final skipPerStaff = [
      for (var i = 0; i < layouts.length; i++) _crossStaffNotesOf(layouts, i),
    ];

    for (var i = 0; i < layouts.length; i++) {
      canvas.save();
      canvas.translate(0, i * staffGap);
      final coords = StaffCoordinateSystem(
        staffSpace: staffSpace,
        staffBaseline: Offset(0, baseline0),
      );
      final renderer = StaffRenderer(
        coordinates: coords,
        metadata: metadata,
        theme: theme,
      );
      renderer.renderStaff(
        canvas,
        layouts[i].elements,
        size,
        layoutEngine: layouts[i].engine,
        // Barlines are drawn once across the whole system below, so the staves
        // don't draw their own (which would double up and not connect).
        renderBarlines: false,
        skipNotes: skipPerStaff[i],
      );
      canvas.restore();
    }

    _drawStaffLabels(canvas, baseline0, systemIndex);
    _drawMeasureNumber(canvas, baseline0, systemIndex);

    // Cross-staff beam groups, drawn after the staves so the beam sits between.
    _drawCrossStaffBeams(canvas, baseline0, layouts);

    // Vertical extent of the system: top line of the first staff to the bottom
    // line of the last staff (staff lines span 4 staff spaces around baseline).
    final topY = baseline0 - staffSpace * 2;
    final bottomY =
        (layouts.length - 1) * staffGap + baseline0 + staffSpace * 2;

    // Draw every barline once as a continuous line spanning the whole system,
    // so connected staves share unbroken barlines (and the final barline too).
    for (final bl in _systemBarlines(layouts)) {
      _drawSystemBarline(canvas, bl.x, bl.type, topY, bottomY);
    }

    // Each group carries its own brace/bracket, spanning only its own staves.
    final bracket = BracketRenderer(
      coordinates: StaffCoordinateSystem(
        staffSpace: staffSpace,
        staffBaseline: Offset(0, baseline0),
      ),
      theme: theme,
      metadata: metadata,
    );
    // Staff lines are drawn from x = 0 (the coordinate origin), so the
    // brace/bracket caps them there and extends left into the reserved _bracePad
    // margin (the whole system is already translated right by _bracePad).
    const leftX = 0.0;
    var staffIdx = 0;
    for (final g in groups) {
      final gTop = baseline0 + staffIdx * staffGap - staffSpace * 2;
      final gBottom =
          baseline0 +
          (staffIdx + g.staves.length - 1) * staffGap +
          staffSpace * 2;
      bracket.render(canvas, g, gTop, gBottom, leftX);
      staffIdx += g.staves.length;
    }

    // A system-start barline at the left edge joins every staff of the system
    // (the vertical line the brace/bracket caps) — present on any grand staff
    // or multi-staff system, not just multi-group scores.
    if (_allStaves.length > 1) {
      final paint = Paint()
        ..color = theme.barlineColor
        ..strokeWidth =
            metadata.getEngravingDefault('thinBarlineThickness', 0.16) *
            staffSpace;
      canvas.drawLine(Offset(leftX, topY), Offset(leftX, bottomY), paint);
    }
  }

  /// Paints only the playback cursor. This is intentionally separate from
  /// [paint] so clock ticks never repaint the full notation.
  void paintPlayhead(
    Canvas canvas,
    Size size,
    ScorePlaybackPosition? position,
  ) {
    paintPlayheadRange(canvas, size, position);
  }

  void paintPlayheadRange(
    Canvas canvas,
    Size size,
    ScorePlaybackPosition? position, {
    int firstSystem = 0,
    int? lastSystem,
  }) {
    if (metadata.isNotLoaded || _systems.isEmpty) return;
    final first = firstSystem.clamp(0, _systems.length - 1);
    final last = (lastSystem ?? _systems.length - 1).clamp(
      first,
      _systems.length - 1,
    );

    canvas.save();
    canvas.translate(_bracePad, 0);
    final baseline0 = staffSpace * 5.0;
    for (var systemIndex = first; systemIndex <= last; systemIndex++) {
      final placement = _playheadForSystem(systemIndex, position);
      if (placement == null) continue;

      final layouts = _systems[systemIndex];
      if (layouts.isEmpty) continue;
      canvas.save();
      canvas.translate(0, (systemIndex - first) * systemBlockHeight);
      canvas.scale(_systemScales[systemIndex], 1.0);
      final topY = baseline0 - staffSpace * 2;
      final bottomY =
          (layouts.length - 1) * staffGap + baseline0 + staffSpace * 2;
      final playheadPaint = Paint()
        ..color = theme.noteheadColor.withValues(alpha: 0.65)
        ..strokeWidth = math.max(1.0, staffSpace * 0.35);
      canvas.drawLine(
        Offset(placement.x, topY - staffSpace),
        Offset(placement.x, bottomY + staffSpace),
        playheadPaint,
      );
      canvas.restore();
    }
    canvas.restore();
  }

  bool hasPlayhead(
    ScorePlaybackPosition? position, {
    int firstSystem = 0,
    int? lastSystem,
  }) {
    if (position == null) return false;
    final measureIndex = _measureIndexForNumber(position.measureNumber);
    if (measureIndex == null) return false;
    if (_systemRanges.isEmpty) return false;
    final first = firstSystem.clamp(0, _systemRanges.length - 1);
    final last = (lastSystem ?? _systemRanges.length - 1).clamp(
      first,
      _systemRanges.length - 1,
    );
    for (var index = first; index <= last; index++) {
      final range = _systemRanges[index];
      if (measureIndex >= range.start && measureIndex <= range.end) return true;
    }
    return false;
  }

  /// Resolves a local canvas position to the measure under the tap.
  ///
  /// The hit test follows the same system scale and measure bounds used by
  /// painting, so it stays aligned when the layout wraps or compresses a
  /// system to fit the available width.
  int? measureAt(Offset position, {int firstSystem = 0, int? lastSystem}) {
    final index = measureIndexAt(
      position,
      firstSystem: firstSystem,
      lastSystem: lastSystem,
    );
    if (index == null || _allStaves.isEmpty) return null;
    return _allStaves.first.measures[index].number ?? index + 1;
  }

  int? measureIndexAt(Offset position, {int firstSystem = 0, int? lastSystem}) {
    if (_systems.isEmpty || _allStaves.isEmpty) return null;
    final first = firstSystem.clamp(0, _systems.length - 1);
    final last = (lastSystem ?? _systems.length - 1).clamp(
      first,
      _systems.length - 1,
    );

    for (var systemIndex = first; systemIndex <= last; systemIndex++) {
      final systemY = position.dy - (systemIndex - first) * systemBlockHeight;
      if (systemY < -staffSpace * 4.0 ||
          systemY > systemBlockHeight + staffSpace * 4.0) {
        continue;
      }

      final x = (position.dx - _bracePad) / _systemScales[systemIndex];
      final range = _systemRanges[systemIndex];
      final layouts = _systems[systemIndex];
      if (layouts.isEmpty) continue;

      final bounds = layouts.first.engine.measureBounds;
      for (
        var localMeasure = 0;
        localMeasure <= range.end - range.start;
        localMeasure++
      ) {
        final current = bounds[localMeasure];
        if (current == null) continue;

        final previous = localMeasure == 0 ? null : bounds[localMeasure - 1];
        final next = bounds[localMeasure + 1];
        final start = previous == null
            ? current.start - staffSpace * 4.0
            : (previous.end + current.start) / 2.0;
        final end = next == null
            ? current.end + staffSpace * 4.0
            : (current.end + next.start) / 2.0;
        if (x < start || x > end) continue;

        final measureIndex = range.start + localMeasure;
        if (measureIndex < 0 ||
            measureIndex >= _allStaves.first.measures.length) {
          return null;
        }
        return measureIndex;
      }
    }
    return null;
  }

  int? measureIndexForNumber(int number) => _measureIndexForNumber(number);

  int? systemIndexForMeasureIndex(int measureIndex) {
    final index = _systemRanges.indexWhere(
      (range) => measureIndex >= range.start && measureIndex <= range.end,
    );
    return index < 0 ? null : index;
  }

  Rect? measureBoundsForIndex(int measureIndex) {
    final systemIndex = systemIndexForMeasureIndex(measureIndex);
    if (systemIndex == null) return null;
    final range = _systemRanges[systemIndex];
    final layouts = _systems[systemIndex];
    if (layouts.isEmpty) return null;
    final localMeasure = measureIndex - range.start;
    final bounds = layouts.first.engine.measureBounds[localMeasure];
    if (bounds == null) return null;
    final scale = _systemScales[systemIndex];
    return Rect.fromLTRB(
      _bracePad + bounds.start * scale,
      systemIndex * systemBlockHeight,
      _bracePad + bounds.end * scale,
      (systemIndex + 1) * systemBlockHeight,
    );
  }

  Offset? playbackOffset(ScorePlaybackPosition? position) {
    if (position == null) return null;
    final measureIndex = _measureIndexForPosition(position);
    if (measureIndex == null) return null;
    final systemIndex = systemIndexForMeasureIndex(measureIndex);
    if (systemIndex == null) return null;
    final placement = _playheadForSystem(systemIndex, position);
    if (placement == null) return null;
    return Offset(
      _bracePad + placement.x * _systemScales[systemIndex],
      systemIndex * systemBlockHeight + systemBlockHeight / 2,
    );
  }

  _PlayheadPlacement? _playheadForSystem(
    int systemIndex,
    ScorePlaybackPosition? position,
  ) {
    if (position == null || systemIndex >= _systemRanges.length) return null;

    final measureIndex = _measureIndexForPosition(position);
    if (measureIndex == null) return null;
    final range = _systemRanges[systemIndex];
    if (measureIndex < range.start || measureIndex > range.end) return null;

    final layouts = _systems[systemIndex];
    if (layouts.isEmpty) return null;
    final localMeasure = measureIndex - range.start;
    final bounds = layouts.first.engine.measureBounds[localMeasure];
    if (bounds == null) return null;

    final measure = _allStaves.first.measures[measureIndex];
    final timeSignature =
        measure.timeSignature ?? measure.inheritedTimeSignature;
    // MusicXML's measureValue is whole-note relative (4/4 == 1.0), while
    // playback positions use quarter-note beats (4/4 == 4.0).
    final sourceBeats = measure.sourceDuration == null
        ? null
        : measure.sourceDuration! * 4.0;
    final measureBeats = sourceBeats != null && sourceBeats > 0
        ? sourceBeats
        : timeSignature == null
        ? 4.0
        : timeSignature.measureValue * 4.0;
    final targetBeat = (position.beat - 1.0).clamp(0.0, measureBeats);
    final anchors = _rhythmicAnchorsForMeasure(
      systemIndex: systemIndex,
      localMeasure: localMeasure,
      bounds: bounds,
    );
    final x = anchors.isEmpty
        ? _rhythmicStartForMeasure(layouts, bounds) +
              (bounds.end - _rhythmicStartForMeasure(layouts, bounds)) *
                  (targetBeat / measureBeats)
        : _interpolateRhythmicX(
            anchors,
            targetBeat,
            measureBeats: measureBeats,
            measureEnd: bounds.end,
          );
    return _PlayheadPlacement(systemIndex: systemIndex, x: x);
  }

  double _interpolateRhythmicX(
    List<_RhythmicAnchor> anchors,
    double targetBeat, {
    required double measureBeats,
    required double measureEnd,
  }) {
    final first = anchors.first;
    if (targetBeat <= first.beat) return first.x;
    for (var index = 1; index < anchors.length; index++) {
      final next = anchors[index];
      if (targetBeat > next.beat) continue;
      final previous = anchors[index - 1];
      final span = next.beat - previous.beat;
      if (span <= 0) return next.x;
      final fraction = ((targetBeat - previous.beat) / span)
          .clamp(0.0, 1.0)
          .toDouble();
      return previous.x + (next.x - previous.x) * fraction;
    }

    final last = anchors.last;
    final remaining = measureBeats - last.beat;
    if (remaining <= 0) return last.x;
    final fraction = ((targetBeat - last.beat) / remaining)
        .clamp(0.0, 1.0)
        .toDouble();
    return last.x + (measureEnd - last.x) * fraction;
  }

  List<_RhythmicAnchor> _rhythmicAnchorsForMeasure({
    required int systemIndex,
    required int localMeasure,
    required ({double start, double end}) bounds,
  }) {
    final range = _systemRanges[systemIndex];
    final sourceMeasureIndex = range.start + localMeasure;
    final anchors = <_RhythmicAnchor>[];
    final layouts = _systems[systemIndex];

    for (var staffIndex = 0; staffIndex < layouts.length; staffIndex++) {
      final staff = _allStaves[staffIndex];
      if (sourceMeasureIndex >= staff.measures.length) continue;
      final measure = staff.measures[sourceMeasureIndex];
      final streams = measure is MultiVoiceMeasure
          ? measure.sortedVoices.map((voice) => voice.elements)
          : [measure.elements];
      for (final stream in streams) {
        var beat = 0.0;
        for (final element in stream) {
          final positionedX = _positionedX(
            layouts[staffIndex].elements,
            element,
          );
          if (positionedX != null) {
            beat += _appendRhythmicAnchors(
              anchors,
              element,
              x: positionedX,
              beat: beat,
            );
          } else {
            beat += _rhythmicDurationInBeats(element);
          }
        }
      }
    }

    anchors.removeWhere(
      (anchor) =>
          anchor.x < bounds.start - staffSpace * 2 ||
          anchor.x > bounds.end + staffSpace * 2,
    );
    anchors.sort((a, b) {
      final beat = a.beat.compareTo(b.beat);
      return beat != 0 ? beat : a.x.compareTo(b.x);
    });
    return anchors;
  }

  double? _positionedX(
    List<PositionedElement> elements,
    MusicalElement element,
  ) {
    for (final positioned in elements) {
      if (identical(positioned.element, element)) return positioned.position.dx;
    }
    return null;
  }

  double _appendRhythmicAnchors(
    List<_RhythmicAnchor> anchors,
    MusicalElement element, {
    required double x,
    required double beat,
  }) {
    if (element is Tuplet) {
      var childBeat = beat;
      for (var index = 0; index < element.elements.length; index++) {
        final child = element.elements[index];
        _appendRhythmicAnchors(
          anchors,
          child,
          x: x + index * staffSpace * 2.5,
          beat: childBeat,
        );
        childBeat += _rhythmicDurationInBeats(child) * element.ratio.modifier;
      }
      return element.totalDuration * 4.0;
    }
    if (element is Note ||
        element is Rest ||
        element is Chord ||
        element is Space) {
      anchors.add(_RhythmicAnchor(beat: beat, x: x));
    }
    return _rhythmicDurationInBeats(element);
  }

  double _rhythmicDurationInBeats(MusicalElement element) {
    if (element is Note) return element.duration.realValue * 4.0;
    if (element is Rest) return element.duration.realValue * 4.0;
    if (element is Chord) return element.duration.realValue * 4.0;
    if (element is Space) return element.musicalValue * 4.0;
    if (element is Tuplet) return element.totalDuration * 4.0;
    return 0.0;
  }

  double _rhythmicStartForMeasure(
    List<_StaffLayout> layouts,
    ({double start, double end}) bounds,
  ) {
    var start = double.infinity;
    for (final layout in layouts) {
      for (final positioned in layout.elements) {
        final x = positioned.position.dx;
        if (x < bounds.start || x > bounds.end) continue;
        final element = positioned.element;
        if (element is Note ||
            element is Rest ||
            element is Chord ||
            element is Tuplet) {
          start = math.min(start, x);
        }
      }
    }
    return start.isFinite ? start : bounds.start;
  }

  int? _measureIndexForNumber(int number) {
    final explicitIndex = _measureIndicesByNumber[number];
    if (explicitIndex != null) return explicitIndex;
    if (_hasExplicitMeasureNumbers) return null;
    final fallback = number - 1;
    return fallback >= 0 &&
            _allStaves.isNotEmpty &&
            fallback < _allStaves.first.measures.length
        ? fallback
        : null;
  }

  int? _measureIndexForPosition(ScorePlaybackPosition position) {
    final sourceIndex = position.sourceMeasureIndex;
    if (sourceIndex != null &&
        sourceIndex >= 0 &&
        _allStaves.any((staff) => sourceIndex < staff.measures.length)) {
      return sourceIndex;
    }
    return _measureIndexForNumber(position.measureNumber);
  }

  void _drawStaffLabels(Canvas canvas, double baseline0, int systemIndex) {
    final available = math.max(1.0, _bracePad - staffSpace * 0.8);
    for (var index = 0; index < _allStaves.length; index++) {
      final staff = _allStaves[index];
      final fullName = staff.name;
      if (fullName == null || fullName.isEmpty) continue;
      final label = systemIndex == 0
          ? fullName
          : staff.abbreviation ?? _shortLabel(fullName);
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: (theme.textStyle ?? const TextStyle()).copyWith(
            color: theme.textColor ?? theme.noteheadColor,
            fontSize: staffSpace * 1.1,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: available);
      painter.paint(
        canvas,
        Offset(
          -_bracePad,
          baseline0 + index * staffGap - painter.height * 0.55,
        ),
      );
    }
  }

  String _shortLabel(String label) {
    final normalized = label.trim().toLowerCase();
    if (normalized.startsWith('baritone')) return 'Bar.';
    if (normalized.startsWith('bass')) return 'B.';
    if (normalized.startsWith('tenor')) {
      final suffix = label.substring('Tenor'.length).trim();
      return suffix.isEmpty ? 'T.' : 'T. $suffix';
    }
    if (normalized.startsWith('soprano')) return 'S.';
    if (normalized.startsWith('alto')) return 'A.';
    if (normalized.startsWith('solo')) return 'Solo';
    return label.length > 6 ? '${label.substring(0, 6)}.' : label;
  }

  void _drawMeasureNumber(Canvas canvas, double baseline0, int systemIndex) {
    if (systemIndex == 0 || _allStaves.isEmpty) return;
    final measureIndex = _systemRanges[systemIndex].start;
    if (measureIndex >= _allStaves.first.measures.length) return;
    final number =
        _allStaves.first.measures[measureIndex].number ?? measureIndex + 1;
    final painter = TextPainter(
      text: TextSpan(
        text: '$number',
        style: (theme.textStyle ?? const TextStyle()).copyWith(
          color: theme.textColor ?? theme.noteheadColor,
          fontSize: staffSpace * 0.95,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, Offset(0, baseline0 - staffSpace * 4.0));
  }

  /// The system's barlines (x + type), taken from the (aligned) first staff —
  /// all staves share the same measure structure in a group.
  List<({double x, BarlineType type})> _systemBarlines(
    List<_StaffLayout> layouts,
  ) {
    if (layouts.isEmpty) return const [];
    final out = <({double x, BarlineType type})>[];
    for (final pe in layouts.first.elements) {
      if (pe.element is Barline) {
        out.add((x: pe.position.dx, type: (pe.element as Barline).type));
      }
    }
    return out;
  }

  /// Draws a single system-spanning barline of the given [type] from [topY] to
  /// [bottomY]. Normal barlines are one thin line; final/heavy barlines add a
  /// thick line; double/light-light draws two thin lines.
  void _drawSystemBarline(
    Canvas canvas,
    double x,
    BarlineType type,
    double topY,
    double bottomY,
  ) {
    final thin =
        metadata.getEngravingDefault('thinBarlineThickness', 0.16) * staffSpace;
    final thick =
        metadata.getEngravingDefault('thickBarlineThickness', 0.5) * staffSpace;
    final color = theme.barlineColor;
    Paint p(double w) => Paint()
      ..color = color
      ..strokeWidth = w
      ..strokeCap = StrokeCap.butt;
    void line(double cx, double w) =>
        canvas.drawLine(Offset(cx, topY), Offset(cx, bottomY), p(w));

    switch (type) {
      case BarlineType.final_:
      case BarlineType.lightHeavy:
        line(x, thin);
        line(x + thin * 0.5 + staffSpace * 0.45 + thick * 0.5, thick);
        break;
      case BarlineType.heavy:
        line(x, thick);
        break;
      case BarlineType.double:
      case BarlineType.lightLight:
        line(x, thin);
        line(x + staffSpace * 0.45, thin);
        break;
      case BarlineType.none:
        break;
      default:
        line(x, thin);
    }
  }

  // --- Cross-staff beams ----------------------------------------------------

  /// Notes of staff [home] that belong to a beam group containing a cross-staff
  /// note. The home staff skips drawing them; the cross-staff pass draws them.
  Set<Note> _crossStaffNotesOf(List<_StaffLayout> layouts, int home) {
    final out = <Note>{};
    for (final g in _crossStaffGroups(layouts[home].elements)) {
      out.addAll(g);
    }
    return out;
  }

  /// Beam runs (note.beam start..end) among positioned elements that contain a
  /// cross-staff note. Works regardless of whether the beam was rendered via the
  /// advanced or the simple path.
  List<List<Note>> _crossStaffGroups(List<PositionedElement> els) {
    final groups = <List<Note>>[];
    List<Note>? cur;
    for (final pe in els) {
      final e = pe.element;
      if (e is! Note) continue;
      switch (e.beam) {
        case BeamType.start:
          cur = [e];
          break;
        case BeamType.inner:
          cur?.add(e);
          break;
        case BeamType.end:
          if (cur != null) {
            cur.add(e);
            if (cur.any((n) => n.crossStaffMove != 0)) groups.add(cur);
            cur = null;
          }
          break;
        case null:
          cur = null;
          break;
      }
    }
    return groups;
  }

  Clef _clefOf(int staffIndex) {
    if (staffIndex < 0 || staffIndex >= _allStaves.length) {
      return Clef(clefType: ClefType.treble);
    }
    for (final m in _allStaves[staffIndex].measures) {
      for (final e in m.elements) {
        if (e is Clef) return e;
      }
    }
    return Clef(clefType: ClefType.treble);
  }

  /// Draws beam groups that straddle two staves: each notehead on its target
  /// staff, stems reaching a single beam placed between the staves.
  void _drawCrossStaffBeams(
    Canvas canvas,
    double baseline0,
    List<_StaffLayout> layouts,
  ) {
    final ss = staffSpace;
    final noteheadChar = metadata.getCodepoint('noteheadBlack');
    final noteheadW =
        (metadata.getGlyphAdvanceWidth('noteheadBlack') ?? 1.18) * ss;
    final stemW = metadata.getEngravingDefault('stemThickness', 0.12) * ss;
    final beamThick = metadata.getEngravingDefault('beamThickness', 0.5) * ss;
    final fontSize = ss * 4.0;
    final stemPaint = Paint()
      ..color = theme.stemColor
      ..strokeWidth = stemW;
    final beamPaint = Paint()..color = theme.stemColor;

    for (var home = 0; home < layouts.length; home++) {
      // Note X positions from the (aligned) positioned elements.
      final noteX = <Note, double>{};
      for (final pe in layouts[home].elements) {
        if (pe.element is Note) noteX[pe.element as Note] = pe.position.dx;
      }
      for (final g in _crossStaffGroups(layouts[home].elements)) {
        final pts = <({double x, double y})>[];
        for (final note in g) {
          final x = noteX[note];
          if (x == null) continue;
          final target = (home + note.crossStaffMove).clamp(
            0,
            _allStaves.length - 1,
          );
          final pos = StaffPositionCalculator.calculate(
            note.pitch,
            _clefOf(target),
          );
          final y = baseline0 + target * staffGap - pos * ss * 0.5;
          pts.add((x: x, y: y));

          // Notehead glyph (noteheadBlack is ~baseline-centred vertically).
          if (noteheadChar.isNotEmpty) {
            final tp = TextPainter(
              text: TextSpan(
                text: noteheadChar,
                style: TextStyle(
                  fontFamily: 'Bravura',
                  package: 'flutter_notemus',
                  fontSize: fontSize,
                  color: theme.noteheadColor,
                  height: 1.0,
                ),
              ),
              textDirection: TextDirection.ltr,
            )..layout();
            final baselineFromTop = tp.computeDistanceToActualBaseline(
              TextBaseline.alphabetic,
            );
            tp.paint(canvas, Offset(x, y - baselineFromTop));
          }
        }
        if (pts.length < 2) continue;

        var minY = pts.first.y, maxY = pts.first.y;
        for (final p in pts) {
          if (p.y < minY) minY = p.y;
          if (p.y > maxY) maxY = p.y;
        }
        final beamY = (minY + maxY) / 2;

        // Stems attach at the notehead edge nearest the beam: a note below the
        // beam stems up (right edge); a note above stems down (left edge).
        double stemXof(({double x, double y}) p) =>
            p.y > beamY ? p.x + noteheadW - stemW * 0.5 : p.x + stemW * 0.5;
        for (final p in pts) {
          final sx = stemXof(p);
          canvas.drawLine(Offset(sx, p.y), Offset(sx, beamY), stemPaint);
        }
        final xs = pts.map(stemXof).toList()..sort();
        canvas.drawRect(
          Rect.fromLTRB(
            xs.first - stemW * 0.5,
            beamY - beamThick / 2,
            xs.last + stemW * 0.5,
            beamY + beamThick / 2,
          ),
          beamPaint,
        );
      }
    }
  }

  /// Returns the rendered note closest to [position], if the tap falls within
  /// a forgiving notehead-sized target.
  ///
  /// Coordinates are in the local space of the [CustomPaint], including the
  /// brace padding and stacked-system offsets applied in [paint].
  Note? noteAt(
    Offset position, {
    Note? lastNote,
    int firstSystem = 0,
    int? lastSystem,
  }) {
    if (_systems.isEmpty) return null;
    final first = firstSystem.clamp(0, _systems.length - 1);
    final last = (lastSystem ?? _systems.length - 1).clamp(
      first,
      _systems.length - 1,
    );

    Note? closestBroad;
    var closestBroadDistance = double.infinity;
    Note? closestNotehead;
    var closestNoteheadDistance = double.infinity;
    final baseline0 = staffSpace * 5.0;
    final sequence = _noteSequence();
    final lastIndex = lastNote == null ? -1 : sequence.indexOf(lastNote);
    const edgeRadius = 60.0;

    for (var sysIdx = first; sysIdx <= last; sysIdx++) {
      final systemPosition = Offset(
        (position.dx - _bracePad) / _systemScales[sysIdx],
        position.dy - (sysIdx - first) * systemBlockHeight,
      );
      if (systemPosition.dy < -edgeRadius ||
          systemPosition.dy > systemBlockHeight + edgeRadius) {
        continue;
      }

      final layouts = _systems[sysIdx];
      for (var staffIdx = 0; staffIdx < layouts.length; staffIdx++) {
        var clef = Clef(clefType: ClefType.treble);
        for (final positioned in layouts[staffIdx].elements) {
          final element = positioned.element;
          if (element is Clef) {
            clef = element;
            continue;
          }
          for (final candidate in _positionedNotes(
            element,
            positioned.position.dx,
          )) {
            final note = candidate.note;
            final targetStaff = (staffIdx + note.crossStaffMove)
                .clamp(0, _allStaves.length - 1)
                .toInt();
            final targetClef = targetStaff == staffIdx
                ? clef
                : _clefOf(targetStaff);
            final staffStep = StaffPositionCalculator.calculate(
              note.pitch,
              targetClef,
            );
            final noteHead = metadata.getGlyphInfo(
              note.duration.type.glyphName,
            );
            final centerX =
                (noteHead?.boundingBox?.centerX ?? 0.59) * staffSpace;
            final centerY =
                (noteHead?.boundingBox?.centerY ?? 0.0) * staffSpace;
            final noteCenter = Offset(
              candidate.x + centerX,
              baseline0 +
                  targetStaff * staffGap -
                  staffStep * staffSpace * 0.5 +
                  centerY,
            );
            final distance = (systemPosition - noteCenter).distance;
            final noteIndex = sequence.indexOf(note);
            final hitRadius = _hitRadiusFor(
              noteIndex: noteIndex,
              lastIndex: lastIndex,
            );
            if (distance <= hitRadius && distance < closestBroadDistance) {
              closestBroad = note;
              closestBroadDistance = distance;
            }
            // Notes remain the primary target even when a dynamic, tuplet
            // number, or other text is visually drawn over the same area.
            final noteheadRadius = math.max(staffSpace * 2.0, 10.0);
            if (distance <= noteheadRadius &&
                distance < closestNoteheadDistance) {
              closestNotehead = note;
              closestNoteheadDistance = distance;
            }
          }
        }
      }
    }
    return closestNotehead ?? closestBroad;
  }

  List<Note> _noteSequence() {
    final notes = <Note>[];
    final seen = Set<Note>.identity();
    for (final system in _systems) {
      for (final layout in system) {
        for (final positioned in layout.elements) {
          final element = positioned.element;
          for (final candidate in _positionedNotes(
            element,
            positioned.position.dx,
          )) {
            final note = candidate.note;
            if (seen.add(note)) notes.add(note);
          }
        }
      }
    }
    return notes;
  }

  /// Returns note positions in the same coordinate model used by the staff
  /// renderer. Tuplet notes are children of one positioned Tuplet element, so
  /// their x positions must be reconstructed from the renderer's slot spacing.
  List<({Note note, double x})> _positionedNotes(
    MusicalElement element,
    double baseX,
  ) {
    if (element is Note) return [(note: element, x: baseX)];
    if (element is Chord) {
      return [for (final note in element.notes) (note: note, x: baseX)];
    }
    if (element is Tuplet) {
      final spacing = staffSpace * 2.5;
      final notes = <({Note note, double x})>[];
      for (var index = 0; index < element.elements.length; index++) {
        notes.addAll(
          _positionedNotes(element.elements[index], baseX + index * spacing),
        );
      }
      return notes;
    }
    return const [];
  }

  double _hitRadiusFor({required int noteIndex, required int lastIndex}) {
    // Keep the XML target sizes aligned with the PDF play overlay:
    // 60px initial/next-two, 30px immediate previous/repeat, 20px distant.
    const baseRadius = 60.0;
    const previousRadius = 30.0;
    const distantRadius = 20.0;
    if (lastIndex < 0 || noteIndex < 0) {
      return baseRadius;
    }
    if (noteIndex == lastIndex) {
      return previousRadius;
    }
    if (noteIndex >= lastIndex && noteIndex - lastIndex <= 2) {
      return baseRadius;
    }
    if (noteIndex == lastIndex - 1) {
      return previousRadius;
    }
    return distantRadius;
  }

  @override
  bool shouldRepaint(covariant GrandStaffPainter oldDelegate) {
    return !identical(oldDelegate.groups, groups) ||
        oldDelegate.staffSpace != staffSpace ||
        oldDelegate.staffGap != staffGap ||
        oldDelegate.availableWidth != availableWidth ||
        oldDelegate.measureRange != measureRange ||
        oldDelegate.wrapSystems != wrapSystems ||
        oldDelegate.fitSystemsToWidth != fitSystemsToWidth ||
        !identical(oldDelegate.metadata, metadata) ||
        !identical(oldDelegate.theme, theme);
  }
}
