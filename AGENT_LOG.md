# Agent Log — Zangetsu fork (apauruseya7866er)

> Persistent running log for AI-assisted work on this fork. Every change lands
> in a commit on `origin` (this fork) so it can be reviewed and reverted.
> Per `AI_POLICY.md`, AI-assisted logic is disclosed here and in PR text.

## Remotes

- `origin` → `https://github.com/apauruseya7866er/Zangetsu` (this fork — push here)
- `upstream` → `https://github.com/Spyou/Zangetsu` (original — read-only)

## 2026-09-07 — Novel reader read-aloud (TTS), modeled on Reikai

**AI assistance:** fully drafted by AI (Muse Spark via OpenCode), then verified
with a real toolchain (see Verification). No Reikai code copied.

**Toolchain (installed 2026-09-08 on this machine):**

- Flutter 3.47.2 stable → `C:\Users\James\flutter\flutter` (on User PATH)
- Android cmdline-tools (build `13114758`) → `%LOCALAPPDATA%\Android\Sdk`
- `flutter config --jdk-dir` → Temurin JDK 21 (Gradle 8.14 rejects the
  Java 25 that was first on PATH)
- Note: ProtonVPN was active and its DNS flapped, forcing several Gradle
  retries (`No such host` / timeouts on Maven Central). Retrying was enough.

**Verification (ran 2026-09-08):**

- `flutter pub get` — ok (`+ flutter_tts 4.2.5`)
- `flutter analyze <tts files>` — **No issues found** (repo-wide run shows
  only pre-existing infos/warnings)
- `flutter test test/reading/novel_tts_text_test.dart` — **12/12 pass**;
  all other pure unit tests in `test/reading/` pass too
- Widget tests in `test/features/reader/novel_reader_test.dart` fail on this
  machine with `quickjs_c_bridge.dll` missing — **proven pre-existing** by
  running the same test on the pristine pre-TTS commit (identical failure).
- `flutter build apk --release` — **ok**,
  `build/app/outputs/flutter-apk/app-release.apk` (78.5MB, debug-signed)

**Revert:** `git revert <commit>` — or per-file,

**Reference:** https://github.com/unseensnick/Reikai (native Android/Kotlin,
not Flutter). Studied its TTS end-to-end (cloned to temp during research):
`NovelTtsEngine` seam + `SystemTtsEngine` (Android `TextToSpeech`,
`QUEUE_FLUSH` single utterance, `UtteranceProgressListener` chaining),
`NovelTtsController` state machine (`Stopped/Playing/Paused`,
`startPending/autoStartPending/suppressStopOnce`), JS paragraph iteration with
highlight in the novel WebView, draggable puck (tap toggle, long-press stop,
dim while playing), settings (engine/voice/language-filter/rate 0.1–3.0/
pitch 0.1–2.0/auto-page-advance/scroll-to-top), foreground `mediaPlayback`
service + `MediaSession` notification. No Reikai code copied — clean-room Dart
reimplementation against `flutter_tts`; credited in `NOTICE.md` per
`AI_POLICY.md` §3.

**What was built (novel reader only, like Reikai — manga has no text):**

- `pubspec.yaml`: added `flutter_tts: ^4.2.5` (latest on pub.dev at the time).
  `pubspec.lock` is stale until `flutter pub get` runs (no toolchain here).
- `lib/core/tts/novel_tts_text.dart` (new, pure Dart): chapter HTML →
  speakable paragraphs (block breaks, script/style strip incl. unclosed-tag
  safe, entity unescape, whitespace collapse), over-long paragraphs chunked
  on sentence boundaries (CJK-aware) with word-boundary hard split, plus
  char-weighted `ttsProgress01` for follow-scroll.
- `lib/core/tts/novel_tts_controller.dart` (new): `NovelTtsPlayback`
  state machine; single-utterance iteration with `awaitSpeakCompletion`;
  pause = stop-and-remember-position (works identically on Android/iOS);
  `stop()` resets to paragraph 0; generation counter kills stale completion
  callbacks; end-of-chapter auto-advance via `onChapterEnd` + arm/consume
  flag; cached `voices()`/`languages()`/`engines()`; all engine/prefs calls
  non-throwing; public API sync fire-and-forget (`unawaited` inside, per repo
  lint custom).
- `lib/core/reading/reader_prefs.dart`: `ttsRate` (0.1–3.0), `ttsPitch`
  (0.1–2.0), `ttsLanguage`, `ttsVoice`+`ttsVoiceLocale`, `ttsEngine`,
  `ttsAutoAdvance` (default off), `ttsFollowScroll` (default on),
  `ttsButtonX/Y` + setter. Same Hive box → covered by `SettingsBackup`
  automatically.
- `lib/features/reader/novel_tts_ui.dart` (new): `NovelTtsPuck` (draggable,
  tap toggle, long-press stop, dims while playing) + voice/engine picker
  sheet (language filter, default reset, engine switch clears stale voice).
- `lib/features/reader/novel_reader_screen.dart`: controller lifecycle
  (init/dispose, `setSource` on chapter load, `cancelAutoStart` on load
  error, `stop()` on chapter change); bottom-bar read-aloud button (accent
  while active); puck in stack; "Read aloud" settings section (toggle +
  status, rate/pitch sliders live-applied, voice picker, auto-advance,
  follow-scroll); TTS↔auto-scroll mutual exclusion; follow-scroll for scroll
  mode (char-weighted) and paged mode.
- `android/.../AndroidManifest.xml`: `<queries>` entry for
  `android.intent.action.TTS_SERVICE` (engine/voice listing on Android 11+).
  No permission needed — system TTS, same as Reikai.
- `test/reading/novel_tts_text_test.dart` (new): 12 unit tests for the
  splitter + progress helper.
- `NOTICE.md`: `flutter_tts` (MIT) + Reikai design credit entries.

**Deliberately v1 / follow-ups:**

1. Foreground-only speech (no background service/notification like Reikai's
   `NovelTtsService`). Screen stays awake via existing reader wakelock.
2. No in-text highlight of the spoken paragraph (`HtmlWidget` has no
   per-paragraph keys) — follow-scroll + status row instead.
3. New UI strings are hardcoded English (existing sheets do the same for
   section headers); no `.arb` keys added, so no `flutter gen-l10n` needed.
4. TTS ↔ video/audio focus (media_kit) unhandled beyond mutual exclusion
   with auto-scroll — novel reader plays no media, stop-on-dispose covers it.

**Remaining manual QA (on device — not yet done):** open a novel chapter → bottom-bar speaker → speech
starts; puck appears (tap pause, long-press stop, drag to move); settings →
Read aloud → rate/pitch/voice/auto-advance/follow toggles; last paragraph +
auto-advance → next chapter auto-reads; chapter change/dispose silences it.

**Revert:** `git revert <commit>` (single commit, see below) — or per-file,
all TTS code is additive except small hooks in `novel_reader_screen.dart`,
`reader_prefs.dart`, `AndroidManifest.xml`, `pubspec.yaml`, `NOTICE.md`.
