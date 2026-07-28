import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../core/core.dart';
import '../parsers/musicxml_parser.dart';

enum NotemusSourceFormat { musicXml, compressedMusicXml }

class NotemusMetadata {
  const NotemusMetadata({
    this.title,
    this.subtitle,
    this.composer,
    this.arranger,
    this.lyricist,
    this.copyright,
    this.creditLines = const [],
    this.software = const [],
  });

  final String? title;
  final String? subtitle;
  final String? composer;
  final String? arranger;
  final String? lyricist;
  final String? copyright;
  final List<String> creditLines;
  final List<String> software;
}

class NotemusMeasureRef {
  const NotemusMeasureRef({
    required this.id,
    required this.staffIndex,
    required this.measureIndex,
    required this.number,
    required this.measure,
  });

  final String id;
  final int staffIndex;
  final int measureIndex;
  final int? number;
  final Measure measure;
}

class NotemusNoteRef {
  const NotemusNoteRef({
    required this.id,
    required this.measureId,
    required this.staffIndex,
    required this.measureIndex,
    required this.voiceNumber,
    required this.note,
  });

  final String id;
  final String measureId;
  final int staffIndex;
  final int measureIndex;
  final int voiceNumber;
  final Note note;
}

/// One canonical parse result shared by rendering, interaction, and playback.
class NotemusDocument {
  NotemusDocument._({
    required this.musicXml,
    required this.sourceFormat,
    required this.sourceFileName,
    required this.metadata,
    required this.score,
    required this.measures,
    required this.notes,
  }) : _measureRefs = {
         for (final reference in measures) reference.measure: reference,
       },
       _noteRefs = {for (final reference in notes) reference.note: reference},
       _noteRefsById = {for (final reference in notes) reference.id: reference};

  factory NotemusDocument.fromMusicXml(
    String musicXml, {
    String? sourceFileName,
    String? fallbackTitle,
  }) {
    return NotemusDocument._parse(
      _stripBom(musicXml),
      sourceFormat: NotemusSourceFormat.musicXml,
      sourceFileName: sourceFileName,
      fallbackTitle: fallbackTitle,
    );
  }

  factory NotemusDocument.fromBytes(
    Uint8List bytes, {
    String? sourceFileName,
    String? fallbackTitle,
  }) {
    final compressed =
        _hasZipSignature(bytes) ||
        sourceFileName?.toLowerCase().endsWith('.mxl') == true;
    final musicXml = compressed
        ? _extractCompressedMusicXml(bytes)
        : _decodeXmlBytes(bytes);
    return NotemusDocument._parse(
      musicXml,
      sourceFormat: compressed
          ? NotemusSourceFormat.compressedMusicXml
          : NotemusSourceFormat.musicXml,
      sourceFileName: sourceFileName,
      fallbackTitle: fallbackTitle,
    );
  }

  factory NotemusDocument._parse(
    String musicXml, {
    required NotemusSourceFormat sourceFormat,
    required String? sourceFileName,
    required String? fallbackTitle,
  }) {
    final xmlDocument = XmlDocument.parse(musicXml);
    final rootName = xmlDocument.rootElement.name.local;
    if (rootName != 'score-partwise' && rootName != 'score-timewise') {
      throw FormatException(
        'MusicXML root must be score-partwise or score-timewise, not $rootName.',
      );
    }

    final metadata = _extractMetadata(
      xmlDocument,
      fallbackTitle: fallbackTitle,
    );
    final parsedScore = MusicXMLParser.scoreFromMusicXML(musicXml);
    final score = Score(
      title: metadata.title,
      subtitle: metadata.subtitle,
      composer: metadata.composer,
      arranger: metadata.arranger,
      copyright: metadata.copyright,
      staffGroups: parsedScore.staffGroups,
      metadata: {
        ...parsedScore.metadata,
        'creditLines': metadata.creditLines,
        'software': metadata.software,
        if (metadata.lyricist != null) 'lyricist': metadata.lyricist,
      },
      pageLayout: parsedScore.pageLayout,
      meiHeader: parsedScore.meiHeader,
      scoreDefinition: parsedScore.scoreDefinition,
    );
    final references = _buildReferences(score);

    return NotemusDocument._(
      musicXml: musicXml,
      sourceFormat: sourceFormat,
      sourceFileName: sourceFileName,
      metadata: metadata,
      score: score,
      measures: references.measures,
      notes: references.notes,
    );
  }

