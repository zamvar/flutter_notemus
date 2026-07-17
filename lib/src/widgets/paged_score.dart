import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../theme/music_score_theme.dart';
import 'grand_staff.dart';

/// Displays a score as a sequence of fixed-ratio pages.
///
/// Pages are made from synchronized measure slices across every staff, so a
/// choir or piano score keeps its vertical alignment. Each page uses the
/// regular [GrandStaff] renderer and preserves [onNoteTap] callbacks.
class PagedScoreView extends StatelessWidget {
  final Score score;
  final MusicScoreTheme theme;
  final double staffSpace;
  final ValueChanged<Note>? onNoteTap;

  /// Number of source measures placed on each page before system wrapping.
  final int measuresPerPage;

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
    this.measuresPerPage = 8,
    this.pageWidth = 595.0,
    this.pageHeight = 842.0,
    this.pageMargin = 40.0,
  }) : assert(measuresPerPage > 0),
       assert(pageWidth > 0),
       assert(pageHeight > 0),
       assert(pageMargin >= 0);

  @override
  Widget build(BuildContext context) {
    final pages = _pages();
    if (pages.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        var width = math.min(pageWidth, constraints.maxWidth - 24.0);
        if (!width.isFinite || width <= 0) width = pageWidth;

        if (constraints.hasBoundedHeight && constraints.maxHeight > 24.0) {
          width = math.min(
            width,
            (constraints.maxHeight - 24.0) * pageWidth / pageHeight,
          );
        }

        final height = width * pageHeight / pageWidth;
        return SizedBox(
          height: height + 24.0,
          child: PageView.builder(
            itemCount: pages.length,
            itemBuilder: (context, index) => Center(
              child: _ScorePage(
                score: pages[index],
                width: width,
                height: height,
                margin: pageMargin * width / pageWidth,
                staffSpace: staffSpace,
                theme: theme,
                onNoteTap: onNoteTap,
              ),
            ),
          ),
        );
      },
    );
  }

  List<Score> _pages() {
    final measureCount = score.allStaves.fold<int>(
      0,
      (maximum, staff) => math.max(maximum, staff.measures.length),
    );
    final pageCount = math.max(1, (measureCount / measuresPerPage).ceil());

    return [
      for (var page = 0; page < pageCount; page++)
        _sliceScore(
          page * measuresPerPage,
          math.min(measureCount, (page + 1) * measuresPerPage),
        ),
    ];
  }

  Score _sliceScore(int start, int end) {
    return score.copyWith(
      staffGroups: [
        for (final group in score.staffGroups)
          group.copyWith(
            staves: [
              for (final staff in group.staves) _sliceStaff(staff, start, end),
            ],
          ),
      ],
    );
  }

  Staff _sliceStaff(Staff source, int start, int end) {
    if (source.measures.isEmpty || start >= source.measures.length) {
      return Staff(lineCount: source.lineCount);
    }

    final actualEnd = math.min(end, source.measures.length);
    final selected = source.measures.sublist(start, actualEnd);
    if (start == 0 || selected.isEmpty) {
      return Staff(measures: selected, lineCount: source.lineCount);
    }

    // Carry state into a new page so clefs, keys, and meters remain readable
    // when the source MusicXML only declares them at the beginning or at a
    // later change point.
    final first = selected.first;
    final firstPageMeasure = Measure(
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
    firstPageMeasure.elements.addAll(carried.whereType<MusicalElement>());
    firstPageMeasure.elements.addAll(first.elements);

    return Staff(
      lineCount: source.lineCount,
      measures: [firstPageMeasure, ...selected.skip(1)],
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
  final Score score;
  final double width;
  final double height;
  final double margin;
  final double staffSpace;
  final MusicScoreTheme theme;
  final ValueChanged<Note>? onNoteTap;

  const _ScorePage({
    required this.score,
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
    return Material(
      color: Colors.white,
      elevation: 2.0,
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: EdgeInsets.all(margin),
          child: ClipRect(
            child: FittedBox(
              fit: BoxFit.contain,
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: contentWidth,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: GrandStaff(
                    groups: score.staffGroups,
                    staffSpace: staffSpace,
                    theme: theme,
                    onNoteTap: onNoteTap,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
