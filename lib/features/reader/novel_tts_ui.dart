import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tts/novel_tts_controller.dart';
import '../../core/reading/reader_prefs.dart';
import 'reader_chrome.dart';

/// Floating read-aloud puck for the novel reader — Reikai's `NovelTtsFloatingButton`
/// adapted to this app's pill language (same surface as [ReaderAutoScrollButton]).
///
/// Only in the tree while TTS is active (playing or paused); like the
/// auto-scroll button it costs nothing the rest of the time. Tap toggles
/// play/pause, long-press stops, drag re-parks it (position persists as a
/// screen fraction, so rotation can't strand it off-screen).
class NovelTtsPuck extends StatefulWidget {
  const NovelTtsPuck({
    super.key,
    required this.controller,
    required this.initialX,
    required this.initialY,
    required this.onMoved,
  });

  final NovelTtsController controller;

  /// Position as a fraction of the screen, 0–1 on each axis.
  final double initialX;
  final double initialY;
  final void Function(double x, double y) onMoved;

  @override
  State<NovelTtsPuck> createState() => _NovelTtsPuckState();
}

class _NovelTtsPuckState extends State<NovelTtsPuck> {
  static const double _size = 46;

  late double _x = widget.initialX;
  late double _y = widget.initialY;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final maxLeft = (screen.width - _size).clamp(0.0, double.infinity);
    final maxTop = (screen.height - _size).clamp(0.0, double.infinity);
    final left = (_x * screen.width).clamp(0.0, maxLeft);
    final top = (_y * screen.height).clamp(
      MediaQuery.paddingOf(context).top + 8,
      maxTop,
    );

