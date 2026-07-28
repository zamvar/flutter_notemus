import 'dart:core' hide Duration;
import 'dart:core' as core;
import 'dart:io';

import 'package:flutter_notemus/flutter_notemus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlaybackPlan', () {
    test('MuseScore XML, MusicXML, and MXL produce the same plan', () {
      const fixtureDirectory = 'test/corpus/fixtures/musescore_4_7_4';
      final plans = [
        for (final extension in ['xml', 'musicxml', 'mxl'])
          PlaybackPlan.fromDocument(
            NotemusDocument.fromBytes(
              File(
                '$fixtureDirectory/notemus_reference.$extension',
              ).readAsBytesSync(),
              sourceFileName: 'notemus_reference.$extension',
            ),
          ),
      ];

      List<Object> measureSignature(PlaybackPlan plan) {
        return [
          for (final measure in plan.measures)
            (
              measure.sourceMeasureIndex,
              measure.repeatPass,
              measure.startTick,
              measure.endTick,
            ),
        ];
      }

      List<Object> noteSignature(PlaybackPlan plan) {
        return [
          for (final note in plan.noteOccurrences)
            (
              note.sourceNoteId,
              note.staffIndex,
              note.voiceNumber,
              note.startTick,
            ),
        ];
      }

      for (final plan in plans.skip(1)) {
        expect(measureSignature(plan), measureSignature(plans.first));
        expect(noteSignature(plan), noteSignature(plans.first));
        expect(plan.tempoChanges.every((tempo) => tempo.bpm == 72), isTrue);
        expect(plan.tempoChanges.first.tick, 0);
      }
      expect(
        plans.first.noteOccurrences.every(
          (occurrence) => occurrence.sourceNoteId.isNotEmpty,
        ),
        isTrue,
      );
      expect(
        plans.first.noteEvents.every((event) => event.sourceNoteId != null),
        isTrue,
      );
      expect(
        plans.first.noteEvents
            .singleWhere(
              (event) => event.midiNote == 79 && event.startTick == 4800,
            )
            .sourceNoteId,
        isNotNull,
      );
    });

    test('one staff repeat order drives every staff', () {
      Note whole(String step, int octave) => Note(
        pitch: Pitch(step: step, octave: octave),
        duration: const Duration(DurationType.whole),
      );

      final top = Staff(
        measures: [
          Measure()
            ..add(TimeSignature(numerator: 4, denominator: 4))
            ..add(Barline(type: BarlineType.repeatForward))
            ..add(whole('C', 4)),
          Measure()
            ..add(VoltaBracket(number: 1, length: 0))
            ..add(whole('D', 4))
            ..add(Barline(type: BarlineType.repeatBackward)),
          Measure()
            ..add(VoltaBracket(number: 2, length: 0))
            ..add(whole('E', 4)),
        ],
      );
      final lower = Staff(
        measures: [
          Measure()..add(whole('G', 3)),
          Measure()..add(whole('A', 3)),
          Measure()..add(whole('B', 3)),
        ],
      );
      final plan = PlaybackPlan.fromScore(
        Score(
          staffGroups: [
            StaffGroup(staves: [top, lower]),
          ],
        ),
      );

      expect(
        plan.measures
            .map((measure) => (measure.sourceMeasureIndex, measure.repeatPass))
            .toList(),
        [(0, 1), (1, 1), (0, 2), (2, 1)],
      );
      expect(
        plan.noteEvents
            .where((event) => event.staffIndex == 1)
            .map((event) => event.midiNote)
            .toList(),
        [55, 57, 55, 59],
      );
    });

    test('tempo changes convert ticks to wall-clock time', () {
      final measure = Measure()
        ..add(TempoMark(beatUnit: DurationType.quarter, bpm: 60))
        ..add(
          Note(
            pitch: const Pitch(step: 'C', octave: 4),
            duration: const Duration(DurationType.quarter),
          ),
        )
        ..add(TempoMark(beatUnit: DurationType.quarter, bpm: 120))
        ..add(
          Note(
            pitch: const Pitch(step: 'D', octave: 4),
            duration: const Duration(DurationType.quarter),
          ),
        );
      final plan = PlaybackPlan.fromScore(
        Score.singleStaff(Staff(measures: [measure])),
      );

      expect(
        plan.tempoChanges.map((tempo) => (tempo.tick, tempo.bpm)).toList(),
        [(0, 60), (960, 120)],
      );
      expect(plan.durationAtTick(960).inMilliseconds, 1000);
      expect(plan.durationAtTick(1920).inMilliseconds, 1500);
      expect(plan.tickAt(const core.Duration(milliseconds: 1250)), 1440);
      expect(
        plan.noteEvents.map((event) => event.start.inMilliseconds).toList(),
        [0, 1000],
      );
    });

    test('MusicXML tuplet timing advances before the following note', () {
      const musicXml = '''
<score-partwise version="4.0">
  <part-list>
    <score-part id="P1"><part-name>Voice</part-name></score-part>
  </part-list>
  <part id="P1">
    <measure number="1">
      <attributes>
        <divisions>3</divisions>
        <time><beats>4</beats><beat-type>4</beat-type></time>
      </attributes>
      <direction>
        <direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>60</per-minute></metronome></direction-type>
      </direction>
      <note>
        <pitch><step>C</step><octave>4</octave></pitch>
        <duration>1</duration><voice>1</voice><type>eighth</type>
        <time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>
        <notations><tuplet type="start"/></notations>
      </note>
      <note>
        <pitch><step>D</step><octave>4</octave></pitch>
        <duration>1</duration><voice>1</voice><type>eighth</type>
        <time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>
      </note>
      <note>
        <pitch><step>E</step><octave>4</octave></pitch>
        <duration>1</duration><voice>1</voice><type>eighth</type>
        <time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>
        <notations><tuplet type="stop"/></notations>
      </note>
      <note>
        <pitch><step>F</step><octave>4</octave></pitch>
        <duration>3</duration><voice>1</voice><type>quarter</type>
      </note>
    </measure>
  </part>
</score-partwise>
''';
      final plan = PlaybackPlan.fromDocument(
        NotemusDocument.fromMusicXml(musicXml),
      );

      expect(plan.noteEvents.map((event) => event.startTick).toList(), [
        0,
        320,
        640,
        960,
      ]);
      expect(plan.noteEvents.map((event) => event.midiNote).toList(), [
        60,
        62,
        64,
        65,
      ]);
      expect(
        plan.noteEvents.map((event) => event.start.inMilliseconds).toList(),
        [0, 333, 666, 1000],
      );
      expect(
        plan.noteEvents.every((event) => event.sourceNoteId != null),
        isTrue,
      );
    });

    test('MusicXML metronome beat unit is normalized to quarter-note BPM', () {
      const musicXml = '''
<score-partwise version="4.0">
  <part-list>
    <score-part id="P1"><part-name>Voice</part-name></score-part>
  </part-list>
  <part id="P1">
    <measure number="1">
      <attributes>
        <divisions>1</divisions>
        <time><beats>4</beats><beat-type>4</beat-type></time>
      </attributes>
      <direction>
        <direction-type><metronome><beat-unit>half</beat-unit><per-minute>60</per-minute></metronome></direction-type>
      </direction>
      <note>
        <pitch><step>C</step><octave>4</octave></pitch>
        <duration>1</duration><voice>1</voice><type>quarter</type>
      </note>
    </measure>
  </part>
</score-partwise>
''';
      final plan = PlaybackPlan.fromDocument(
        NotemusDocument.fromMusicXml(musicXml),
      );

      expect(plan.tempoChanges.first.bpm, 120);
      expect(plan.noteEvents.single.start.inMilliseconds, 0);
      expect(plan.durationAtTick(960).inMilliseconds, 500);
    });

    test('implicit MusicXML pickup uses its exact source duration', () {
      const musicXml = '''
<score-partwise version="4.0">
  <part-list>
    <score-part id="P1"><part-name>Voice</part-name></score-part>
  </part-list>
  <part id="P1">
    <measure number="0" implicit="yes">
      <attributes>
        <divisions>4</divisions>
        <time><beats>4</beats><beat-type>4</beat-type></time>
      </attributes>
      <note>
        <pitch><step>C</step><octave>4</octave></pitch>
        <duration>4</duration><voice>1</voice><type>quarter</type>
      </note>
    </measure>
    <measure number="1">
      <note>
        <pitch><step>D</step><octave>4</octave></pitch>
        <duration>16</duration><voice>1</voice><type>whole</type>
      </note>
    </measure>
  </part>
</score-partwise>
''';
      final document = NotemusDocument.fromMusicXml(musicXml);
      final plan = PlaybackPlan.fromDocument(document);

      expect(document.score.allStaves.single.measures.first.isImplicit, isTrue);
      expect(
        document.score.allStaves.single.measures.first.sourceDuration,
        0.25,
      );
      expect(plan.measures.first.endTick, 960);
      expect(plan.measures.last.startTick, 960);
      expect(plan.noteEvents.map((event) => event.startTick), [0, 960]);
    });

    test('positions and seeking use repeat-expanded occurrences', () {
      final first = Measure()
        ..add(TimeSignature(numerator: 4, denominator: 4))
        ..add(Barline(type: BarlineType.repeatForward))
        ..add(
          Note(
            pitch: const Pitch(step: 'C', octave: 4),
            duration: const Duration(DurationType.whole),
          ),
        );
      final second = Measure()
        ..add(
          Note(
            pitch: const Pitch(step: 'D', octave: 4),
            duration: const Duration(DurationType.whole),
          ),
        )
        ..add(Barline(type: BarlineType.repeatBackward));
      final plan = PlaybackPlan.fromScore(
        Score.singleStaff(Staff(measures: [first, second])),
      );

      expect(plan.occurrencesForMeasure(0).length, 2);
      expect(plan.timeForMeasure(0), core.Duration.zero);
      expect(
        plan.timeForMeasure(0, occurrence: 1),
        const core.Duration(seconds: 4),
      );
      final position = plan.positionAt(const core.Duration(milliseconds: 4500));
      expect(position?.measure.sourceMeasureIndex, 0);
      expect(position?.measure.repeatPass, 2);
      expect(position?.beat, closeTo(2, 0.001));
    });
  });
}
