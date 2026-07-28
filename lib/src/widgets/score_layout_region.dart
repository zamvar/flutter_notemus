import 'dart:async' as async;
import 'dart:core';
import 'dart:core' as core;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/note.dart';
import '../layout/score_layout.dart';
import '../rendering/grand_staff_painter.dart';
import 'score_interaction.dart';

/// Paints and interacts with a contiguous subset of one cached [ScoreLayout].
class ScoreLayoutRegion extends StatefulWidget {
  const ScoreLayoutRegion({
    super.key,
    required this.layout,
    this.firstSystem = 0,
    this.lastSystem,
    this.onNoteTap,
    this.onNoteTapWithPosition,
    this.onMeasureTap,
    this.playbackPosition,
  }) : assert(firstSystem >= 0),
       assert(lastSystem == null || lastSystem >= firstSystem);

  final ScoreLayout layout;
  final int firstSystem;
  final int? lastSystem;
  final ValueChanged<Note>? onNoteTap;
  final ValueChanged<ScoreNoteTap>? onNoteTapWithPosition;
  final ValueChanged<ScoreMeasureTap>? onMeasureTap;
  final ValueListenable<ScorePlaybackPosition?>? playbackPosition;

  @override
  State<ScoreLayoutRegion> createState() => _ScoreLayoutRegionState();
}

class _ScoreLayoutRegionState extends State<ScoreLayoutRegion> {
  Note? _lastTappedNote;
  Note? _lastSwipedNote;
  async.Timer? _tapResetTimer;
  final _noteStopwatch = core.Stopwatch()..start();
  var _pointerMoved = false;
  var _lastNoteEventMs = 0;
  _RegionPlaybackPosition? _playbackScope;

  GrandStaffPainter get _painter => widget.layout.painter;
  int get _lastSystem => (widget.lastSystem ?? _painter.systemCount - 1).clamp(
    widget.firstSystem,
    _painter.systemCount - 1,
  );

  @override
  void initState() {
    super.initState();
    _syncPlaybackScope();
  }

  @override
  void didUpdateWidget(covariant ScoreLayoutRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layout != widget.layout ||
        oldWidget.firstSystem != widget.firstSystem ||
        oldWidget.lastSystem != widget.lastSystem ||
        oldWidget.playbackPosition != widget.playbackPosition) {
      _syncPlaybackScope();
    }
  }

  @override
  void dispose() {
    _tapResetTimer?.cancel();
    _playbackScope?.dispose();
    _noteStopwatch.stop();
    super.dispose();
  }

  void _emitNote(Note note, Offset globalPosition) {
    _lastTappedNote = note;
    _tapResetTimer?.cancel();
    _tapResetTimer = async.Timer(const core.Duration(seconds: 5), () {
      if (mounted) _lastTappedNote = null;
    });
    widget.onNoteTap?.call(note);
    widget.onNoteTapWithPosition?.call(
      ScoreNoteTap(note: note, globalPosition: globalPosition),
    );
  }

  void _handleTap(TapUpDetails details) {
    if (_pointerMoved) {
      _pointerMoved = false;
      _lastSwipedNote = null;
      return;
    }
    final measureNumber = _painter.measureAt(
      details.localPosition,
      firstSystem: widget.firstSystem,
      lastSystem: _lastSystem,
    );
    if (measureNumber != null) {
      widget.onMeasureTap?.call(
        ScoreMeasureTap(
          measureNumber: measureNumber,
          globalPosition: details.globalPosition,
        ),
      );
    }
    final note = _painter.noteAt(
      details.localPosition,
      lastNote: _lastTappedNote,
      firstSystem: widget.firstSystem,
      lastSystem: _lastSystem,
    );
    if (note != null) _emitNote(note, details.globalPosition);
  }

  void _handleSwipe(PointerMoveEvent event) {
    if (event.delta.distance < 0.5) return;
    _pointerMoved = true;
    final now = _noteStopwatch.elapsedMilliseconds;
    if (now - _lastNoteEventMs < 80) return;
    final note = _painter.noteAt(
      event.localPosition,
      lastNote: _lastTappedNote,
      firstSystem: widget.firstSystem,
      lastSystem: _lastSystem,
    );
    if (note == null || note == _lastSwipedNote) return;
    _lastSwipedNote = note;
    _lastNoteEventMs = now;
    _emitNote(note, event.position);
  }

  void _syncPlaybackScope() {
    final source = widget.playbackPosition;
    if (source == null || _painter.systemCount == 0) {
      _playbackScope?.dispose();
      _playbackScope = null;
      return;
    }
    if (_playbackScope == null) {
      _playbackScope = _RegionPlaybackPosition(
        source: source,
        painter: _painter,
        firstSystem: widget.firstSystem,
        lastSystem: _lastSystem,
      );
    } else {
      _playbackScope!.update(
        source: source,
        painter: _painter,
        firstSystem: widget.firstSystem,
        lastSystem: _lastSystem,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_painter.systemCount == 0) return const SizedBox.shrink();
    final size = Size(
      _painter.totalWidth,
      _painter.heightForSystemRange(widget.firstSystem, _lastSystem),
    );
    final hasNoteInteraction =
        widget.onNoteTap != null || widget.onNoteTapWithPosition != null;
    return SizedBox.fromSize(
      size: size,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) {
          _pointerMoved = false;
          _lastSwipedNote = null;
        },
        onPointerMove: hasNoteInteraction ? _handleSwipe : null,
        onPointerUp: (_) => _lastSwipedNote = null,
        onPointerCancel: (_) => _lastSwipedNote = null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: hasNoteInteraction || widget.onMeasureTap != null
              ? _handleTap
              : null,
          child: CustomPaint(
            size: size,
            painter: _ScoreLayoutRegionPainter(
              layout: widget.layout,
              firstSystem: widget.firstSystem,
              lastSystem: _lastSystem,
            ),
            foregroundPainter: _playbackScope == null
                ? null
                : _ScoreLayoutPlayheadPainter(
                    layout: widget.layout,
                    firstSystem: widget.firstSystem,
                    lastSystem: _lastSystem,
                    playbackPosition: _playbackScope!,
                  ),
          ),
        ),
      ),
    );
  }
}

