import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/core.dart';
import '../rendering/grand_staff_painter.dart';
import '../layout/score_layout.dart';
import '../smufl/smufl_metadata_loader.dart';
import '../theme/music_score_theme.dart';
import 'score_interaction.dart';
import 'score_layout_region.dart';

/// Controls page navigation and the zoom transform for [PagedScoreView].
class PagedScoreController extends ChangeNotifier {
  final PageController pageController = PageController();
  final Map<int, TransformationController> _transforms = {};

  int currentPage = 0;
  int pageCount = 0;

  void setPageCount(int count) {
    if (pageCount == count) return;
    pageCount = count;
    if (pageCount > 0 && currentPage >= pageCount) {
      currentPage = pageCount - 1;
    }
    notifyListeners();
  }

  TransformationController transformationFor(int page) {
    return _transforms.putIfAbsent(page, () {
      final controller = TransformationController();
      controller.addListener(() {
        if (page == currentPage) notifyListeners();
      });
      return controller;
    });
  }

  double get currentScale =>
      transformationFor(currentPage).value.getMaxScaleOnAxis();

  void setCurrentPage(int page) {
    currentPage = page;
    notifyListeners();
  }

  void zoomBy(double factor) {
    final next = (currentScale * factor).clamp(1.0, 4.0).toDouble();
    transformationFor(currentPage).value = Matrix4.diagonal3Values(
      next,
      next,
      1.0,
    );
    notifyListeners();
  }

  void resetZoom() {
    transformationFor(currentPage).value = Matrix4.identity();
    notifyListeners();
  }

  void previousPage() {
    if (currentPage > 0) pageController.jumpToPage(currentPage - 1);
  }

  void nextPage() {
    if (currentPage + 1 < pageCount) {
      pageController.jumpToPage(currentPage + 1);
    }
  }

  @override
  void dispose() {
    pageController.dispose();
    for (final transform in _transforms.values) {
      transform.dispose();
    }
    super.dispose();
  }
}

/// Displays a score as a sequence of fixed-ratio paper pages.
///
/// The regular [GrandStaff] layout decides the measure breaks. Those systems
/// are then composed vertically on each page, so the page never has to shrink
/// a tall score into an unreadable strip.
class PagedScoreView extends StatefulWidget {
  final Score score;
  final MusicScoreTheme theme;
  final double staffSpace;
  final double? staffGap;
  final ValueChanged<Note>? onNoteTap;
  final ValueChanged<ScoreNoteTap>? onNoteTapWithPosition;
  final ValueChanged<ScoreMeasureTap>? onMeasureTap;
  final PagedScoreController? controller;
  final ValueListenable<ScorePlaybackPosition?>? playbackPosition;
  final SmuflMetadata? metadata;
  final ScoreLayoutCache? cache;
  final ValueChanged<ScoreLayout>? onLayoutChanged;

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
    this.staffGap,
    this.onNoteTap,
    this.onNoteTapWithPosition,
    this.onMeasureTap,
    this.controller,
    this.playbackPosition,
    this.metadata,
    this.cache,
    this.onLayoutChanged,
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
  late SmuflMetadata _metadata;
  late Future<void> _metadataFuture;
  late PagedScoreController _controller;
  var _ownsController = false;
  ScoreLayout? _layout;
  ScoreLayout? _lastReportedLayout;
  int? _lastPlaybackMeasureNumber;

  @override
  void initState() {
    super.initState();
    _setMetadata(widget.metadata);
    _controller = widget.controller ?? PagedScoreController();
    _ownsController = widget.controller == null;
    widget.playbackPosition?.addListener(_handlePlaybackPosition);
  }

