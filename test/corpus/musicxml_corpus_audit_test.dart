import 'dart:convert';
import 'dart:io';

import 'package:flutter_notemus/flutter_notemus.dart';
import 'package:flutter_notemus/src/rendering/grand_staff_painter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

const _corpusEnvironmentVariable = 'NOTEMUS_MUSICXML_CORPUS';
const _referenceCorpusPath = 'test/corpus/fixtures';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final corpusPath = Platform.environment[_corpusEnvironmentVariable];
  final files = <String, File>{
    for (final file in _musicXmlFiles(_referenceCorpusPath))
      file.absolute.path: file,
    if (corpusPath != null)
      for (final file in _musicXmlFiles(corpusPath)) file.absolute.path: file,
  }.values.toList();
  late SmuflMetadata metadata;

  setUpAll(() async {
    metadata = SmuflMetadata();
    await metadata.load();
  });

  test('external MusicXML corpus contains readable scores', () {
    if (corpusPath != null) {
      expect(
        Directory(corpusPath).existsSync(),
        isTrue,
        reason: 'Corpus directory does not exist: $corpusPath',
      );
    }
    expect(
      files,
      isNotEmpty,
      reason: 'No MusicXML files found in the reference or external corpus.',
    );
  });

  for (final file in files) {
    test('conserves ${file.path}', () {
      final notemusDocument = NotemusDocument.fromBytes(
        file.readAsBytesSync(),
        sourceFileName: file.path,
      );
      final source = notemusDocument.musicXml;
      final document = XmlDocument.parse(source);
      final sourceStats = _SourceStats.fromDocument(document);
      final score = notemusDocument.score;
      final parsedMeasureCount = score.allStaves.fold<int>(
        0,
        (total, staff) => total + staff.measures.length,
      );
      final parsedNoteCount = _scoreNoteCount(score);
      final midi = MidiMapper.fromScore(score);
      final midiNoteOnCount = midi.tracks
          .expand((track) => track.events)
          .where((event) => event.type == MidiEventType.noteOn)
          .length;
      final painter = GrandStaffPainter(
        groups: score.staffGroups,
        staffSpace: 10,
        metadata: metadata,
        theme: const MusicScoreTheme(),
        availableWidth: 520,
      );
      final renderedNoteCount = painter.debugRenderedNotes.length;
      final parsedStaffNotes = [
        for (var index = 0; index < score.allStaves.length; index++)
          {
            'index': index,
            'name': score.allStaves[index].name,
            'notes': _staffNoteCount(score.allStaves[index]),
          },
      ];

      final report = <String, Object?>{
        'file': file.path,
        'sourceFormat': notemusDocument.sourceFormat.name,
        'software': sourceStats.software,
        'sourceTitle': sourceStats.title,
        'parsedTitle': score.title,
        'sourceParts': sourceStats.partCount,
        'parsedStaves': score.staffCount,
        'sourcePartNotes': sourceStats.partPitchedNoteCounts,
        'parsedStaffNotes': parsedStaffNotes,
        'measureMismatches': _measureMismatches(score, sourceStats),
        'sourceMeasureInstances': sourceStats.expectedMeasureInstances,
        'parsedMeasureInstances': parsedMeasureCount,
        'sourcePitchedNotes': sourceStats.pitchedNoteCount,
        'parsedNotes': parsedNoteCount,
        'renderedNotes': renderedNoteCount,
        'midiNoteOns': midiNoteOnCount,
        'systems': painter.systemRanges.length,
        'backups': sourceStats.backupCount,
        'forwards': sourceStats.forwardCount,
        'tupletNotes': sourceStats.tupletNoteCount,
        'lyrics': sourceStats.lyricCount,
        'midiWarnings': midi.warnings,
      };
      final encodedReport = const JsonEncoder.withIndent('  ').convert(report);
      // This is intentionally machine-readable so reports from multiple
      // exporters can be diffed without committing their source scores.
      // ignore: avoid_print
      print(encodedReport);

      expect(
        parsedMeasureCount,
        sourceStats.expectedMeasureInstances,
        reason: encodedReport,
      );
      expect(
        parsedNoteCount,
        sourceStats.pitchedNoteCount,
        reason: encodedReport,
      );
      expect(renderedNoteCount, parsedNoteCount, reason: encodedReport);
    });
  }
}

List<File> _musicXmlFiles(String rootPath) {
  final root = Directory(rootPath);
  if (!root.existsSync()) return const [];

  final files =
      root
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) {
            final lower = file.path.toLowerCase();
            if (lower.endsWith('.mxl')) return true;
            if (!lower.endsWith('.xml') && !lower.endsWith('.musicxml')) {
              return false;
            }
            try {
              final rootName = XmlDocument.parse(
                file.readAsStringSync(),
              ).rootElement.name.local;
              return rootName == 'score-partwise' ||
                  rootName == 'score-timewise';
            } on XmlParserException {
              return false;
            }
          })
          .toList()
        ..sort((left, right) => left.path.compareTo(right.path));
  return files;
}

int _scoreNoteCount(Score score) {
  return score.allStaves.fold<int>(
    0,
    (count, staff) => count + _staffNoteCount(staff),
  );
}

int _staffNoteCount(Staff staff) {
  return staff.measures.fold<int>(
    0,
    (count, measure) => count + _measureNoteCount(measure),
  );
}