class _ScoreLayoutRegionPainter extends CustomPainter {
  const _ScoreLayoutRegionPainter({
    required this.layout,
    required this.firstSystem,
    required this.lastSystem,
  });

  final ScoreLayout layout;
  final int firstSystem;
  final int lastSystem;

  @override
  void paint(Canvas canvas, Size size) {
    layout.painter.paintSystemRange(
      canvas,
      size,
      firstSystem: firstSystem,
      lastSystem: lastSystem,
    );
  }

  @override
  bool shouldRepaint(covariant _ScoreLayoutRegionPainter oldDelegate) {
    return oldDelegate.layout != layout ||
        oldDelegate.firstSystem != firstSystem ||
        oldDelegate.lastSystem != lastSystem;
  }
}

class _ScoreLayoutPlayheadPainter extends CustomPainter {
  _ScoreLayoutPlayheadPainter({
    required this.layout,
    required this.firstSystem,
    required this.lastSystem,
    required this.playbackPosition,
  }) : super(repaint: playbackPosition);

  final ScoreLayout layout;
  final int firstSystem;
  final int lastSystem;
  final ValueListenable<ScorePlaybackPosition?> playbackPosition;

  @override
  void paint(Canvas canvas, Size size) {
    layout.painter.paintPlayheadRange(
      canvas,
      size,
      playbackPosition.value,
      firstSystem: firstSystem,
      lastSystem: lastSystem,
    );
  }

  @override
  bool shouldRepaint(covariant _ScoreLayoutPlayheadPainter oldDelegate) {
    return oldDelegate.layout != layout ||
        oldDelegate.firstSystem != firstSystem ||
        oldDelegate.lastSystem != lastSystem ||
        oldDelegate.playbackPosition != playbackPosition;
  }
}

class _RegionPlaybackPosition extends ValueNotifier<ScorePlaybackPosition?> {
  _RegionPlaybackPosition({
    required ValueListenable<ScorePlaybackPosition?> source,
    required GrandStaffPainter painter,
    required int firstSystem,
    required int lastSystem,
  }) : _source = source,
       _painter = painter,
       _firstSystem = firstSystem,
       _lastSystem = lastSystem,
       super(null) {
    _source.addListener(_sync);
    _sync();
  }

  ValueListenable<ScorePlaybackPosition?> _source;
  GrandStaffPainter _painter;
  int _firstSystem;
  int _lastSystem;

  void update({
    required ValueListenable<ScorePlaybackPosition?> source,
    required GrandStaffPainter painter,
    required int firstSystem,
    required int lastSystem,
  }) {
    if (_source != source) {
      _source.removeListener(_sync);
      _source = source;
      _source.addListener(_sync);
    }
    _painter = painter;
    _firstSystem = firstSystem;
    _lastSystem = lastSystem;
    _sync();
  }

  void _sync() {
    final position = _source.value;
    value =
        _painter.hasPlayhead(
          position,
          firstSystem: _firstSystem,
          lastSystem: _lastSystem,
        )
        ? position
        : null;
  }

  @override
  void dispose() {
    _source.removeListener(_sync);
    super.dispose();
  }
}
