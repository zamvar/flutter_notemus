import 'package:flutter_notemus/flutter_notemus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SmuflMetadata metadata;
  late Score score;

  setUpAll(() async {
    metadata = SmuflMetadata();
    await metadata.load();
    score = _score(measureCount: 24, staffCount: 4);
  });

  test('vertical layout wraps dynamically and conserves every measure', () {
    final narrow = ScoreLayout.build(
      score: score,
      mode: ScoreLayoutMode.continuousVertical,
      metadata: metadata,
      theme: const MusicScoreTheme(),
      availableWidth: 360,
      staffSpace: 8,
    );
    final wide = ScoreLayout.build(
      score: score,
      mode: ScoreLayoutMode.continuousVertical,
      metadata: metadata,
      theme: const MusicScoreTheme(),
      availableWidth: 760,
      staffSpace: 8,
    );

    expect(narrow.systems.length, greaterThan(wide.systems.length));
    expect(_measureIndices(narrow), List.generate(24, (index) => index));
    expect(_measureIndices(wide), List.generate(24, (index) => index));
    expect(narrow.painter.debugRenderedNotes.length, 24 * 4 * 4);
    expect(wide.painter.debugRenderedNotes.length, 24 * 4 * 4);
  });

  test('horizontal layout is one natural-width unscaled system', () {
    final layout = ScoreLayout.build(
      score: score,
      mode: ScoreLayoutMode.continuousHorizontal,
      metadata: metadata,
      theme: const MusicScoreTheme(),
      availableWidth: 360,
      staffSpace: 8,
    );

    expect(layout.systems, hasLength(1));
    expect(layout.systems.single.firstMeasureIndex, 0);
    expect(layout.systems.single.lastMeasureIndex, 23);
    expect(layout.systems.single.scale, 1);
    expect(layout.size.width, greaterThan(360));
    expect(layout.painter.debugRenderedNotes.length, 24 * 4 * 4);
  });

  test('paged layout assigns each system to exactly one page', () {
    final layout = ScoreLayout.build(
      score: score,
      mode: ScoreLayoutMode.paged,
      metadata: metadata,
      theme: const MusicScoreTheme(),
      availableWidth: 460,
      staffSpace: 8,
      pageMargin: 32,
    );

    expect(layout.pages.length, greaterThan(1));
    expect(layout.pages.first.headerHeight, greaterThan(0));
    expect(
      layout.pages.skip(1).every((page) => page.headerHeight == 0),
      isTrue,
    );
    expect([
      for (final page in layout.pages)
        for (
          var system = page.firstSystemIndex;
          system <= page.lastSystemIndex;
          system++
        )
          system,
    ], List.generate(layout.systems.length, (index) => index));
    expect(
      layout.pages.every(
        (page) =>
            page.scoreHeight + page.headerHeight <=
            page.contentBounds.height + 0.001,
      ),
      isTrue,
    );
  });

  test('cache reuses equivalent layout requests and separates modes', () {
    final cache = ScoreLayoutCache(maximumEntries: 2);
    ScoreLayout build(ScoreLayoutMode mode) => cache.getOrBuild(
      score: score,
      mode: mode,
      metadata: metadata,
      theme: MusicScoreTheme.standard(),
      availableWidth: 500.1,
      staffSpace: 8,
    );

    final first = build(ScoreLayoutMode.continuousVertical);
    final equivalent = cache.getOrBuild(
      score: score,
      mode: ScoreLayoutMode.continuousVertical,
      metadata: metadata,
      theme: const MusicScoreTheme(),
      availableWidth: 500.2,
      staffSpace: 8,
    );
    final horizontal = build(ScoreLayoutMode.continuousHorizontal);

    expect(identical(first, equivalent), isTrue);
    expect(identical(first, horizontal), isFalse);
    expect(cache.length, 2);
  });

  test('paged layout is stable across viewport widths', () {
    final cache = ScoreLayoutCache();
    final narrow = cache.getOrBuild(
      score: score,
      mode: ScoreLayoutMode.paged,
      metadata: metadata,
      theme: const MusicScoreTheme(),
      availableWidth: 320,
      staffSpace: 8,
    );
    final wide = cache.getOrBuild(
      score: score,
      mode: ScoreLayoutMode.paged,
      metadata: metadata,
      theme: const MusicScoreTheme(),
      availableWidth: 1200,
      staffSpace: 8,
    );

    expect(identical(narrow, wide), isTrue);
    expect(narrow.pageSize, const Size(595, 842));
  });

  test('measure and playhead geometry resolve from the same layout', () {
    final layout = ScoreLayout.build(
      score: score,
      mode: ScoreLayoutMode.continuousVertical,
      metadata: metadata,
      theme: const MusicScoreTheme(),
      availableWidth: 500,
      staffSpace: 8,
    );
    final bounds = layout.measureBoundsForIndex(10);
    final playhead = layout.playbackOffset(
      const ScorePlaybackPosition(measureNumber: 11, beat: 2),
    );

    expect(bounds, isNotNull);
    expect(playhead, isNotNull);
    expect(bounds!.contains(playhead!), isTrue);
  });

  testWidgets('ScoreLayoutView renders vertical and horizontal modes', (
    tester,
  ) async {
    ScoreLayout? reported;
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 320,
          height: 600,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ScoreLayoutView(
              score: score,
              mode: ScoreLayoutMode.continuousHorizontal,
              metadata: metadata,
              staffSpace: 8,
              onLayoutChanged: (layout) => reported = layout,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(reported?.mode, ScoreLayoutMode.continuousHorizontal);
    expect(reported?.systems, hasLength(1));
    expect(
      tester.getSize(find.byType(ScoreLayoutRegion)).width,
      greaterThan(320),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 320,
          height: 600,
          child: ScoreLayoutView(
            score: score,
            mode: ScoreLayoutMode.continuousVertical,
            metadata: metadata,
            staffSpace: 8,
            onLayoutChanged: (layout) => reported = layout,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(reported?.mode, ScoreLayoutMode.continuousVertical);
    expect(reported!.systems.length, greaterThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('paged mode preserves geometry and follows playback pages', (
    tester,
  ) async {
    final controller = PagedScoreController();
    final playback = ValueNotifier<ScorePlaybackPosition?>(null);
    ScoreLayout? reported;
    addTearDown(controller.dispose);
    addTearDown(playback.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 500,
          height: 700,
          child: ScoreLayoutView(
            score: score,
            mode: ScoreLayoutMode.paged,
            metadata: metadata,
            staffSpace: 8,
            staffGap: 64,
            pagedController: controller,
            playbackPosition: playback,
            onLayoutChanged: (layout) => reported = layout,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final layout = reported!;
    expect(layout.mode, ScoreLayoutMode.paged);
    expect(layout.pages.length, greaterThan(1));
    expect(layout.painter.systemBlockHeight, 272);
    expect(controller.pageCount, layout.pages.length);

    final destination = layout.pages.last;
    final measureIndex =
        layout.systems[destination.firstSystemIndex].firstMeasureIndex;
    playback.value = ScorePlaybackPosition(
      measureNumber: measureIndex + 1,
      beat: 1,
    );
    await tester.pumpAndSettle();

    expect(controller.currentPage, destination.index);
  });
}

List<int> _measureIndices(ScoreLayout layout) {
  return [
    for (final system in layout.systems)
      for (
        var measure = system.firstMeasureIndex;
        measure <= system.lastMeasureIndex;
        measure++
      )
        measure,
  ];
}

Score _score({required int measureCount, required int staffCount}) {
  final groups = [
    StaffGroup(
      staves: [
        for (var staffIndex = 0; staffIndex < staffCount; staffIndex++)
          Staff(
            name: 'Voice ${staffIndex + 1}',
            measures: [
              for (
                var measureIndex = 0;
                measureIndex < measureCount;
                measureIndex++
              )
                Measure(number: measureIndex + 1)
                  ..add(TimeSignature(numerator: 4, denominator: 4))
                  ..add(
                    Note(
                      pitch: Pitch(step: 'C', octave: 3 + staffIndex),
                      duration: const Duration(DurationType.quarter),
                    ),
                  )
                  ..add(
                    Note(
                      pitch: Pitch(step: 'D', octave: 3 + staffIndex),
                      duration: const Duration(DurationType.quarter),
                    ),
                  )
                  ..add(
                    Note(
                      pitch: Pitch(step: 'E', octave: 3 + staffIndex),
                      duration: const Duration(DurationType.quarter),
                    ),
                  )
                  ..add(
                    Note(
                      pitch: Pitch(step: 'F', octave: 3 + staffIndex),
                      duration: const Duration(DurationType.quarter),
                    ),
                  ),
            ],
          ),
      ],
    ),
  ];
  return Score(
    title: 'Layout Reference',
    composer: 'Notemus',
    staffGroups: groups,
  );
}