    // Always Positioned, even when hidden — same reason as the auto-scroll
    // button: everything else in the Stack is positioned, so a bare shrink
    // would collapse the whole reader to 0x0.
    return Positioned(
      left: left,
      top: top,
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          if (!controller.isActive) return const SizedBox.shrink();
          final playing = controller.isPlaying;
          return Semantics(
            button: true,
            label: playing ? 'Pause read aloud' : 'Resume read aloud',
            child: GestureDetector(
              onTap: controller.toggle,
              onLongPress: controller.stop,
              onPanStart: (_) => setState(() => _dragging = true),
              onPanUpdate: (d) {
                setState(() {
                  _x = ((left + d.delta.dx) / screen.width).clamp(0.0, 1.0);
                  _y = ((top + d.delta.dy) / screen.height).clamp(0.0, 1.0);
                });
              },
              onPanEnd: (_) {
                setState(() => _dragging = false);
                widget.onMoved(_x, _y);
              },
              child: Opacity(
                // Faint while playing (Reikai dims its puck the same way):
                // this sits over the page for the whole chapter.
                opacity: _dragging ? 0.95 : (playing ? 0.45 : 0.9),
                child: Tooltip(
                  message: 'Tap to ${playing ? 'pause' : 'resume'} · '
                      'long-press to stop',
                  child: SizedBox(
                    width: _size,
                    height: _size,
                    child: ReaderPillSurface(
                      radius: _size / 2,
                      child: Center(
                        child: Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 22,
                          color: AppColors.accent,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Opens the voice/engine picker for read-aloud. [onPicked] fires after any
/// change so the parent sheet + reader rebuild (same `apply` pattern the
/// reader settings sheets use).
Future<void> showNovelTtsVoiceSheet({
  required BuildContext context,
  required NovelTtsController controller,
  required ReaderPrefs prefs,
  required VoidCallback onPicked,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _NovelTtsVoiceSheet(
      controller: controller,
      prefs: prefs,
      onPicked: onPicked,
    ),
  );
}

class _NovelTtsVoiceSheet extends StatefulWidget {
  const _NovelTtsVoiceSheet({
    required this.controller,
    required this.prefs,
    required this.onPicked,
  });

  final NovelTtsController controller;
  final ReaderPrefs prefs;
  final VoidCallback onPicked;

  @override
  State<_NovelTtsVoiceSheet> createState() => _NovelTtsVoiceSheetState();
}

class _NovelTtsVoiceSheetState extends State<_NovelTtsVoiceSheet> {
  late final Future<({List<Map<String, String>> voices, List<Map<String, String>> engines})>
  _future = _load();
  String _languageFilter = '';

  Future<({List<Map<String, String>> voices, List<Map<String, String>> engines})>
  _load() async {
    final voices = await widget.controller.voices();
    final engines = await widget.controller.engines();
    return (voices: voices, engines: engines);
  }

  @override
  Widget build(BuildContext context) {
    return readerSheetBody(
      context: context,
      title: 'Voice',
      subtitle: 'System voices — no download, works offline.',
      children: [
        FutureBuilder(
          future: _future,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final voices = snapshot.data!.voices;
            final engines = snapshot.data!.engines;
            if (voices.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No voices reported on this device yet — install a TTS '
                  'engine (e.g. Google Speech Services) and reopen this.',
                  style: AppText.body.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              );
            }
            // Language filter options from the voices themselves (base tag
            // before the dash, like Reikai's language picker).
            final langs = <String>{};
            for (final v in voices) {
              final tag = v['locale'] ?? '';
              if (tag.isNotEmpty) langs.add(tag.split(RegExp(r'[-_]')).first);
            }
            final sortedLangs = langs.toList()..sort();
            final filtered = _languageFilter.isEmpty
                ? voices
                : voices
                      .where(
                        (v) =>
                            (v['locale'] ?? '').split(RegExp(r'[-_]')).first ==
                            _languageFilter,
                      )
                      .toList();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (engines.length > 1) ...[
                  readerSheetSection('Engine'),
                  readerSheetGroup([
                    for (final e in engines)
                      readerSheetRow(
                        icon: Icons.settings_voice_rounded,
                        label: e['label'] ?? e['name']!,
                        trailing: widget.prefs.ttsEngine == e['name']
                            ? Icon(
                                Icons.check_rounded,
                                color: AppColors.accent,
                              )
                            : null,
                        onTap: () async {
                          await widget.prefs.setTtsEngine(e['name']!);
                          // A new engine has its own voices — clear the stale
                          // pick so the engine default speaks, not a name it
                          // doesn't know.
                          await widget.prefs.setTtsVoice('', '');
                          widget.controller.refreshSettings();
                          widget.onPicked();
                          if (mounted) setState(() {});
                        },
                      ),
                  ]),
                ],
                readerSheetSection('Language'),
                readerSheetGroup([
                  readerSheetRow(
                    icon: Icons.translate_rounded,
                    label: 'Language',
                    trailing: DropdownButton<String>(
                      value: _languageFilter,
                      underline: const SizedBox.shrink(),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('All'),
                        ),
                        for (final l in sortedLangs)
                          DropdownMenuItem(value: l, child: Text(l)),
                      ],
                      onChanged: (v) =>
                          setState(() => _languageFilter = v ?? ''),
                    ),
                  ),
                ]),
                readerSheetSection('Voice (${filtered.length})'),
                readerSheetGroup([
                  readerSheetRow(
                    icon: Icons.record_voice_over_rounded,
                    label: 'Default',
                    trailing: widget.prefs.ttsVoice.isEmpty
                        ? Icon(
                            Icons.check_rounded,
                            color: AppColors.accent,
                          )
                        : null,
                    onTap: () async {
                      await widget.prefs.setTtsVoice('', '');
                      await widget.prefs.setTtsLanguage('');
                      widget.controller.refreshSettings();
                      widget.onPicked();
                      if (mounted) setState(() {});
                    },
                  ),
                  for (final v in filtered.take(120))
                    readerSheetRow(
                      icon: Icons.person_rounded,
                      label: v['name']!,
                      trailing: widget.prefs.ttsVoice == v['name']
                          ? Icon(
                              Icons.check_rounded,
                              color: AppColors.accent,
                            )
                          : Text(
                              v['locale'] ?? '',
                              style: AppText.caption.copyWith(
                                color: AppColors.textSecondary,
                              ),
                            ),
                      onTap: () async {
                        await widget.prefs.setTtsVoice(
                          v['name']!,
                          v['locale'] ?? '',
                        );
                        await widget.prefs.setTtsLanguage(v['locale'] ?? '');
                        widget.controller.refreshSettings();
                        widget.onPicked();
                        if (mounted) setState(() {});
                      },
                    ),
                ]),
                if (filtered.length > 120)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Showing 120 of ${filtered.length} — narrow the '
                      'language above to find the rest.',
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
