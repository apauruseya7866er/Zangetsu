/// Chapter HTML → speakable paragraphs for read-aloud (TTS).
///
/// Pure Dart, no Flutter imports, so it stays unit-testable without pumping
/// a widget. The novel reader's own `_tokenizeHtml` (novel_reader_screen.dart)
/// is display-oriented (bold/italic spans); this is speech-oriented: block
/// boundaries become utterance boundaries, inline styling is dropped, and
/// over-long paragraphs are chunked — every engine caps a single `speak()`
/// call (`flutter_tts.getMaxSpeechInputLength`, ~4000 chars on Android), and
/// a whole chapter in one call would also make progress/follow-scroll jump.
///
/// Mirrors Reikai's `core.js` normalisation (whitespace collapse, empty
/// filtering) adapted from a WebView DOM walk to the raw HTML string.
library;

/// Splits [html] into non-empty normalised paragraphs, chunking any single
/// paragraph longer than [maxChunkLength] on sentence boundaries (hard word
/// split as a last resort). Returns `[]` for empty/markup-only input.
List<String> ttsParagraphsFromHtml(String html, {int maxChunkLength = 1500}) {
  // Same unclosed-tag-safe strip as the reader: an unclosed <script>/<style>
  // still eats through end-of-string instead of leaking into speech.
  final cleaned = html.replaceAll(
    RegExp(
      r'<(script|style)[^>]*>.*?(?:</\1>|$)',
      caseSensitive: false,
      dotAll: true,
    ),
    ' ',
  );
  // Block boundaries become paragraph breaks; <br> a soft one (same split).
  final withBreaks = cleaned.replaceAll(
    RegExp(
      r'</(p|div|h[1-6]|li|blockquote|section|article|tr)[^>]*>|<br[^>]*>',
      caseSensitive: false,
    ),
    '\n',
  );
  final stripped = withBreaks.replaceAll(RegExp(r'<[^>]*>'), '');
  final out = <String>[];
  for (final line in stripped.split('\n')) {
    final text = _collapseWhitespace(_unescapeHtml(line)).trim();
    if (text.isEmpty) continue;
    if (text.length <= maxChunkLength) {
      out.add(text);
    } else {
      out.addAll(_chunkLongParagraph(text, maxChunkLength));
    }
  }
  return out;
}

/// Fraction (0–1) of [paragraphs] already spoken at [index]: cumulative
/// characters, not paragraph count — paragraphs vary wildly in length, so a
/// plain index/count fraction would make follow-scroll jump. Used to drive
/// the reader's scroll position while speaking.
double ttsProgress01(List<String> paragraphs, int index) {
  if (paragraphs.isEmpty) return 0;
  final total = paragraphs.fold<int>(0, (n, p) => n + p.length);
  if (total <= 0) return 0;
  final clamped = index.clamp(0, paragraphs.length);
  var done = 0;
  for (var i = 0; i < clamped; i++) {
    done += paragraphs[i].length;
  }
  return (done / total).clamp(0.0, 1.0);
}

/// Splits one over-long paragraph on sentence boundaries (Latin + CJK
/// terminators), accumulating up to [max] chars per chunk. A single sentence
/// longer than [max] is hard-split on a word boundary so no chunk ever
/// exceeds the engine's per-utterance cap.
List<String> _chunkLongParagraph(String text, int max) {
  final sentences = text.split(
    RegExp(r'(?<=[.!?…。！？])\s+'),
  );
  final chunks = <String>[];
  final current = StringBuffer();
  void flush() {
    final s = _collapseWhitespace(current.toString()).trim();
    if (s.isNotEmpty) chunks.add(s);
    current.clear();
  }

  for (final sentence in sentences) {
    final s = sentence.trim();
    if (s.isEmpty) continue;
    if (s.length > max) {
      flush();
      // Hard-split the monster sentence itself on word boundaries.
      var rest = s;
      while (rest.length > max) {
        var cut = rest.lastIndexOf(' ', max);
        if (cut <= 0) cut = max;
        chunks.add(rest.substring(0, cut).trim());
        rest = rest.substring(cut).trim();
      }
      if (rest.isNotEmpty) {
        current.write(rest);
        current.write(' ');
      }
      continue;
    }
    if (current.length + s.length + 1 > max) flush();
    current.write(s);
    current.write(' ');
  }
  flush();
  return chunks;
}

String _collapseWhitespace(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

const Map<String, String> _htmlEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'mdash': '—',
  'ndash': '–',
  'hellip': '…',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
};

/// Decodes the handful of HTML entities scraped chapter text actually
/// contains (named + numeric). Anything unrecognised — including a numeric
/// reference outside the valid Unicode range — is left as-is rather than
/// crashing, mirroring the reader's own `_unescapeHtml`.
String _unescapeHtml(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);'), (
    m,
  ) {
    final ref = m.group(1)!;
    if (ref.startsWith('#x')) {
      return _charOrRaw(int.tryParse(ref.substring(2), radix: 16), m.group(0)!);
    }
    if (ref.startsWith('#')) {
      return _charOrRaw(int.tryParse(ref.substring(1)), m.group(0)!);
    }
    return _htmlEntities[ref] ?? m.group(0)!;
  });
}

String _charOrRaw(int? code, String raw) {
  if (code == null || code < 0 || code > 0x10FFFF) return raw;
  return String.fromCharCode(code);
}
