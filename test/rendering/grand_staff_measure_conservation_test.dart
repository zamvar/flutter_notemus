import 'package:flutter/material.dart';
import 'package:flutter_notemus/flutter_notemus.dart' hide Duration;
import 'package:flutter_notemus/flutter_notemus.dart' as notemus show Duration;
import 'package:flutter_notemus/src/rendering/grand_staff_painter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SmuflMetadata metadata;

  setUpAll(() async {
    metadata = SmuflMetadata();
    await metadata.load();
  });

  test('wrapped systems conserve every multi-voice note', () {
    final fixture = _polyphonicScore(measureCount: 12);
    final painter = GrandStaffPainter(
      groups: fixture.score.staffGroups,
      staffSpace: 10,
      metadata: metadata,
      theme: const MusicScoreTheme(),
      availableWidth: 320,
    );

    expect(painter.systemRanges.length, greaterThan(1));
    expect(
      painter.debugRenderedNotes,
      containsAll(fixture.notes),
      reason: 'No source voice may disappear at a system break.',
    );
    expect(painter.debugRenderedNotes, hasLength(fixture.notes.length));
  });

  test('an explicit later measure range retains its original voices', () {
    final fixture = _polyphonicScore(measureCount: 8);
    final expected = fixture.notesByMeasure[4]!;
    final painter = GrandStaffPainter(
      groups: fixture.score.staffGroups,
      staffSpace: 10,
      metadata: metadata,
      theme: const MusicScoreTheme(),
      availableWidth: 320,
      measureRange: (start: 4, end: 4),
    );

    expect(painter.systemRanges, [(start: 4, end: 4)]);
    expect(painter.debugRenderedNotes, containsAll(expected));
    expect(painter.debugRenderedNotes, hasLength(expected.length));
  });

  test('tuplet chord tones remain renderable and tappable', () {
    final notes = [
      Note(
        pitch: const Pitch(step: 'C', octave: 4),
        duration: const notemus.Duration(DurationType.eighth),
      ),
      Note(
        pitch: const Pitch(step: 'E', octave: 4),
        duration: const notemus.Duration(DurationType.eighth),
      ),
      Note(
        pitch: const Pitch(step: 'D', octave: 4),
        duration: const notemus.Duration(DurationType.eighth),
      ),
      Note(
        pitch: const Pitch(step: 'F', octave: 4),
        duration: const notemus.Duration(DurationType.eighth),
      ),
    ];
    final measure = Measure()
      ..add(Clef(clefType: ClefType.treble))
      ..add(
        Tuplet.triplet(
          elements: [
            Chord(
              notes: notes.take(2).toList(),
              duration: notes.first.duration,
            ),
            notes[2],
            notes[3],
          ],
        ),
      );
    final score = Score.singleStaff(Staff(measures: [measure]));
    final painter = GrandStaffPainter(
      groups: score.staffGroups,
      staffSpace: 10,
      metadata: metadata,
      theme: const MusicScoreTheme(),
      availableWidth: 320,
    );

    expect(painter.debugRenderedNotes, containsAll(notes));
    expect(painter.debugRenderedNotes, hasLength(notes.length));
  });

  test('multi-voice staff keeps its shared bass clef for non-1 voices', () {
    final note = Note(
      pitch: const Pitch(step: 'G', octave: 3),
      duration: const notemus.Duration(DurationType.quarter),
      voice: 5,
    );
    final measure = MultiVoiceMeasure()
      ..add(Clef(clefType: ClefType.bass))
      ..addVoice(Voice(number: 5, elements: [note]));
    final score = Score.singleStaff(Staff(measures: [measure]));
    final painter = GrandStaffPainter(
      groups: score.staffGroups,
      staffSpace: 10,
      metadata: metadata,
      theme: const MusicScoreTheme(),
      availableWidth: 320,
    );

    final elements = painter.debugPositionedElements.single.single;
    expect(elements.map((element) => element.element), contains(isA<Clef>()));
    final positionedNote = elements.firstWhere(
      (element) => identical(element.element, note),
    );
    final bassPosition = StaffPositionCalculator.calculate(
      note.pitch,
      Clef(clefType: ClefType.bass),
    );
    final expectedY = StaffPositionCalculator.toPixelY(bassPosition, 10, 50);
    expect(positionedNote.position.dy, closeTo(expectedY, 0.001));
  });

  testWidgets('paged score keeps original measures across every page', (
    tester,
  ) async {
    final fixture = _polyphonicScore(measureCount: 12);
    final controller = PagedScoreController();
    addTearDown(controller.dispose);
    await tester.binding.setSurfaceSize(const Size(360, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PagedScoreView(
            score: fixture.score,
            controller: controller,
            staffSpace: 10,
            pageWidth: 320,
            pageHeight: 440,
            pageMargin: 24,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.pageCount, greaterThan(1));
    final ranges = <({int start, int end})>{};
    for (var page = 0; page < controller.pageCount; page++) {
      for (final region in tester.widgetList<ScoreLayoutRegion>(
        find.byType(ScoreLayoutRegion),
      )) {
        expect(region.layout.score, same(fixture.score));
        final lastSystem =
            region.lastSystem ?? region.layout.systems.length - 1;
        for (
          var systemIndex = region.firstSystem;
          systemIndex <= lastSystem;
          systemIndex++
        ) {
          final system = region.layout.systems[systemIndex];
          ranges.add((
            start: system.firstMeasureIndex,
            end: system.lastMeasureIndex,
          ));
        }
      }
      if (page + 1 < controller.pageCount) {
        controller.nextPage();
        await tester.pumpAndSettle();
      }
    }

    final renderedMeasureIndices = <int>{
      for (final range in ranges)
        for (var index = range.start; index <= range.end; index++) index,
    };
    expect(renderedMeasureIndices, {
      for (var index = 0; index < 12; index++) index,
    });
  });
}

({Score score, Set<Note> notes, Map<int, Set<Note>> notesByMeasure})
_polyphonicScore({required int measureCount}) {
  final allNotes = Set<Note>.identity();
  final notesByMeasure = <int, Set<Note>>{};
  final measures = <Measure>[];

  for (var measureIndex = 0; measureIndex < measureCount; measureIndex++) {
    final measureNotes = Set<Note>.identity();
    Note note(String step, int octave, DurationType duration) {
      final value = Note(
        pitch: Pitch(step: step, octave: octave),
        duration: notemus.Duration(duration),
      );
      allNotes.add(value);
      measureNotes.add(value);
      return value;
    }

    final leadElements = <MusicalElement>[
      if (measureIndex == 0) Clef(clefType: ClefType.treble),
      if (measureIndex == 0) TimeSignature(numerator: 4, denominator: 4),
      note('C', 5, DurationType.quarter),
      note('D', 5, DurationType.quarter),
      note('E', 5, DurationType.quarter),
      note('F', 5, DurationType.quarter),
    ];
    final measure = MultiVoiceMeasure()
      ..number = measureIndex + 1
      ..addVoice(Voice.voice1(elements: leadElements))
      ..addVoice(
        Voice.voice2(
          elements: [
            note('C', 4, DurationType.half),
            note('G', 3, DurationType.half),
          ],
        ),
      );
    measures.add(measure);
    notesByMeasure[measureIndex] = measureNotes;
  }

  return (
    score: Score(
      staffGroups: [
        StaffGroup(
          staves: [Staff(name: 'Choir', measures: measures)],
          bracket: BracketType.bracket,
        ),
      ],
    ),
    notes: allNotes,
    notesByMeasure: notesByMeasure,
  );
}
