import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../reading/reader_prefs.dart';
import 'novel_tts_text.dart';

/// Read-aloud playback state for the novel reader — the Flutter analogue of
/// Reikai's `TtsPlayback` (novel reader only; manga has no text to speak).
enum NovelTtsPlayback { stopped, playing, paused }

/// Owns the OS TTS engine for one novel chapter and walks the chapter's
/// paragraphs, one utterance at a time.
///
/// Design mirrors Reikai's `NovelTtsController`: the engine speaks a single
/// chunk with QUEUE_FLUSH and reports completion, and THIS class owns the
/// iteration (next paragraph, end-of-chapter auto-advance) — no native queue,
/// so pause/resume/skip stay exact. Pause is stop-and-remember-position
/// (like Reikai's `pause-speak`): resume re-speaks the interrupted paragraph
/// from its start, which works identically on Android and iOS without
/// depending on the engine's partial pause support.
///
/// Public methods are synchronous fire-and-forget (state flips immediately,
/// engine calls run unawaited inside) so widget wiring stays trivial
/// (`onPressed: _tts.toggle`) with no `unawaited` dance at call sites.
class NovelTtsController extends ChangeNotifier {
  NovelTtsController({
    required ReaderPrefs prefs,
    FlutterTts? engine,
    this.onChapterEnd,
  }) : _prefs = prefs,
       _engine = engine;

  final ReaderPrefs _prefs;

  /// Fired when the last paragraph finishes while auto-advance is on — the
  /// reader changes chapter, and the fresh chapter auto-starts via
  /// [setSource]. Null (or auto-advance off) means stop at chapter end.
  final void Function()? onChapterEnd;

  FlutterTts? _engine;
  List<String> _paragraphs = const [];
  NovelTtsPlayback _playback = NovelTtsPlayback.stopped;
  int _index = 0;

  /// Bumps on every stop/play so a late completion callback from a cancelled
  /// utterance can't advance the new run.
  int _generation = 0;

  /// Armed at chapter end when auto-advance fires; consumed by the next
  /// [setSource], which starts speaking the new chapter on its own.
  bool _autoStartPending = false;
  bool _disposed = false;

  List<Map<String, String>>? _voicesCache;
  List<String>? _languagesCache;
  List<Map<String, String>>? _enginesCache;

  NovelTtsPlayback get playback => _playback;
  bool get isPlaying => _playback == NovelTtsPlayback.playing;
  bool get isActive => _playback != NovelTtsPlayback.stopped;
  bool get hasContent => _paragraphs.isNotEmpty;
  int get index => _index;
  int get count => _paragraphs.length;

  /// First ~120 chars of the paragraph being read, for status rows.
  String get currentSnippet {
    if (_paragraphs.isEmpty) return '';
    final p = _paragraphs[_index.clamp(0, _paragraphs.length - 1)];
    return p.length <= 120 ? p : '${p.substring(0, 120)}…';
  }

  /// Character-weighted progress through the chapter — drives follow-scroll
  /// without jumping on short/long paragraphs. See [ttsProgress01].
  double get progress01 => ttsProgress01(_paragraphs, _index);

  /// Loads a chapter's HTML, replacing any previous source. Starts speaking
  /// immediately only when an auto-advance armed it (see [onChapterEnd]);
  /// a manual chapter change just loads and stays stopped.
  void setSource({required String html}) {
    _generation++;
    _paragraphs = ttsParagraphsFromHtml(html);
    _index = 0;
    _setPlayback(NovelTtsPlayback.stopped);
    if (_autoStartPending) {
      _autoStartPending = false;
      if (_paragraphs.isNotEmpty) play();
    }
  }

  /// Drops a pending auto-start without playing — the load-error path, so a
  /// failed next chapter doesn't leave a stale arm that fires on a later one.
  void cancelAutoStart() => _autoStartPending = false;

  void play() {
    if (_paragraphs.isEmpty || _disposed) return;
    if (_playback == NovelTtsPlayback.playing) return;
    _index = _index.clamp(0, _paragraphs.length - 1);
    _setPlayback(NovelTtsPlayback.playing);
    unawaited(_speakCurrent());
  }

  void pause() {
    if (_playback != NovelTtsPlayback.playing) return;
    _generation++;
    _setPlayback(NovelTtsPlayback.paused);
    unawaited(_cancelUtterance());
  }

  void toggle() {
    if (_playback == NovelTtsPlayback.playing) {
      pause();
    } else {
      play();
    }
  }

  void stop() {
    _generation++;
    _index = 0;
    _setPlayback(NovelTtsPlayback.stopped);
    unawaited(_cancelUtterance());
  }

  /// Skips to the next paragraph, staying in the current play state: while
  /// playing the next paragraph starts at once, while paused/stopped only
  /// the position moves.
  void nextParagraph() {
    if (_paragraphs.isEmpty) return;
    _generation++;
    _index = (_index + 1).clamp(0, _paragraphs.length - 1);
    notifyListeners();
    if (_playback == NovelTtsPlayback.playing) unawaited(_speakCurrent());
  }

  void prevParagraph() {
    if (_paragraphs.isEmpty) return;
    _generation++;
    _index = (_index - 1).clamp(0, _paragraphs.length - 1);
    notifyListeners();
    if (_playback == NovelTtsPlayback.playing) unawaited(_speakCurrent());
  }

  /// Re-applies rate/pitch/voice/language/engine — call after the settings
  /// sheet writes new prefs so a running voice changes without restarting.
  void refreshSettings() {
    _voicesCache = null;
    // Never throws (the whole body is guarded) — safe to fire and forget.
    unawaited(_applySettings());
  }

