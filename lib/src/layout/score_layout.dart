import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../core/score.dart';
import '../rendering/grand_staff_painter.dart';
import '../smufl/smufl_metadata_loader.dart';
import '../theme/music_score_theme.dart';

enum ScoreLayoutMode { paged, continuousVertical, continuousHorizontal }

class ScoreSystemLayout {
  const ScoreSystemLayout({
    required this.index,
    required this.firstMeasureIndex,
    required this.lastMeasureIndex,
    required this.bounds,
    required this.scale,
  });

  final int index;
  final int firstMeasureIndex;
  final int lastMeasureIndex;
  final Rect bounds;
  final double scale;

  bool containsMeasure(int measureIndex) {
    return measureIndex >= firstMeasureIndex &&
        measureIndex <= lastMeasureIndex;
  }
}

class ScorePageLayout {
  const ScorePageLayout({
    required this.index,
    required this.firstSystemIndex,
    required this.lastSystemIndex,
    required this.size,
    required this.contentBounds,
    required this.headerHeight,
    required this.scoreHeight,
  });

  final int index;
  final int firstSystemIndex;
  final int lastSystemIndex;
  final Size size;
  final Rect contentBounds;
  final double headerHeight;
  final double scoreHeight;

  int get systemCount => lastSystemIndex - firstSystemIndex + 1;

  bool containsSystem(int systemIndex) {
    return systemIndex >= firstSystemIndex && systemIndex <= lastSystemIndex;
  }
}

/// Cached, immutable geometry for every supported score display mode.
class ScoreLayout {
  ScoreLayout._({
    required this.score,
    required this.mode,
    required this.painter,
    required this.systems,
    required this.pages,
    required this.size,
    required this.pageSize,
    required this.pageMargin,
  });

  factory ScoreLayout.build({
    required Score score,
    required ScoreLayoutMode mode,
    required SmuflMetadata metadata,
    required MusicScoreTheme theme,
    required double availableWidth,
    double staffSpace = 12,
    double? staffGap,
    double pageWidth = 595,
    double pageHeight = 842,
    double pageMargin = 40,
  }) {
    assert(availableWidth > 0);
    assert(pageWidth > 0);
    assert(pageHeight > 0);
    assert(pageMargin >= 0);

    final safeWidth = availableWidth.isFinite && availableWidth > 0
        ? availableWidth
        : pageWidth;
    final resolvedGap = staffGap ?? staffSpace * 11;
    final isPaged = mode == ScoreLayoutMode.paged;
    final renderedPageSize = isPaged ? Size(pageWidth, pageHeight) : Size.zero;
    final renderedMargin = isPaged ? pageMargin : 0.0;
    final layoutWidth = isPaged
        ? math.max(1.0, pageWidth - pageMargin * 2)
        : safeWidth;
    final horizontal = mode == ScoreLayoutMode.continuousHorizontal;
    final painter = GrandStaffPainter(
      groups: score.staffGroups,
      staffSpace: staffSpace,
      metadata: metadata,
      theme: theme,
      availableWidth: layoutWidth,
      staffGap: resolvedGap,
      wrapSystems: !horizontal,
      fitSystemsToWidth: !horizontal,
    );
    final systems = [
      for (var index = 0; index < painter.systemRanges.length; index++)
        ScoreSystemLayout(
          index: index,
          firstMeasureIndex: painter.systemRanges[index].start,
          lastMeasureIndex: painter.systemRanges[index].end,
          bounds: painter.systemBounds(index),
          scale: painter.systemScaleAt(index),
        ),
    ];
    final pages = isPaged
        ? _buildPages(
            score: score,
            painter: painter,
            pageSize: renderedPageSize,
            margin: renderedMargin,
            staffSpace: staffSpace,
          )
        : const <ScorePageLayout>[];
    final size = isPaged
        ? renderedPageSize
        : Size(painter.totalWidth, painter.totalHeight);

    return ScoreLayout._(
      score: score,
      mode: mode,
      painter: painter,
      systems: List.unmodifiable(systems),
      pages: List.unmodifiable(pages),
      size: size,
      pageSize: renderedPageSize,
      pageMargin: renderedMargin,
    );
  }

