// MusicXML import: directions (crescendo/diminuendo wedges).

import 'package:flutter_notemus/flutter_notemus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String score(String measureBody) =>
      '<score-partwise version="4.0"><part-list><score-part id="P1">'
      '<part-name>Music</part-name></score-part></part-list><part id="P1">'
      '<measure number="1">$measureBody</measure></part></score-partwise>';

  List<Dynamic> dynamicsOf(Staff s) =>
      s.measures.expand((m) => m.elements).whereType<Dynamic>().toList();

  group('MusicXML numbered (nested) slurs', () {
    List<Note> notesOf(Staff s) =>
        s.measures.expand((m) => m.elements).whereType<Note>().toList();

    test('concurrent <slur number=> boundaries are imported by id', () {
      final xml = score(
        '<note><pitch><step>C</step><octave>5</octave></pitch>'
        '<duration>1</duration><type>quarter</type>'
        '<notations><slur type="start" number="1"/></notations></note>'
        '<note><pitch><step>D</step><octave>5</octave></pitch>'
        '<duration>1</duration><type>quarter</type>'
        '<notations><slur type="start" number="2"/></notations></note>'
        '<note><pitch><step>D</step><octave>5</octave></pitch>'
        '<duration>1</duration><type>quarter</type>'
        '<notations><slur type="stop" number="2"/></notations></note>'
        '<note><pitch><step>C</step><octave>5</octave></pitch>'
        '<duration>1</duration><type>quarter</type>'
        '<notations><slur type="stop" number="1"/></notations></note>',
      );
      final notes = notesOf(MusicXMLParser.parseMusicXML(xml));
      expect(notes[0].slurs.single.number, 1);
      expect(notes[0].slurs.single.type, SlurType.start);
      expect(notes[1].slurs.single.number, 2);
      expect(notes[3].slurs.single.number, 1);
      expect(notes[3].slurs.single.type, SlurType.end);
    });
  });

  group('MusicXML cautionary/editorial accidentals', () {
    List<Note> notesOf(Staff s) =>
        s.measures.expand((m) => m.elements).whereType<Note>().toList();

    test(
      'cautionary/parentheses -> parentheses; bracket/editorial -> brackets',
      () {
        final xml = score(
          '<note><pitch><step>C</step><octave>5</octave><alter>1</alter></pitch>'
          '<duration>1</duration><type>quarter</type>'
          '<accidental cautionary="yes">sharp</accidental></note>'
          '<note><pitch><step>A</step><octave>4</octave><alter>-1</alter></pitch>'
          '<duration>1</duration><type>quarter</type>'
          '<accidental bracket="yes">flat</accidental></note>'
          '<note><pitch><step>G</step><octave>4</octave><alter>1</alter></pitch>'
          '<duration>1</duration><type>quarter</type>'
          '<accidental>sharp</accidental></note>',
        );
        final notes = notesOf(MusicXMLParser.parseMusicXML(xml));
        expect(
          notes[0].accidentalParenthesis,
          AccidentalParenthesis.parentheses,
        );
        expect(notes[1].accidentalParenthesis, AccidentalParenthesis.brackets);
        expect(notes[2].accidentalParenthesis, AccidentalParenthesis.none);
      },
    );
  });

  group('MusicXML multi-part / multi-staff import', () {
    List<Note> staffNotes(Staff s) =>
        s.measures.expand((m) => m.elements).whereType<Note>().toList();

    test('each <part> becomes its own staff in the Score (SATB/ensemble)', () {
      const xml =
          '<score-partwise version="4.0"><part-list>'
          '<score-part id="P1"><part-name>Soprano</part-name></score-part>'
          '<score-part id="P2"><part-name>Bass</part-name></score-part>'
          '</part-list>'
          '<part id="P1"><measure number="1">'
          '<note><pitch><step>C</step><octave>5</octave></pitch>'
          '<duration>1</duration><type>quarter</type></note></measure></part>'
          '<part id="P2"><measure number="1">'
          '<note><pitch><step>C</step><octave>3</octave></pitch>'
          '<duration>1</duration><type>quarter</type></note></measure></part>'
          '</score-partwise>';
      final score = MusicXMLParser.scoreFromMusicXML(xml);
      expect(score.allStaves.length, 2);
      expect(staffNotes(score.allStaves[0]).single.pitch.octave, 5);
      expect(staffNotes(score.allStaves[1]).single.pitch.octave, 3);
    });

    test('a 2-staff part (piano) splits by <staff> with per-staff clefs', () {
      const xml =
          '<score-partwise version="4.0"><part-list>'
          '<score-part id="P1"><part-name>Piano</part-name></score-part>'
          '</part-list><part id="P1"><measure number="1">'
          '<attributes><divisions>1</divisions><staves>2</staves>'
          '<clef number="1"><sign>G</sign><line>2</line></clef>'
          '<clef number="2"><sign>F</sign><line>4</line></clef></attributes>'
          '<note><pitch><step>E</step><octave>5</octave></pitch>'
          '<duration>1</duration><type>quarter</type><staff>1</staff></note>'
          '<note><pitch><step>C</step><octave>3</octave></pitch>'
          '<duration>1</duration><type>quarter</type><staff>2</staff></note>'
          '</measure></part></score-partwise>';
      final score = MusicXMLParser.scoreFromMusicXML(xml);
      expect(score.allStaves.length, 2);
      // Treble staff gets the E5 + a G clef; bass staff the C3 + an F clef.
      final s1 = score.allStaves[0];
      final s2 = score.allStaves[1];
      expect(staffNotes(s1).single.pitch.octave, 5);
      expect(staffNotes(s2).single.pitch.octave, 3);
      Clef clefOf(Staff s) => s.measures.first.elements.whereType<Clef>().first;
      expect(clefOf(s1).actualClefType, ClefType.treble);
      expect(clefOf(s2).actualClefType, ClefType.bass);
      // The piano part is one braced StaffGroup (grand staff).
      expect(score.staffGroups.length, 1);
      expect(score.staffGroups.single.bracket, BracketType.brace);
      expect(score.staffGroups.single.staves.length, 2);
    });

    test('a later measure containing only voice 5 is not discarded', () {
      const xml =
          '<score-partwise version="4.0"><part-list>'
          '<score-part id="P1"><part-name>Piano</part-name></score-part>'
          '</part-list><part id="P1">'
          '<measure number="1"><attributes><divisions>1</divisions><staves>2'
          '</staves><clef number="1"><sign>G</sign><line>2</line></clef>'
          '<clef number="2"><sign>F</sign><line>4</line></clef></attributes>'
          '</measure><measure number="2">'
          '<note><pitch><step>C</step><octave>5</octave></pitch>'
          '<duration>1</duration><type>quarter</type><voice>1</voice>'
          '<staff>1</staff></note><backup><duration>1</duration></backup>'
          '<note><pitch><step>C</step><octave>3</octave></pitch>'
          '<duration>1</duration><type>quarter</type><voice>5</voice>'
          '<staff>2</staff></note>'
          '<note><chord/><pitch><step>G</step><octave>3</octave></pitch>'
          '<duration>1</duration><type>quarter</type><voice>5</voice>'
          '<staff>2</staff></note></measure></part></score-partwise>';

      final score = MusicXMLParser.scoreFromMusicXML(xml);
      final lowerMeasure = score.allStaves[1].measures[1];

      expect(lowerMeasure, isA<MultiVoiceMeasure>());
      final voice = (lowerMeasure as MultiVoiceMeasure).getVoice(5);
      expect(voice, isNotNull);
      expect(voice!.elements, hasLength(1));
      expect(voice.elements.single, isA<Chord>());
      expect((voice.elements.single as Chord).notes, hasLength(2));
    });

    test('separate parts become separate staff groups', () {
      const xml =
          '<score-partwise version="4.0"><part-list>'
          '<score-part id="P1"><part-name>Soprano</part-name></score-part>'
          '<score-part id="P2"><part-name>Bass</part-name></score-part>'
          '</part-list>'
          '<part id="P1"><measure number="1">'
          '<note><pitch><step>C</step><octave>5</octave></pitch>'
          '<duration>1</duration><type>quarter</type></note></measure></part>'
          '<part id="P2"><measure number="1">'
          '<note><pitch><step>C</step><octave>3</octave></pitch>'
          '<duration>1</duration><type>quarter</type></note></measure></part>'
          '</score-partwise>';
      final score = MusicXMLParser.scoreFromMusicXML(xml);
      expect(score.staffGroups.length, 2);
      expect(score.staffGroups.every((g) => g.staves.length == 1), isTrue);
    });

    test('a beam crossing staves routes notes to the home staff', () {
      String e8(String s, int o, String beam, int staff) =>
          '<note><pitch><step>$s</step><octave>$o</octave></pitch>'
          '<duration>1</duration><type>eighth</type><voice>1</voice>'
          '<beam number="1">$beam</beam><staff>$staff</staff></note>';
      final xml =
          '<score-partwise version="4.0"><part-list>'
          '<score-part id="P1"><part-name>Piano</part-name></score-part>'
          '</part-list><part id="P1"><measure number="1">'
          '<attributes><divisions>1</divisions><staves>2</staves>'
          '<clef number="1"><sign>G</sign><line>2</line></clef>'
          '<clef number="2"><sign>F</sign><line>4</line></clef></attributes>'
          '${e8('C', 5, 'begin', 1)}${e8('A', 4, 'continue', 1)}'
          '${e8('A', 3, 'continue', 2)}${e8('F', 3, 'end', 2)}'
          '</measure></part></score-partwise>';
      final score = MusicXMLParser.scoreFromMusicXML(xml);
      final group = score.staffGroups.single; // braced piano
      List<Note> notesOf(Staff s) =>
          s.measures.expand((m) => m.elements).whereType<Note>().toList();
      final home = notesOf(group.staves[0]); // treble = beam home
      final bass = notesOf(group.staves[1]);
      // All four notes routed to the home staff so the beam survives.
      expect(home.length, 4);
      expect(bass.length, 0);
      // The two notes written on staff 2 carry a cross-staff move of +1.
      expect(home[0].crossStaffMove, 0);
      expect(home[1].crossStaffMove, 0);
      expect(home[2].crossStaffMove, 1);
      expect(home[3].crossStaffMove, 1);
    });

    test('a <part-group> brackets its member parts into one group', () {
      const xml =
          '<score-partwise version="4.0"><part-list>'
          '<part-group type="start" number="1">'
          '<group-symbol>bracket</group-symbol></part-group>'
          '<score-part id="P1"><part-name>Violin I</part-name></score-part>'
          '<score-part id="P2"><part-name>Violin II</part-name></score-part>'
          '<part-group type="stop" number="1"/>'
          '</part-list>'
          '<part id="P1"><measure number="1">'
          '<note><pitch><step>G</step><octave>4</octave></pitch>'
          '<duration>1</duration><type>quarter</type></note></measure></part>'
          '<part id="P2"><measure number="1">'
          '<note><pitch><step>D</step><octave>4</octave></pitch>'
          '<duration>1</duration><type>quarter</type></note></measure></part>'
          '</score-partwise>';
      final score = MusicXMLParser.scoreFromMusicXML(xml);
      expect(score.staffGroups.length, 1);
      expect(score.staffGroups.single.bracket, BracketType.bracket);
      expect(score.staffGroups.single.staves.length, 2);
    });
  });

  group('MusicXML <wedge> import', () {
    test('crescendo wedge becomes a hairpin Dynamic', () {
      final xml = score(
        '<direction><direction-type><wedge type="crescendo"/></direction-type>'
        '</direction>'
        '<note><pitch><step>C</step><octave>5</octave></pitch>'
        '<duration>1</duration><type>quarter</type></note>'
        '<direction><direction-type><wedge type="stop"/></direction-type>'
        '</direction>',
      );
      final dyns = dynamicsOf(MusicXMLParser.parseMusicXML(xml));
      expect(dyns.length, 1);
      expect(dyns.first.type, DynamicType.crescendo);
      expect(dyns.first.isHairpin, isTrue);
    });

    test('diminuendo wedge becomes a hairpin Dynamic', () {
      final xml = score(
        '<direction><direction-type><wedge type="diminuendo"/></direction-type>'
        '</direction>'
        '<note><pitch><step>C</step><octave>5</octave></pitch>'
        '<duration>1</duration><type>quarter</type></note>',
      );
      final dyns = dynamicsOf(MusicXMLParser.parseMusicXML(xml));
      expect(dyns.length, 1);
      expect(dyns.first.type, DynamicType.diminuendo);
      expect(dyns.first.isHairpin, isTrue);
    });
  });

  group('MusicXML timing semantics', () {
    test('chord tones after a tuplet stop stay in the closing tuplet', () {
      String tripletNote(
        String step, {
        required String tuplet,
        bool chord = false,
      }) {
        return '<note>${chord ? '<chord/>' : ''}'
            '<pitch><step>$step</step><octave>4</octave></pitch>'
            '<duration>4</duration><voice>1</voice><type>eighth</type>'
            '<time-modification><actual-notes>3</actual-notes>'
            '<normal-notes>2</normal-notes></time-modification>'
            '<notations>$tuplet</notations></note>';
      }

      final xml = score(
        '<attributes><divisions>12</divisions>'
        '<time><beats>1</beats><beat-type>4</beat-type></time></attributes>'
        '${tripletNote('C', tuplet: '<tuplet type="start"/>')}'
        '${tripletNote('E', tuplet: '', chord: true)}'
        '${tripletNote('D', tuplet: '')}'
        '${tripletNote('F', tuplet: '', chord: true)}'
        '${tripletNote('E', tuplet: '<tuplet type="stop"/>')}'
        '${tripletNote('G', tuplet: '', chord: true)}',
      );

      final staff = MusicXMLParser.parseMusicXML(xml);
      final measure = staff.measures.single;
      final tuplet = measure.elements.whereType<Tuplet>().single;
      final midi = MidiMapper.fromStaff(staff);

      expect(measure.elements, hasLength(2));
      expect(tuplet.elements, hasLength(3));
      expect(tuplet.elements, everyElement(isA<Chord>()));
      expect(
        tuplet.elements.whereType<Chord>().map((chord) => chord.notes.length),
        everyElement(2),
      );
      expect(midi.warnings, isEmpty);
      expect(midi.totalTicks, 960);
    });

    test('<sound tempo> becomes an authoritative tempo mark', () {
      final xml = score(
        '<direction><direction-type><words>Andante</words></direction-type>'
        '<sound tempo="72"/></direction>'
        '<note><pitch><step>C</step><octave>4</octave></pitch>'
        '<duration>4</duration><type>whole</type></note>',
      );

      final staff = MusicXMLParser.parseMusicXML(xml);
      final tempo = staff.measures.single.elements
          .whereType<TempoMark>()
          .single;
      final midi = MidiMapper.fromStaff(staff);
      final tempoEvents = midi.tracks
          .expand((track) => track.events)
          .where((event) => event.type == MidiEventType.tempo)
          .toList();

      expect(tempo.bpm, 72);
      expect(tempo.showMetronome, isFalse);
      expect(tempoEvents.any((event) => event.bpm == 72), isTrue);
    });

    test('<forward> preserves a late entrance in a non-default voice', () {
      const xml =
          '<score-partwise version="4.0"><part-list>'
          '<score-part id="P1"><part-name>Voice</part-name></score-part>'
          '</part-list><part id="P1"><measure number="1">'
          '<attributes><divisions>2</divisions>'
          '<time><beats>4</beats><beat-type>4</beat-type></time></attributes>'
          '<note><pitch><step>C</step><octave>4</octave></pitch>'
          '<duration>8</duration><voice>1</voice><type>whole</type></note>'
          '<backup><duration>8</duration></backup>'
          '<forward><duration>3</duration><voice>3</voice></forward>'
          '<note><pitch><step>E</step><octave>4</octave></pitch>'
          '<duration>1</duration><voice>3</voice><type>eighth</type></note>'
          '</measure></part></score-partwise>';

      final staff = MusicXMLParser.parseMusicXML(xml);
      final measure = staff.measures.single as MultiVoiceMeasure;
      final delayedVoice = measure.getVoice(3)!;
      final space = delayedVoice.elements.first as Space;
      final midi = MidiMapper.fromStaff(staff);
      final delayedNoteOn = midi.tracks
          .expand((track) => track.events)
          .singleWhere(
            (event) => event.type == MidiEventType.noteOn && event.note == 64,
          );

      expect(space.musicalValue, 0.375);
      expect(delayedVoice.elements.last, isA<Note>());
      expect(delayedNoteOn.tick, 1440);
    });
  });
}
