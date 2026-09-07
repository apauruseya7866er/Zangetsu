import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tts/novel_tts_text.dart';

void main() {
  group('ttsParagraphsFromHtml', () {
    test('splits block tags into paragraphs and strips inline markup', () {
      const html =
          '<p>First <b>bold</b> paragraph.</p>'
          '<p>Second <i>italic</i> one.</p>';
      expect(ttsParagraphsFromHtml(html), [
        'First bold paragraph.',
        'Second italic one.',
      ]);
    });

    test('treats br and div boundaries as breaks', () {
      const html = '<div>Top</div>Bottom<br>line';
      expect(ttsParagraphsFromHtml(html), ['Top', 'Bottom', 'line']);
    });

    test('drops script/style blocks and their contents', () {
      const html =
          '<style>p { color: red; }</style>'
          '<p>Real text.</p>'
          '<script>readItAloud = true;</script>';
      expect(ttsParagraphsFromHtml(html), ['Real text.']);
    });

    test('an unclosed script tag still eats through end-of-string', () {
      const html = '<p>Before.</p><script>var x = 1;';
      expect(ttsParagraphsFromHtml(html), ['Before.']);
    });

    test('unescapes entities and collapses whitespace', () {
      const html = '<p>Tom &amp; Jerry&nbsp;&nbsp;said &ldquo;hi&rdquo;.</p>';
      expect(ttsParagraphsFromHtml(html), ['Tom & Jerry said “hi”.']);
    });

    test('leaves unknown entities alone instead of mangling them', () {
      const html = '<p>Weird &bogus; stays.</p>';
      expect(ttsParagraphsFromHtml(html), ['Weird &bogus; stays.']);
    });

    test('drops empty paragraphs', () {
      const html = '<p>  </p><p>Kept.</p><p></p><br><p>Also kept.</p>';
      expect(ttsParagraphsFromHtml(html), ['Kept.', 'Also kept.']);
    });

    test('empty or markup-only input yields no paragraphs', () {
      expect(ttsParagraphsFromHtml(''), isEmpty);
      expect(ttsParagraphsFromHtml('<p></p><div><br></div>'), isEmpty);
      expect(ttsParagraphsFromHtml('<style>a{}</style>'), isEmpty);
    });

    test('chunks an over-long paragraph on sentence boundaries', () {
      final long = List.filled(
        10,
        'This is sentence number one in a very long paragraph. ',
      ).join();
      final chunks = ttsParagraphsFromHtml(long, maxChunkLength: 100);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(100));
      }
      // Nothing lost: rejoining recovers every sentence.
      expect(chunks.join(' '), contains('sentence number one'));
    });

    test('hard-splits a single over-long sentence on word boundaries', () {
      final words = List.filled(60, 'word').join(' ');
      final chunks = ttsParagraphsFromHtml(
        '<p>$words</p>',
        maxChunkLength: 50,
      );
      expect(chunks, isNotEmpty);
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(50));
      }
      expect(chunks.join(' ').split(' ').length, words.split(' ').length);
    });
  });

  group('ttsProgress01', () {
    test('weights by characters, not paragraph count', () {
      final paras = ['ab', 'abcdefgh']; // 2 + 8 chars
      expect(ttsProgress01(paras, 0), 0.0);
      expect(ttsProgress01(paras, 1), closeTo(0.2, 0.0001));
      expect(ttsProgress01(paras, 2), 1.0);
    });

    test('empty input is zero and indices clamp', () {
      expect(ttsProgress01(const [], 0), 0.0);
      expect(ttsProgress01(['a'], 99), 1.0);
      expect(ttsProgress01(['a'], -5), 0.0);
    });
  });
}