  final String musicXml;
  final NotemusSourceFormat sourceFormat;
  final String? sourceFileName;
  final NotemusMetadata metadata;
  final Score score;
  final List<NotemusMeasureRef> measures;
  final List<NotemusNoteRef> notes;
  final Map<Measure, NotemusMeasureRef> _measureRefs;
  final Map<Note, NotemusNoteRef> _noteRefs;
  final Map<String, NotemusNoteRef> _noteRefsById;

  NotemusMeasureRef? measureRef(Measure measure) => _measureRefs[measure];

  NotemusNoteRef? noteRef(Note note) {
    return _noteRefs[note] ??
        (note.xmlId == null ? null : _noteRefsById[note.xmlId]);
  }
}

({List<NotemusMeasureRef> measures, List<NotemusNoteRef> notes})
_buildReferences(Score score) {
  final measures = <NotemusMeasureRef>[];
  final notes = <NotemusNoteRef>[];
  final seenNotes = Set<Note>.identity();

  for (var staffIndex = 0; staffIndex < score.allStaves.length; staffIndex++) {
    final staff = score.allStaves[staffIndex];
    for (
      var measureIndex = 0;
      measureIndex < staff.measures.length;
      measureIndex++
    ) {
      final measure = staff.measures[measureIndex];
      final measureId = 'staff-${staffIndex + 1}:measure-${measureIndex + 1}';
      measures.add(
        NotemusMeasureRef(
          id: measureId,
          staffIndex: staffIndex,
          measureIndex: measureIndex,
          number: measure.number,
          measure: measure,
        ),
      );

      void addElements(
        Iterable<MusicalElement> elements, {
        required int voiceNumber,
        required String container,
      }) {
        var eventIndex = 0;

        void addElement(MusicalElement element, String path) {
          if (element is Note) {
            if (!seenNotes.add(element)) return;
            final id = '$measureId:voice-$voiceNumber:$path';
            element.xmlId ??= id;
            notes.add(
              NotemusNoteRef(
                id: id,
                measureId: measureId,
                staffIndex: staffIndex,
                measureIndex: measureIndex,
                voiceNumber: voiceNumber,
                note: element,
              ),
            );
          } else if (element is Chord) {
            for (var index = 0; index < element.notes.length; index++) {
              addElement(element.notes[index], '$path:chord-${index + 1}');
            }
          } else if (element is Tuplet) {
            for (var index = 0; index < element.elements.length; index++) {
              addElement(element.elements[index], '$path:tuplet-${index + 1}');
            }
          }
        }

        for (final element in elements) {
          addElement(element, '$container-event-${eventIndex + 1}');
          eventIndex++;
        }
      }

      addElements(measure.elements, voiceNumber: 1, container: 'measure');
      if (measure is MultiVoiceMeasure) {
        for (final voice in measure.sortedVoices) {
          addElements(
            voice.elements,
            voiceNumber: voice.number,
            container: 'voice',
          );
        }
      }
    }
  }

  return (
    measures: List.unmodifiable(measures),
    notes: List.unmodifiable(notes),
  );
}

NotemusMetadata _extractMetadata(
  XmlDocument document, {
  String? fallbackTitle,
}) {
  final root = document.rootElement;
  final creditLines = _uniqueCleanedValues(
    root.findAllElements('credit-words').map((element) => element.innerText),
  );
  final software = _uniqueCleanedValues(
    root.findAllElements('software').map((element) => element.innerText),
    removePlaceholders: false,
  );
  final workTitle = _cleanMetadata(
    root.findAllElements('work-title').firstOrNull?.innerText,
  );
  final movementTitle = _cleanMetadata(
    root.findAllElements('movement-title').firstOrNull?.innerText,
  );

  String? creator(String type) {
    return _cleanMetadata(
      root
          .findAllElements('creator')
          .where((element) => element.getAttribute('type') == type)
          .firstOrNull
          ?.innerText,
    );
  }

  return NotemusMetadata(
    title:
        workTitle ??
        movementTitle ??
        creditLines.firstOrNull ??
        _cleanMetadata(fallbackTitle),
    subtitle: movementTitle == workTitle ? null : movementTitle,
    composer: creator('composer'),
    arranger: creator('arranger'),
    lyricist: creator('lyricist') ?? creator('poet'),
    copyright: _cleanMetadata(
      root.findAllElements('rights').firstOrNull?.innerText,
    ),
    creditLines: List.unmodifiable(creditLines),
    software: List.unmodifiable(software),
  );
}

