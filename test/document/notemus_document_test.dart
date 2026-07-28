import 'dart:io';

import 'package:flutter_notemus/flutter_notemus.dart';
import 'package:flutter_notemus/src/rendering/grand_staff_painter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fixtureDirectory = 'test/corpus/fixtures/musescore_4_7_4';
  const fixtureNames = [
    'notemus_reference.xml',
    'notemus_reference.musicxml',
    'notemus_reference.mxl',
  ];

  test('all MuseScore containers produce the same canonical document', () {
    final documents = [
      for (final name in fixtureNames)
        NotemusDocument.fromBytes(
          File('$fixtureDirectory/$name').readAsBytesSync(),
          sourceFileName: name,
        ),
    ];

    for (final document in documents) {
      expect(document.metadata.title, 'Notemus Reference');
      expect(document.metadata.subtitle, 'MusicXML Conservation Suite');
      expect(document.metadata.composer, 'Notemus Contributors');
      expect(document.metadata.arranger, 'Codex Test Fixture');
      expect(document.metadata.copyright, 'CC0-1.0');
      expect(document.metadata.software, ['MuseScore Studio 4.7.4']);
      expect(document.score.allStaves, hasLength(3));
      expect(document.measures, hasLength(9));
      expect(document.notes, hasLength(27));
      expect(document.notes.map((note) => note.id).toSet(), hasLength(27));
      expect(
        document.measures.map((measure) => measure.id).toSet(),
        hasLength(9),
      );
    }

    expect(
      documents.map(
        (document) => document.notes.map((note) => note.id).toList(),
      ),
      everyElement(documents.first.notes.map((note) => note.id).toList()),
    );
    expect(documents.last.sourceFormat, NotemusSourceFormat.compressedMusicXml);
  });

  test('credit text replaces MuseScore placeholder metadata', () {
    const xml = '''
<score-partwise version="4.0">
  <work><work-title>Untitled score</work-title></work>
  <identification>
    <creator type="composer">Composer / arranger</creator>
  </identification>
  <credit><credit-words>Steal Away</credit-words></credit>
  <part-list>
    <score-part id="P1"><part-name>Solo</part-name></score-part>
  </part-list>
  <part id="P1">
    <measure number="1"><note><rest/><duration>4</duration></note></measure>
  </part>
</score-partwise>
''';

    final document = NotemusDocument.fromMusicXml(xml);

    expect(document.metadata.title, 'Steal Away');
    expect(document.metadata.composer, isNull);
    expect(document.score.title, 'Steal Away');
    expect(document.score.composer, isNull);
  });

  test('stable references resolve the original parsed objects', () {
    final document = NotemusDocument.fromBytes(
      File('$fixtureDirectory/notemus_reference.mxl').readAsBytesSync(),
      sourceFileName: 'notemus_reference.mxl',
    );

    for (final reference in document.measures) {
      expect(document.measureRef(reference.measure), same(reference));
    }
    for (final reference in document.notes) {
      expect(document.noteRef(reference.note), same(reference));
    }
  });

  test('layout-generated note copies resolve to document identities', () async {
    final document = NotemusDocument.fromBytes(
      File('$fixtureDirectory/notemus_reference.mxl').readAsBytesSync(),
      sourceFileName: 'notemus_reference.mxl',
    );
    final metadata = SmuflMetadata();
    await metadata.load();
    final painter = GrandStaffPainter(
      groups: document.score.staffGroups,
      staffSpace: 10,
      metadata: metadata,
      theme: const MusicScoreTheme(),
      availableWidth: 320,
    );

    for (final renderedNote in painter.debugRenderedNotes) {
      expect(document.noteRef(renderedNote), isNotNull);
    }
  });
}