  @override
  void didUpdateWidget(covariant PagedScoreView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.metadata != widget.metadata) {
      _setMetadata(widget.metadata);
    }
    if (oldWidget.controller != widget.controller) {
      if (_ownsController) _controller.dispose();
      _controller = widget.controller ?? PagedScoreController();
      _ownsController = widget.controller == null;
    }
    if (oldWidget.playbackPosition != widget.playbackPosition) {
      oldWidget.playbackPosition?.removeListener(_handlePlaybackPosition);
      widget.playbackPosition?.addListener(_handlePlaybackPosition);
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
  void dispose() {
    widget.playbackPosition?.removeListener(_handlePlaybackPosition);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _handlePlaybackPosition() {
    final position = widget.playbackPosition?.value;
    if (position == null) {
      _lastPlaybackMeasureNumber = null;
      return;
    }
    if (position.measureNumber == _lastPlaybackMeasureNumber ||
        _layout == null) {
      return;
    }
    _lastPlaybackMeasureNumber = position.measureNumber;

    final measureIndex = _measureIndexForNumber(position.measureNumber);
    if (measureIndex == null) return;
    final page = _layout?.pageForMeasureIndex(measureIndex)?.index;
    if (page == null) return;
    if (page == _controller.currentPage || page >= _controller.pageCount) {
      return;
    }
    _jumpToPlaybackPage(page);
  }

  void _jumpToPlaybackPage(int page) {
    void jump() {
      if (!mounted ||
          page >= _controller.pageCount ||
          !_controller.pageController.hasClients) {
        return;
      }
      _controller.pageController.jumpToPage(page);
    }

    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle &&
        _controller.pageController.hasClients) {
      jump();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => jump());
    }
  }

