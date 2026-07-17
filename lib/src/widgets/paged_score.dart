import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../rendering/grand_staff_painter.dart';
import '../smufl/smufl_metadata_loader.dart';
import '../theme/music_score_theme.dart';
import 'grand_staff.dart';

/// Displays a score as a sequence of fixed-ratio paper pages.
///
/// The regular [GrandStaff] layout decides the measure breaks. Those systems
/// are then composed vertically on each page, so the page never has to shrink
/// a tall score into an unreadable strip.
class PagedScoreView extends StatefulWidget {
  final Score score;
  final MusicScoreTheme theme;
  final double staffSpace;
  final ValueChanged<Note>? onNoteTap;

  /// Page size in points. A4 portrait is the default.
  final double pageWidth;
  final double pageHeight;

  /// Inner page margin in logical pixels at the rendered page scale.
  final double pageMargin;

  const PagedScoreView({
    super.key,
    required this.score,
    this.theme = const MusicScoreTheme(),
    this.staffSpace = 12.0,
    this.onNoteTap,
    this.pageWidth = 595.0,
    this.pageHeight = 842.0,
    this.pageMargin = 40.0,
  }) : assert(pageWidth > 0),
       assert(pageHeight > 0),
       assert(pageMargin >= 0);

  @override
  State<PagedScoreView> createState() => _PagedScoreViewState();
}

class _PagedScoreViewState extends State<PagedScoreView> {
  late final SmuflMetadata _metadata;
  late final Future<void> _metadataFuture;

  @override
  void initState() {
    super.initState();
    _metadata = SmuflMetadata();
    _metadataFuture = _metadata.load();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _metadataFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('Failed to load notation: ${snapshot.error}'),
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            var width = math.min(
              widget.pageWidth,
              constraints.maxWidth.isFinite
                  ? constraints.maxWidth - 24.0
                  : widget.pageWidth,
            );
            if (!width.isFinite || width <= 0) width = widget.pageWidth;

            final height = width * widget.pageHeight / widget.pageWidth;
            final margin = widget.pageMargin * width / widget.pageWidth;
            final systems = _systems(width - margin * 2.0);
            final pages = _pages(systems, _systemsPerPage());

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final page in pages) ...[
                  _ScorePage(
                    systems: page,
                    width: width,
                    height: height,
                    margin: margin,
                    staffSpace: widget.staffSpace,
                    theme: widget.theme,
                    onNoteTap: widget.onNoteTap,
                  ),
                  const SizedBox(height: 24),
                ],
              ],
            );
          },
        );
      },
    );
  }

  /// Uses the same greedy system ranges as [GrandStaffPainter], ensuring that
  /// pagination follows the actual engraving layout at this page width.
  List<Score> _systems(double contentWidth) {
    final probe = GrandStaffPainter(
      groups: widget.score.staffGroups,
      staffSpace: widget.staffSpace,
      metadata: _metadata,
      theme: widget.theme,
      availableWidth: math.max(1.0, contentWidth),
      staffGap: widget.staffSpace * 11.0,
    );
    final ranges = probe.systemRanges;
    if (ranges.isEmpty) return const [];

    return [for (final range in ranges) _sliceScore(range.start, range.end)];
  }

  int _systemsPerPage() {
    final staffCount = widget.score.staffCount;
    final staffGap = widget.staffSpace * 11.0;
    final systemBlockHeight =
        math.max(0, staffCount - 1) * staffGap + widget.staffSpace * 10.0;
    final systemHeight = systemBlockHeight + widget.staffSpace * 2.0;
    final systemGap = widget.staffSpace * 4.0;
    final contentHeight = widget.pageHeight - widget.pageMargin * 2.0;
    return math.max(
      1,
      ((contentHeight + systemGap) / (systemHeight + systemGap)).floor(),
    );
  }

  List<List<Score>> _pages(List<Score> systems, int systemsPerPage) {
    if (systems.isEmpty) return const [];

    return [
      for (var start = 0; start < systems.length; start += systemsPerPage)
        systems.sublist(
          start,
          math.min(start + systemsPerPage, systems.length),
        ),
    ];
  }

  Score _sliceScore(int start, int endInclusive) {
    return widget.score.copyWith(
      staffGroups: [
        for (final group in widget.score.staffGroups)
          group.copyWith(
            staves: [
              for (final staff in group.staves)
                _sliceStaff(staff, start, endInclusive),
            ],
          ),
      ],
    );
  }

  Staff _sliceStaff(Staff source, int start, int endInclusive) {
    if (source.measures.isEmpty || start >= source.measures.length) {
      return Staff(lineCount: source.lineCount);
    }

    final actualEnd = math.min(endInclusive + 1, source.measures.length);
    final selected = source.measures.sublist(start, actualEnd);
    if (start == 0 || selected.isEmpty) {
      return Staff(measures: selected, lineCount: source.lineCount);
    }

    // Carry state into a new system so clefs, keys, and meters remain readable
    // when the source MusicXML only declares them at the beginning or at a
    // later change point.
    final first = selected.first;
    final firstSystemMeasure = Measure(
      autoBeaming: first.autoBeaming,
      beamingMode: first.beamingMode,
      manualBeamGroups: first.manualBeamGroups,
      inheritedTimeSignature: first.inheritedTimeSignature,
      number: first.number,
    );
    final carried = <MusicalElement?>[
      if (!_hasElement<Clef>(first)) _latest<Clef>(source, start),
      if (!_hasElement<KeySignature>(first))
        _latest<KeySignature>(source, start),
      if (!_hasElement<TimeSignature>(first))
        _latest<TimeSignature>(source, start),
    ];
    firstSystemMeasure.elements.addAll(carried.whereType<MusicalElement>());
    firstSystemMeasure.elements.addAll(first.elements);

    return Staff(
      lineCount: source.lineCount,
      measures: [firstSystemMeasure, ...selected.skip(1)],
    );
  }

  bool _hasElement<T>(Measure measure) {
    return measure.elements.any((element) => element is T);
  }

  T? _latest<T>(Staff staff, int before) {
    for (var index = before - 1; index >= 0; index--) {
      for (final element in staff.measures[index].elements.reversed) {
        if (element is T) return element as T;
      }
    }
    return null;
  }
}

class _ScorePage extends StatelessWidget {
  final List<Score> systems;
  final double width;
  final double height;
  final double margin;
  final double staffSpace;
  final MusicScoreTheme theme;
  final ValueChanged<Note>? onNoteTap;

  const _ScorePage({
    required this.systems,
    required this.width,
    required this.height,
    required this.margin,
    required this.staffSpace,
    required this.theme,
    required this.onNoteTap,
  });

  @override
  Widget build(BuildContext context) {
    final contentWidth = math.max(1.0, width - margin * 2.0);
    final systemGap = staffSpace * 4.0;
    return Material(
      color: Colors.white,
      elevation: 2.0,
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: EdgeInsets.all(margin),
          child: ClipRect(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < systems.length; index++) ...[
                  SizedBox(
                    width: contentWidth,
                    child: GrandStaff(
                      groups: systems[index].staffGroups,
                      staffSpace: staffSpace,
                      theme: theme,
                      onNoteTap: onNoteTap,
                    ),
                  ),
                  if (index < systems.length - 1) SizedBox(height: systemGap),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
