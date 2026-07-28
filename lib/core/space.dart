// lib/core/space.dart

import 'musical_element.dart';
import 'duration.dart';

/// Representa a space empty with duração definida, correspwherendo to the
/// elemento `<space>` of the MEI v5.
///
/// A `<space>` ocupa tempo no measure sem produzir som. Is used for
/// align voices or Createsr paUsess invisíveis in noteção específica.
///
/// ```dart
/// measure.add(Space(duration: const Duration(DurationType.quarter)));
/// ```
class Space extends MusicalElement {
  /// Duração of the space (tempo that ocupa no measure).
  final Duration duration;

  /// Exact occupied time as a fraction of a whole note.
  ///
  /// MusicXML `<forward>` durations are division-based and are not always
  /// representable by a single written [Duration]. The written duration is
  /// retained for spacing, while this value remains authoritative for timing.
  final double musicalValue;

  Space({required this.duration, double? musicalValue})
    : musicalValue = musicalValue ?? duration.realValue,
      assert((musicalValue ?? duration.realValue) >= 0);
}

/// Representa a space de medida inteira (measure completo in siReadsncio),
/// correspwherendo to the elemento `<mSpace>` of the MEI v5.
///
/// used for indicate a measure de paUses in partes orquestrais where
/// o instrumento not toca, sem display a paUses de semibreve normal.
///
/// ```dart
/// measure.add(MeasureSpace());
/// ```
class MeasureSpace extends MusicalElement {
  /// Number de measures de siReadsncio that this elemento representa.
  /// Default = 1. used for paUsess multi-measures comprimidas.
  final int measureCount;

  MeasureSpace({this.measureCount = 1});
}