  int? _measureIndexForNumber(int number) {
    var hasExplicitNumber = false;
    for (final staff in widget.score.allStaves) {
      for (var index = 0; index < staff.measures.length; index++) {
        final measureNumber = staff.measures[index].number;
        if (measureNumber != null) hasExplicitNumber = true;
        if (measureNumber == number) return index;
      }
    }
    if (hasExplicitNumber) return null;
    final fallback = number - 1;
    return fallback >= 0 &&
            widget.score.allStaves.isNotEmpty &&
            fallback < widget.score.allStaves.first.measures.length
        ? fallback
        : null;
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
            final maxDisplayWidth =
                constraints.hasBoundedWidth && constraints.maxWidth.isFinite
                ? math.max(1.0, constraints.maxWidth - 24.0)
                : widget.pageWidth;
            final maxDisplayHeight =
                constraints.hasBoundedHeight && constraints.maxHeight.isFinite
                ? math.max(1.0, constraints.maxHeight - 24.0)
                : widget.pageHeight;
            final displayScale = math.min(
              maxDisplayWidth / widget.pageWidth,
              maxDisplayHeight / widget.pageHeight,
            );
            final displaySize = Size(
              widget.pageWidth * displayScale,
              widget.pageHeight * displayScale,
            );

            final layout = (widget.cache ?? ScoreLayoutCache.shared).getOrBuild(
              score: widget.score,
              mode: ScoreLayoutMode.paged,
              metadata: _metadata,
              theme: widget.theme,
              availableWidth: widget.pageWidth,
              staffSpace: widget.staffSpace,
              staffGap: widget.staffGap,
              pageWidth: widget.pageWidth,
              pageHeight: widget.pageHeight,
              pageMargin: widget.pageMargin,
            );
            _layout = layout;
            _reportLayout(layout);
            final height = layout.pageSize.height;
            final pages = layout.pages;
            if (_controller.pageCount != pages.length) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _controller.setPageCount(pages.length);
              });
            }

            return SizedBox(
              height:
                  constraints.hasBoundedHeight && constraints.maxHeight.isFinite
                  ? constraints.maxHeight
                  : height + 24.0,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => PageView.builder(
                  controller: _controller.pageController,
                  itemCount: pages.length,
                  physics: _controller.currentScale > 1.01
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  onPageChanged: _controller.setCurrentPage,
                  itemBuilder: (context, index) => Center(
                    child: SizedBox.fromSize(
                      size: displaySize,
                      child: InteractiveViewer(
                        transformationController: _controller.transformationFor(
                          index,
                        ),
                        minScale: 1.0,
                        maxScale: 4.0,
                        panEnabled: _controller.currentScale > 1.01,
                        scaleEnabled: true,
                        boundaryMargin: const EdgeInsets.all(200),
                        clipBehavior: Clip.hardEdge,
                        child: FittedBox(
                          fit: BoxFit.fill,
                          child: _ScorePage(
                            score: widget.score,
                            layout: layout,
                            page: pages[index],
                            staffSpace: widget.staffSpace,
                            onNoteTap: widget.onNoteTap,
                            onNoteTapWithPosition: widget.onNoteTapWithPosition,
                            onMeasureTap: widget.onMeasureTap,
                            playbackPosition: widget.playbackPosition,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ScorePage extends StatelessWidget {
  final Score score;
  final ScoreLayout layout;
  final ScorePageLayout page;
  final double staffSpace;
  final ValueChanged<Note>? onNoteTap;
  final ValueChanged<ScoreNoteTap>? onNoteTapWithPosition;
  final ValueChanged<ScoreMeasureTap>? onMeasureTap;
  final ValueListenable<ScorePlaybackPosition?>? playbackPosition;

  const _ScorePage({
    required this.score,
    required this.layout,
    required this.page,
    required this.staffSpace,
    required this.onNoteTap,
    required this.onNoteTapWithPosition,
    required this.onMeasureTap,
    required this.playbackPosition,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 2.0,
      child: SizedBox(
        width: page.size.width,
        height: page.size.height,
        child: Padding(
          padding: EdgeInsets.all(layout.pageMargin),
          child: ClipRect(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (page.headerHeight > 0)
                  _ScoreHeader(
                    score: score,
                    width: page.contentBounds.width,
                    staffSpace: staffSpace,
                  ),
                ScoreLayoutRegion(
                  layout: layout,
                  firstSystem: page.firstSystemIndex,
                  lastSystem: page.lastSystemIndex,
                  onNoteTap: onNoteTap,
                  onNoteTapWithPosition: onNoteTapWithPosition,
                  onMeasureTap: onMeasureTap,
                  playbackPosition: playbackPosition,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ScoreHeader extends StatelessWidget {
  final Score score;
  final double width;
  final double staffSpace;

  const _ScoreHeader({
    required this.score,
    required this.width,
    required this.staffSpace,
  });

  @override
  Widget build(BuildContext context) {
    final creditLines = _creditLines();
    return SizedBox(
      width: width,
      height: staffSpace * 12.0,
      child: Stack(
        children: [
          if (score.title?.isNotEmpty == true)
            Align(
              alignment: Alignment.topCenter,
              child: Text(
                score.title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.black,
                  fontSize: staffSpace * 3.0,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if (score.subtitle?.isNotEmpty == true)
            Align(
              alignment: const Alignment(0, 0.2),
              child: Text(
                score.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.black,
                  fontSize: staffSpace * 1.65,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (score.composer?.isNotEmpty == true)
            Align(
              alignment: Alignment.topRight,
              child: Text(
                score.composer!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.black,
                  fontSize: staffSpace * 1.35,
                ),
              ),
            ),
          if (creditLines.isNotEmpty || score.arranger?.isNotEmpty == true)
            Align(
              alignment: Alignment.topLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in creditLines)
                    Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: staffSpace * 1.25,
                      ),
                    ),
                  if (score.arranger?.isNotEmpty == true)
                    Text(
                      'arr. ${score.arranger}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: staffSpace * 1.35,
                      ),
                    ),
                ],
              ),
            ),
          if (score.copyright?.isNotEmpty == true)
            Align(
              alignment: Alignment.bottomCenter,
              child: Text(
                score.copyright!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.black,
                  fontSize: staffSpace * 1.05,
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<String> _creditLines() {
    final raw = score.metadata['creditLines'];
    if (raw is! Iterable) return const [];
    final existing = {
      score.title,
      score.subtitle,
      score.composer,
      score.arranger,
      score.copyright,
    };
    return [
      for (final value in raw.whereType<String>().take(3))
        if (value.trim().isNotEmpty && !existing.contains(value.trim()))
          value.trim(),
    ];
  }
}