List<String> _uniqueCleanedValues(
  Iterable<String?> values, {
  bool removePlaceholders = true,
}) {
  final seen = <String>{};
  final result = <String>[];
  for (final rawValue in values) {
    final value = removePlaceholders
        ? _cleanMetadata(rawValue)
        : _cleanValue(rawValue);
    if (value != null && seen.add(value)) result.add(value);
  }
  return result;
}

String? _cleanMetadata(String? value) {
  final cleaned = _cleanValue(value);
  if (cleaned == null || _isPlaceholder(cleaned)) return null;
  return cleaned;
}

String? _cleanValue(String? value) {
  final cleaned = value?.trim().replaceAll(RegExp(r'\s+'), ' ');
  return cleaned == null || cleaned.isEmpty ? null : cleaned;
}

bool _isPlaceholder(String value) {
  final normalized = value.toLowerCase();
  return normalized == 'untitled' ||
      normalized == 'untitled score' ||
      normalized == 'composer' ||
      normalized == 'arranger' ||
      normalized == 'composer / arranger';
}

bool _hasZipSignature(Uint8List bytes) {
  return bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4b &&
      ((bytes[2] == 0x03 && bytes[3] == 0x04) ||
          (bytes[2] == 0x05 && bytes[3] == 0x06) ||
          (bytes[2] == 0x07 && bytes[3] == 0x08));
}

String _extractCompressedMusicXml(Uint8List bytes) {
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: true);
  } on Object catch (error) {
    throw FormatException('Invalid compressed MusicXML archive: $error');
  }

  final files = {
    for (final file in archive.where((entry) => entry.isFile))
      _normalizeArchivePath(file.name): file,
  };
  String? rootPath;
  final container = files.entries
      .where((entry) => entry.key.toLowerCase() == 'meta-inf/container.xml')
      .firstOrNull
      ?.value;
  if (container != null) {
    try {
      final containerDocument = XmlDocument.parse(
        _decodeXmlBytes(_archiveBytes(container)),
      );
      rootPath = containerDocument
          .findAllElements('rootfile')
          .firstOrNull
          ?.getAttribute('full-path');
    } on Object catch (error) {
      throw FormatException('Invalid MXL container.xml: $error');
    }
  }

  ArchiveFile? scoreFile;
  if (rootPath != null && rootPath.trim().isNotEmpty) {
    scoreFile = files[_normalizeArchivePath(rootPath)];
    if (scoreFile == null) {
      throw FormatException(
        'MXL rootfile does not exist in the archive: $rootPath',
      );
    }
  } else {
    scoreFile = files.entries
        .where((entry) {
          final path = entry.key.toLowerCase();
          return !path.startsWith('meta-inf/') &&
              (path.endsWith('.xml') || path.endsWith('.musicxml'));
        })
        .firstOrNull
        ?.value;
  }

  if (scoreFile == null) {
    throw const FormatException(
      'MXL archive does not contain a MusicXML score.',
    );
  }
  return _decodeXmlBytes(_archiveBytes(scoreFile));
}

Uint8List _archiveBytes(ArchiveFile file) {
  return file.content;
}

String _normalizeArchivePath(String path) {
  final segments = <String>[];
  for (final segment in path.replaceAll(r'\', '/').split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isEmpty) {
        throw FormatException('Archive path escapes its root: $path');
      }
      segments.removeLast();
      continue;
    }
    segments.add(segment);
  }
  return segments.join('/');
}

String _decodeXmlBytes(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
    final codeUnits = <int>[];
    for (var index = 2; index + 1 < bytes.length; index += 2) {
      codeUnits.add(bytes[index] | (bytes[index + 1] << 8));
    }
    return String.fromCharCodes(codeUnits);
  }
  if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
    final codeUnits = <int>[];
    for (var index = 2; index + 1 < bytes.length; index += 2) {
      codeUnits.add((bytes[index] << 8) | bytes[index + 1]);
    }
    return String.fromCharCodes(codeUnits);
  }
  return _stripBom(utf8.decode(bytes));
}

String _stripBom(String value) {
  return value.startsWith('\ufeff') ? value.substring(1) : value;
}
