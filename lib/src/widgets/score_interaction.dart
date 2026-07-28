import 'package:flutter/widgets.dart';

import '../../core/note.dart';

/// A note tap plus its screen position, used for contextual note feedback.
class ScoreNoteTap {
  const ScoreNoteTap({required this.note, required this.globalPosition});

  final Note note;
  final Offset globalPosition;
}
