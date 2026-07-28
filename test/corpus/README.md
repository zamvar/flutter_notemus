# External MusicXML corpus

The corpus audit compares source MusicXML counts with Notemus parsing, MIDI
generation, and rendered layout counts. Keep commercial or otherwise private
scores outside this repository.

Extract `.mxl` containers into a private directory, then run:

```sh
NOTEMUS_MUSICXML_CORPUS=/path/to/corpus \
  flutter test test/corpus/musicxml_corpus_audit_test.dart --reporter expanded
```

The audit discovers `.xml` and `.musicxml` files recursively. Each report is
printed as JSON so results from MuseScore and other exporters can be compared.