int _measureNoteCount(Measure measure) {
  var count = _elementNoteCount(measure.elements);
  if (measure is MultiVoiceMeasure) {
    for (final voice in measure.voices) {
      count += _elementNoteCount(voice.elements);
    }
  }
  return count;
}

int _elementNoteCount(Iterable<MusicalElement> elements) {
  var count = 0;
  for (final element in elements) {
    if (element is Note) {
      count++;
    } else if (element is Chord) {
      count += element.notes.length;
    } else if (element is Tuplet) {
      count += _elementNoteCount(element.elements);
    }
  }
  return count;
}

class _SourceStats {
  const _SourceStats({
    required this.software,
    required this.title,
    required this.partCount,
    required this.partPitchedNoteCounts,
    required this.partMeasurePitchedNoteCounts,
    required this.expectedMeasureInstances,
    required this.pitchedNoteCount,
    required this.backupCount,
    required this.forwardCount,
    required this.tupletNoteCount,
    required this.lyricCount,
  });

  factory _SourceStats.fromDocument(XmlDocument document) {
    final root = document.rootElement;
    final isPartwise = root.name.local == 'score-partwise';
    final parts = isPartwise
        ? root.findElements('part').toList()
        : root
              .findElements('measure')
              .expand((measure) => measure.findElements('part'))
              .toList();

    var expectedMeasureInstances = 0;
    if (isPartwise) {
      for (final part in parts) {
        var staffCount = 1;
        for (final staves in part.findAllElements('staves')) {
          final value = int.tryParse(staves.innerText.trim());
          if (value != null && value > staffCount) staffCount = value;
        }
        for (final staff in part.findAllElements('staff')) {
          final value = int.tryParse(staff.innerText.trim());
          if (value != null && value > staffCount) staffCount = value;
        }
        expectedMeasureInstances +=
            part.findElements('measure').length * staffCount;
      }
    } else {
      expectedMeasureInstances = parts.length;
    }

    final notes = root.findAllElements('note').toList();
    final partMeasurePitchedNoteCounts = isPartwise
        ? [
            for (final part in parts)
              [
                for (final measure in part.findElements('measure'))
                  measure
                      .findAllElements('note')
                      .where((note) => note.findElements('pitch').isNotEmpty)
                      .length,
              ],
          ]
        : const <List<int>>[];
    return _SourceStats(
      software: root
          .findAllElements('software')
          .map((element) => element.innerText.trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList(),
      title: _firstNonEmpty([
        root.findAllElements('work-title').firstOrNull?.innerText,
        root.findAllElements('movement-title').firstOrNull?.innerText,
        ...root
            .findAllElements('credit-words')
            .map((element) => element.innerText),
      ]),
      partCount: isPartwise
          ? parts.length
          : root
                    .findElements('measure')
                    .firstOrNull
                    ?.findElements('part')
                    .length ??
                0,
      partPitchedNoteCounts: isPartwise
          ? [
              for (final part in parts)
                part
                    .findAllElements('note')
                    .where((note) => note.findElements('pitch').isNotEmpty)
                    .length,
            ]
          : const [],
      partMeasurePitchedNoteCounts: partMeasurePitchedNoteCounts,
      expectedMeasureInstances: expectedMeasureInstances,
      pitchedNoteCount: notes
          .where((note) => note.findElements('pitch').isNotEmpty)
          .length,
      backupCount: root.findAllElements('backup').length,
      forwardCount: root.findAllElements('forward').length,
      tupletNoteCount: notes
          .where((note) => note.findElements('time-modification').isNotEmpty)
          .length,
      lyricCount: root.findAllElements('lyric').length,
    );
  }

  final List<String> software;
  final String? title;
  final int partCount;
  final List<int> partPitchedNoteCounts;
  final List<List<int>> partMeasurePitchedNoteCounts;
  final int expectedMeasureInstances;
  final int pitchedNoteCount;
  final int backupCount;
  final int forwardCount;
  final int tupletNoteCount;
  final int lyricCount;
}

List<Map<String, Object?>> _measureMismatches(
  Score score,
  _SourceStats source,
) {
  if (score.staffGroups.length != source.partMeasurePitchedNoteCounts.length) {
    return const [];
  }

  final mismatches = <Map<String, Object?>>[];
  for (var partIndex = 0; partIndex < score.staffGroups.length; partIndex++) {
    final expectedMeasures = source.partMeasurePitchedNoteCounts[partIndex];
    final staves = score.staffGroups[partIndex].staves;
    for (
      var measureIndex = 0;
      measureIndex < expectedMeasures.length;
      measureIndex++
    ) {
      final actual = staves.fold<int>(
        0,
        (count, staff) =>
            count +
            (measureIndex < staff.measures.length
                ? _measureNoteCount(staff.measures[measureIndex])
                : 0),
      );
      final expected = expectedMeasures[measureIndex];
      if (actual != expected) {
        mismatches.add({
          'part': partIndex + 1,
          'measure': measureIndex + 1,
          'expected': expected,
          'actual': actual,
        });
      }
    }
  }
  return mismatches;
}

String? _firstNonEmpty(Iterable<String?> candidates) {
  for (final candidate in candidates) {
    final value = candidate?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}