  final Score score;
  final ScoreLayoutMode mode;
  final GrandStaffPainter painter;
  final List<ScoreSystemLayout> systems;
  final List<ScorePageLayout> pages;

  /// Continuous canvas size, or one page's size in paged mode.
  final Size size;
  final Size pageSize;
  final double pageMargin;

  ScoreSystemLayout? systemForMeasureIndex(int measureIndex) {
    for (final system in systems) {
      if (system.containsMeasure(measureIndex)) return system;
    }
    return null;
  }

  ScorePageLayout? pageForMeasureIndex(int measureIndex) {
    final system = systemForMeasureIndex(measureIndex);
    if (system == null) return null;
    for (final page in pages) {
      if (page.containsSystem(system.index)) return page;
    }
    return null;
  }

  Rect? measureBoundsForIndex(int measureIndex) {
    return painter.measureBoundsForIndex(measureIndex);
  }

  Offset? playbackOffset(ScorePlaybackPosition? position) {
    return painter.playbackOffset(position);
  }

  Offset? playbackOffsetOnPage(ScorePlaybackPosition? position, int pageIndex) {
    if (pageIndex < 0 || pageIndex >= pages.length) return null;
    final global = painter.playbackOffset(position);
    if (global == null) return null;
    final page = pages[pageIndex];
    return Offset(
      page.contentBounds.left + global.dx,
      page.contentBounds.top +
          page.headerHeight +
          global.dy -
          page.firstSystemIndex * painter.systemBlockHeight,
    );
  }
}

List<ScorePageLayout> _buildPages({
  required Score score,
  required GrandStaffPainter painter,
  required Size pageSize,
  required double margin,
  required double staffSpace,
}) {
  if (painter.systemCount == 0) return const [];
  final contentBounds = Rect.fromLTWH(
    margin,
    margin,
    math.max(1.0, pageSize.width - margin * 2),
    math.max(1.0, pageSize.height - margin * 2),
  );
  final hasHeader =
      score.title?.isNotEmpty == true ||
      score.subtitle?.isNotEmpty == true ||
      score.composer?.isNotEmpty == true ||
      score.arranger?.isNotEmpty == true ||
      score.copyright?.isNotEmpty == true;
  final pages = <ScorePageLayout>[];
  var firstSystem = 0;

  while (firstSystem < painter.systemCount) {
    final headerHeight = pages.isEmpty && hasHeader ? staffSpace * 12 : 0.0;
    final availableHeight = math.max(1.0, contentBounds.height - headerHeight);
    var lastSystem = firstSystem;
    while (lastSystem + 1 < painter.systemCount) {
      final candidateHeight = painter.heightForSystemRange(
        firstSystem,
        lastSystem + 1,
      );
      if (candidateHeight > availableHeight) break;
      lastSystem++;
    }
    final scoreHeight = painter.heightForSystemRange(firstSystem, lastSystem);
    pages.add(
      ScorePageLayout(
        index: pages.length,
        firstSystemIndex: firstSystem,
        lastSystemIndex: lastSystem,
        size: pageSize,
        contentBounds: contentBounds,
        headerHeight: headerHeight,
        scoreHeight: scoreHeight,
      ),
    );
    firstSystem = lastSystem + 1;
  }
  return pages;
}

/// Small LRU cache so rebuilds, zoom controls, and mode switches reuse layout.
class ScoreLayoutCache {
  ScoreLayoutCache({this.maximumEntries = 12}) : assert(maximumEntries > 0);

  static final shared = ScoreLayoutCache();

  final int maximumEntries;
  final LinkedHashMap<_ScoreLayoutKey, ScoreLayout> _entries = LinkedHashMap();

  int get length => _entries.length;

