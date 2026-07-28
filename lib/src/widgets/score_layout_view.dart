import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/note.dart';
import '../../core/score.dart';
import '../layout/score_layout.dart';
import '../rendering/grand_staff_painter.dart';
import '../smufl/smufl_metadata_loader.dart';
import '../theme/music_score_theme.dart';
import 'paged_score.dart';
import 'score_interaction.dart';
import 'score_layout_region.dart';

/// Displays a score using the same cached geometry in every display mode.
class ScoreLayoutView extends StatefulWidget {
  const ScoreLayoutView({
    super.key,
    required this.score,
    required this.mode,
    this.theme = const MusicScoreTheme(),
    this.staffSpace = 12,
    this.staffGap,
    this.layoutWidth,
    this.metadata,
    this.cache,
    this.pagedController,
    this.playbackPosition,
    this.onNoteTap,
    this.onNoteTapWithPosition,
    this.onMeasureTap,
    this.onLayoutChanged,
    this.pageWidth = 595,
    this.pageHeight = 842,
    this.pageMargin = 40,
  });

  final Score score;
  final ScoreLayoutMode mode;
  final MusicScoreTheme theme;
  final double staffSpace;
  final double? staffGap;

  /// Engraving width used when the parent axis is unbounded.
  final double? layoutWidth;

  final SmuflMetadata? metadata;
  final ScoreLayoutCache? cache;
  final PagedScoreController? pagedController;
  final ValueListenable<ScorePlaybackPosition?>? playbackPosition;
  final ValueChanged<Note>? onNoteTap;
  final ValueChanged<ScoreNoteTap>? onNoteTapWithPosition;
  final ValueChanged<ScoreMeasureTap>? onMeasureTap;
  final ValueChanged<ScoreLayout>? onLayoutChanged;
  final double pageWidth;
  final double pageHeight;
  final double pageMargin;

  @override
  State<ScoreLayoutView> createState() => _ScoreLayoutViewState();
}

class _ScoreLayoutViewState extends State<ScoreLayoutView> {
  late SmuflMetadata _metadata;
  late Future<void> _metadataFuture;
  ScoreLayout? _lastReportedLayout;

  @override
  void initState() {
    super.initState();
    _setMetadata(widget.metadata);
  }

  @override
  void didUpdateWidget(covariant ScoreLayoutView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.metadata != widget.metadata) {
      _setMetadata(widget.metadata);
    }
  }

  void _setMetadata(SmuflMetadata? metadata) {
    _metadata = metadata ?? SmuflMetadata();
    _metadataFuture = metadata == null
        ? _metadata.load()
        : Future<void>.value();
  }

  void _reportLayout(ScoreLayout layout) {
    if (_lastReportedLayout == layout) return;
    _lastReportedLayout = layout;
    final callback = widget.onLayoutChanged;
    if (callback == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _lastReportedLayout == layout) callback(layout);
    });
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
        if (widget.mode == ScoreLayoutMode.paged) {
          return PagedScoreView(
            score: widget.score,
            theme: widget.theme,
            staffSpace: widget.staffSpace,
            staffGap: widget.staffGap,
            onNoteTap: widget.onNoteTap,
            onNoteTapWithPosition: widget.onNoteTapWithPosition,
            onMeasureTap: widget.onMeasureTap,
            controller: widget.pagedController,
            playbackPosition: widget.playbackPosition,
            metadata: _metadata,
            cache: widget.cache,
            onLayoutChanged: widget.onLayoutChanged,
            pageWidth: widget.pageWidth,
            pageHeight: widget.pageHeight,
            pageMargin: widget.pageMargin,
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final constrainedWidth =
                constraints.hasBoundedWidth && constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : null;
            final width =
                widget.layoutWidth ?? constrainedWidth ?? widget.pageWidth;
            final layout = (widget.cache ?? ScoreLayoutCache.shared).getOrBuild(
              score: widget.score,
              mode: widget.mode,
              metadata: _metadata,
              theme: widget.theme,
              availableWidth: width,
              staffSpace: widget.staffSpace,
              staffGap: widget.staffGap,
              pageWidth: widget.pageWidth,
              pageHeight: widget.pageHeight,
              pageMargin: widget.pageMargin,
            );
            _reportLayout(layout);
            return ScoreLayoutRegion(
              layout: layout,
              playbackPosition: widget.playbackPosition,
              onNoteTap: widget.onNoteTap,
              onNoteTapWithPosition: widget.onNoteTapWithPosition,
              onMeasureTap: widget.onMeasureTap,
            );
          },
        );
      },
    );
  }
}