  /// Cached voice list (`name` + `locale` per entry), sorted by locale.
  /// Empty when the engine reports none (or isn't reachable, e.g. tests).
  Future<List<Map<String, String>>> voices() async {
    final cached = _voicesCache;
    if (cached != null) return cached;
    try {
      final engine = await _ensureEngine();
      final raw = await engine?.getVoices as List<dynamic>? ?? const [];
      final out = <Map<String, String>>[];
      for (final v in raw) {
        if (v is! Map) continue;
        final name = v['name']?.toString() ?? '';
        if (name.isEmpty) continue;
        out.add({'name': name, 'locale': v['locale']?.toString() ?? ''});
      }
      out.sort((a, b) {
        final c = a['locale']!.compareTo(b['locale']!);
        return c != 0 ? c : a['name']!.compareTo(b['name']!);
      });
      _voicesCache = out;
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Cached language tags (`en-US`, …), sorted. Empty when unreachable.
  Future<List<String>> languages() async {
    final cached = _languagesCache;
    if (cached != null) return cached;
    try {
      final engine = await _ensureEngine();
      final raw = await engine?.getLanguages as List<dynamic>? ?? const [];
      final out = raw
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList()
        ..sort();
      _languagesCache = out;
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Cached Android engine packages (`name` + `label`). Always empty on iOS
  /// (the getter throws there) — callers hide the engine row when empty.
  Future<List<Map<String, String>>> engines() async {
    final cached = _enginesCache;
    if (cached != null) return cached;
    try {
      final engine = await _ensureEngine();
      final raw = await engine?.getEngines as List<dynamic>? ?? const [];
      final out = <Map<String, String>>[];
      for (final e in raw) {
        if (e is Map) {
          final name = e['name']?.toString() ?? '';
          if (name.isEmpty) continue;
          out.add({'name': name, 'label': e['label']?.toString() ?? name});
        } else if (e.toString().isNotEmpty) {
          out.add({'name': e.toString(), 'label': e.toString()});
        }
      }
      _enginesCache = out;
      return out;
    } catch (_) {
      return const [];
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(_cancelUtterance());
    super.dispose();
  }

  // ── internals ─────────────────────────────────────────────────────────

  /// Best-effort utterance cancel — never throws, so stop/pause/dispose stay
  /// safe to call from any state, including widget tests with no engine.
  Future<void> _cancelUtterance() async {
    try {
      await _engine?.stop();
    } catch (_) {
      // No engine / already gone — the state flip already happened.
    }
  }

  void _setPlayback(NovelTtsPlayback value) {
    if (_playback == value) return;
    _playback = value;
    notifyListeners();
  }

  Future<FlutterTts?> _ensureEngine() async {
    var engine = _engine;
    if (engine == null) {
      try {
        engine = FlutterTts();
      } catch (_) {
        return null;
      }
      _engine = engine;
      try {
        await engine.awaitSpeakCompletion(true);
      } catch (_) {
        // Non-fatal: without it, completion still fires on most engines.
      }
      engine.setStartHandler(() {});
      engine.setCompletionHandler(_onUtteranceDone);
      engine.setCancelHandler(() {});
      engine.setErrorHandler((_) {
        // An engine error mid-chapter: stop rather than spin through every
        // remaining paragraph failing the same way.
        if (_disposed) return;
        _generation++;
        _setPlayback(NovelTtsPlayback.stopped);
      });
    }
    await _applySettings();
    return _engine;
  }

  Future<void> _applySettings() async {
    try {
      final engine = _engine;
      if (engine == null || _disposed) return;
      final language = _prefs.ttsLanguage;
      if (language.isNotEmpty) await engine.setLanguage(language);
      final voice = _prefs.ttsVoice;
      if (voice.isNotEmpty) {
        final map = {'name': voice};
        final locale = _prefs.ttsVoiceLocale;
        if (locale.isNotEmpty) map['locale'] = locale;
        await engine.setVoice(map);
      }
      await engine.setSpeechRate(_prefs.ttsRate);
      await engine.setPitch(_prefs.ttsPitch);
      final enginePackage = _prefs.ttsEngine;
      // setEngine throws on iOS; a missing voice/language must never kill
      // playback either — the engine falls back to its default.
      if (enginePackage.isNotEmpty) await engine.setEngine(enginePackage);
    } catch (_) {
      // Best-effort: prefs reads and engine writes both stay non-fatal.
    }
  }

  Future<void> _speakCurrent() async {
    final generation = _generation;
    try {
      final engine = await _ensureEngine();
      if (_disposed ||
          engine == null ||
          generation != _generation ||
          _playback != NovelTtsPlayback.playing) {
        return;
      }
      if (_index < 0 || _index >= _paragraphs.length) {
        _finishChapter();
        return;
      }
      await engine.speak(_paragraphs[_index]);
    } catch (_) {
      if (!_disposed && generation == _generation) {
        _generation++;
        _setPlayback(NovelTtsPlayback.stopped);
      }
    }
  }

  void _onUtteranceDone() {
    if (_disposed || _playback != NovelTtsPlayback.playing) return;
    if (_index + 1 < _paragraphs.length) {
      _index++;
      notifyListeners();
      unawaited(_speakCurrent());
    } else {
      _finishChapter();
    }
  }

  void _finishChapter() {
    _generation++;
    _setPlayback(NovelTtsPlayback.stopped);
    // Prefs reads stay inside try/catch: this runs off a platform callback,
    // where a throw would propagate into the engine instead of the UI.
    var advance = false;
    try {
      advance = _prefs.ttsAutoAdvance && onChapterEnd != null;
    } catch (_) {
      advance = false;
    }
    if (!advance) return;
    _autoStartPending = true;
    try {
      onChapterEnd!.call();
    } catch (_) {
      _autoStartPending = false;
    }
  }
}