  ScoreLayout getOrBuild({
    required Score score,
    required ScoreLayoutMode mode,
    required SmuflMetadata metadata,
    required MusicScoreTheme theme,
    required double availableWidth,
    double staffSpace = 12,
    double? staffGap,
    double pageWidth = 595,
    double pageHeight = 842,
    double pageMargin = 40,
  }) {
    final resolvedWidth = availableWidth.isFinite && availableWidth > 0
        ? availableWidth
        : pageWidth;
    final layoutWidth = mode == ScoreLayoutMode.paged
        ? pageWidth
        : resolvedWidth;
    final key = _ScoreLayoutKey(
      score: score,
      mode: mode,
      metadata: metadata,
      themeHash: _themeHash(theme),
      availableWidth: _quantize(layoutWidth),
      staffSpace: _quantize(staffSpace),
      staffGap: _quantize(staffGap ?? staffSpace * 11),
      pageWidth: _quantize(pageWidth),
      pageHeight: _quantize(pageHeight),
      pageMargin: _quantize(pageMargin),
    );
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return cached;
    }

    final layout = ScoreLayout.build(
      score: score,
      mode: mode,
      metadata: metadata,
      theme: theme,
      availableWidth: layoutWidth,
      staffSpace: staffSpace,
      staffGap: staffGap,
      pageWidth: pageWidth,
      pageHeight: pageHeight,
      pageMargin: pageMargin,
    );
    _entries[key] = layout;
    while (_entries.length > maximumEntries) {
      _entries.remove(_entries.keys.first);
    }
    return layout;
  }

  void invalidate(Score score) {
    _entries.removeWhere((key, _) => identical(key.score, score));
  }

  void clear() => _entries.clear();
}

double _quantize(double value) => (value * 2).round() / 2;

int _themeHash(MusicScoreTheme theme) {
  return Object.hashAll([
    theme.staffLineColor,
    theme.noteheadColor,
    theme.stemColor,
    theme.clefColor,
    theme.barlineColor,
    theme.timeSignatureColor,
    theme.keySignatureColor,
    theme.restColor,
    theme.articulationColor,
    theme.ornamentColor,
    theme.dynamicColor,
    theme.tupletColor,
    theme.breathColor,
    theme.slurColor,
    theme.tieColor,
    theme.beamColor,
    theme.accidentalColor,
    theme.harmonicColor,
    theme.textColor,
    theme.repeatColor,
    theme.octaveColor,
    theme.clusterColor,
    theme.caesuraColor,
    theme.metronomeColor,
    theme.textStyle,
    theme.dynamicTextStyle,
    theme.tupletTextStyle,
    theme.tempoTextStyle,
    theme.expressionTextStyle,
    theme.lyricTextStyle,
    theme.chordTextStyle,
    theme.rehearsalTextStyle,
    theme.repeatTextStyle,
    theme.octaveTextStyle,
    theme.metronomeTextStyle,
    theme.defaultStaffSpace,
    theme.defaultFontSize,
    theme.showLedgerLines,
    theme.antiAlias,
    theme.strokeWidth,
  ]);
}

class _ScoreLayoutKey {
  const _ScoreLayoutKey({
    required this.score,
    required this.mode,
    required this.metadata,
    required this.themeHash,
    required this.availableWidth,
    required this.staffSpace,
    required this.staffGap,
    required this.pageWidth,
    required this.pageHeight,
    required this.pageMargin,
  });

  final Score score;
  final ScoreLayoutMode mode;
  final SmuflMetadata metadata;
  final int themeHash;
  final double availableWidth;
  final double staffSpace;
  final double staffGap;
  final double pageWidth;
  final double pageHeight;
  final double pageMargin;

  @override
  bool operator ==(Object other) {
    return other is _ScoreLayoutKey &&
        identical(other.score, score) &&
        other.mode == mode &&
        identical(other.metadata, metadata) &&
        other.themeHash == themeHash &&
        other.availableWidth == availableWidth &&
        other.staffSpace == staffSpace &&
        other.staffGap == staffGap &&
        other.pageWidth == pageWidth &&
        other.pageHeight == pageHeight &&
        other.pageMargin == pageMargin;
  }

  @override
  int get hashCode => Object.hash(
    identityHashCode(score),
    mode,
    identityHashCode(metadata),
    themeHash,
    availableWidth,
    staffSpace,
    staffGap,
    pageWidth,
    pageHeight,
    pageMargin,
  );
}
