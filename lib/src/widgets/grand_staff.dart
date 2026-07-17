// lib/src/widgets/grand_staff.dart
//
// Public widget that renders a multi-staff system (grand staff / ensemble) from
// a [StaffGroup]: the staves are stacked vertically, aligned on a shared
// horizontal grid, and connected by a brace/bracket and continuous barlines.

import 'dart:async' as async;
import 'dart:core';
import 'dart:core' as core;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/core.dart';
import '../rendering/grand_staff_painter.dart';
import '../smufl/smufl_metadata_loader.dart';
import '../theme/music_score_theme.dart';

/// A note tap plus its screen position, used for contextual note feedback.
class ScoreNoteTap {
  final Note note;
  final Offset globalPosition;

  const ScoreNoteTap({required this.note, required this.globalPosition});
}

/// Renders a whole [Score] — each of its [StaffGroup]s as a [GrandStaff],
/// stacked vertically. A single-group score (piano, SATB) renders as one
/// grand staff; a multi-group score (e.g. choir + piano) stacks the groups.
///
/// ```dart
/// ScoreView(score: MusicXMLParser.scoreFromMusicXML(xml));
/// ```
class ScoreView extends StatelessWidget {
  final Score score;
  final MusicScoreTheme theme;
  final double staffSpace;
  final ValueChanged<Note>? onNoteTap;

  const ScoreView({
    super.key,
    required this.score,
    this.theme = const MusicScoreTheme(),
    this.staffSpace = 12.0,
    this.onNoteTap,
  });

  @override
  Widget build(BuildContext context) {
    final groups = score.staffGroups;
    if (groups.isEmpty) return const SizedBox.shrink();
    // All groups on one unified horizontal grid (a true multi-section system).
    return GrandStaff(
      groups: groups,
      theme: theme,
      staffSpace: staffSpace,
      onNoteTap: onNoteTap,
    );
  }
}

/// Renders a [StaffGroup] as a vertically-stacked, horizontally-aligned system
/// (e.g. a piano grand staff or an SATB / ensemble group).
///
/// ```dart
/// GrandStaff(
///   group: StaffGroup(
///     staves: [trebleStaff, bassStaff],
///     bracket: BracketType.brace,
///   ),
/// )
/// ```
///
/// Wraps into stacked systems when the music is wider than one line. For a
/// single staff use [MusicScore] instead; for a whole [Score] use [ScoreView].
class GrandStaff extends StatefulWidget {
  /// The staves (and their brace/bracket) to render together. Provide this or
  /// [groups].
  final StaffGroup? group;

  /// Multiple groups rendered on one unified grid (ensemble / full score).
  final List<StaffGroup>? groups;

  /// Visual theme.
  final MusicScoreTheme theme;

  /// Staff space in logical pixels.
  final double staffSpace;

  /// Baseline-to-baseline vertical distance between adjacent staves. Defaults
  /// to 11 staff spaces (a comfortable grand-staff gap).
  final double? staffGap;

  /// Called when the user taps the notehead of a rendered note.
  ///
  /// The callback receives the original [Note] from the parsed score, so
  /// callers can use its pitch, lyric, voice, and other musical data without
  /// maintaining a second visual layout.
  final ValueChanged<Note>? onNoteTap;

  /// Reuses metadata loaded by a parent document renderer.
  final SmuflMetadata? metadata;

  /// Called with the tapped note and its global screen position.
  final ValueChanged<ScoreNoteTap>? onNoteTapWithPosition;

  /// Repaint-only playback cursor for the rendered system.
  final ValueListenable<ScorePlaybackPosition?>? playbackPosition;

  const GrandStaff({
    super.key,
    this.group,
    this.groups,
    this.theme = const MusicScoreTheme(),
    this.staffSpace = 12.0,
    this.staffGap,
    this.onNoteTap,
    this.metadata,
    this.onNoteTapWithPosition,
    this.playbackPosition,
  }) : assert(
         group != null || groups != null,
         'Provide either group or groups',
       );

  List<StaffGroup> get _groups => groups ?? [group!];

  @override
  State<GrandStaff> createState() => _GrandStaffState();
}

class _GrandStaffState extends State<GrandStaff> {
  late Future<void> _metadataFuture;
  late SmuflMetadata _metadata;
  Note? _lastTappedNote;
  Note? _lastSwipedNote;
  async.Timer? _tapResetTimer;
  final _noteStopwatch = core.Stopwatch()..start();
  var _pointerMoved = false;
  var _lastNoteEventMs = 0;
  _ScopedPlaybackPosition? _playheadScope;

  @override
  void initState() {
    super.initState();
    _metadata = widget.metadata ?? SmuflMetadata();
    _metadataFuture = widget.metadata == null
        ? _metadata.load()
        : Future<void>.value();
  }

  @override
  void didUpdateWidget(covariant GrandStaff oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.metadata != widget.metadata && widget.metadata != null) {
      _metadata = widget.metadata!;
      _metadataFuture = Future<void>.value();
    }
  }

  @override
  void dispose() {
    _tapResetTimer?.cancel();
    _playheadScope?.dispose();
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

  void _handleNoteTap(TapUpDetails details, GrandStaffPainter painter) {
    if (_pointerMoved) {
      _pointerMoved = false;
      _lastSwipedNote = null;
      return;
    }
    final note = painter.noteAt(
      details.localPosition,
      lastNote: _lastTappedNote,
    );
    if (note == null) return;

    _emitNote(note, details.globalPosition);
  }

  void _handleNoteSwipe(PointerMoveEvent event, GrandStaffPainter painter) {
    if (event.delta.distance < 0.5) return;
    _pointerMoved = true;
    final now = _noteStopwatch.elapsedMilliseconds;
    if (now - _lastNoteEventMs < 80) return;

    final note = painter.noteAt(event.localPosition, lastNote: _lastTappedNote);
    if (note == null || note == _lastSwipedNote) return;
    _lastSwipedNote = note;
    _lastNoteEventMs = now;
    _emitNote(note, event.position);
  }

  double get _gap => widget.staffGap ?? widget.staffSpace * 11.0;

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
            child: Text('Failed to load metadata: ${snapshot.error}'),
          );
        }
        if (widget._groups.every((g) => g.staves.isEmpty)) {
          return const SizedBox.shrink();
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final width =
                constraints.hasBoundedWidth && constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 800.0;
            // Build the painter first so we can size to its (multi-system) height.
            final painter = GrandStaffPainter(
              groups: widget._groups,
              staffSpace: widget.staffSpace,
              metadata: _metadata,
              theme: widget.theme,
              availableWidth: width,
              staffGap: _gap,
            );
            final sourcePlaybackPosition = widget.playbackPosition;
            if (sourcePlaybackPosition == null) {
              _playheadScope?.dispose();
              _playheadScope = null;
            } else if (_playheadScope == null) {
              _playheadScope = _ScopedPlaybackPosition(
                source: sourcePlaybackPosition,
                layout: painter,
              );
            } else {
              _playheadScope!.update(
                source: sourcePlaybackPosition,
                layout: painter,
              );
            }
            final playheadScope = _playheadScope;
            final height = painter.totalHeight;
            return SizedBox(
              width: width,
              height: height,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) {
                  _pointerMoved = false;
                  _lastSwipedNote = null;
                },
                onPointerMove:
                    widget.onNoteTap == null &&
                        widget.onNoteTapWithPosition == null
                    ? null
                    : (event) => _handleNoteSwipe(event, painter),
                onPointerUp: (_) => _lastSwipedNote = null,
                onPointerCancel: (_) => _lastSwipedNote = null,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp:
                      widget.onNoteTap == null &&
                          widget.onNoteTapWithPosition == null
                      ? null
                      : (details) => _handleNoteTap(details, painter),
                  child: CustomPaint(
                    size: Size(width, height),
                    painter: painter,
                    foregroundPainter: playheadScope == null
                        ? null
                        : _ScorePlayheadPainter(
                            layout: painter,
                            playbackPosition: playheadScope,
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

class _ScorePlayheadPainter extends CustomPainter {
  final GrandStaffPainter layout;
  final ValueListenable<ScorePlaybackPosition?> playbackPosition;

  _ScorePlayheadPainter({required this.layout, required this.playbackPosition})
    : super(repaint: playbackPosition);

  @override
  void paint(Canvas canvas, Size size) =>
      layout.paintPlayhead(canvas, size, playbackPosition.value);

  @override
  bool shouldRepaint(covariant _ScorePlayheadPainter oldDelegate) {
    return oldDelegate.layout != layout ||
        oldDelegate.playbackPosition != playbackPosition;
  }
}

class _ScopedPlaybackPosition extends ValueNotifier<ScorePlaybackPosition?> {
  ValueListenable<ScorePlaybackPosition?> _source;
  GrandStaffPainter _layout;

  _ScopedPlaybackPosition({
    required ValueListenable<ScorePlaybackPosition?> source,
    required GrandStaffPainter layout,
  }) : _source = source,
       _layout = layout,
       super(null) {
    _source.addListener(_sync);
    _sync();
  }

  void update({
    required ValueListenable<ScorePlaybackPosition?> source,
    required GrandStaffPainter layout,
  }) {
    if (_source != source) {
      _source.removeListener(_sync);
      _source = source;
      _source.addListener(_sync);
    }
    _layout = layout;
    _sync();
  }

  void _sync() {
    final position = _source.value;
    value = _layout.hasPlayhead(position) ? position : null;
  }

  @override
  void dispose() {
    _source.removeListener(_sync);
    super.dispose();
  }
}
