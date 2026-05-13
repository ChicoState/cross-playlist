import 'package:flutter/material.dart';

import 'playback_controller.dart';
import 'services/youtube_api.dart';

class MiniPlayerBar extends StatefulWidget {
  const MiniPlayerBar({super.key, required this.controller});

  final PlaylistPlaybackController controller;

  @override
  State<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends State<MiniPlayerBar> {
  double? _dragValue;

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        if (!controller.showMiniPlayer) return const SizedBox.shrink();
        final song = controller.currentSong;
        if (song == null) return const SizedBox.shrink();

        final theme = Theme.of(context);
        final dur = controller.duration;
        final pos = controller.position;
        final maxMs = dur.inMilliseconds > 0 ? dur.inMilliseconds : 1;
        final liveValue = (pos.inMilliseconds / maxMs).clamp(0.0, 1.0);
        final sliderValue = _dragValue ?? liveValue;
        final sliderEnabled = dur.inMilliseconds > 0;

        return Material(
          elevation: 8,
          color: theme.colorScheme.surfaceContainerHighest,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(5),
                            child: song.imageUrl != null
                                ? Image.network(
                                    song.imageUrl!,
                                    fit: BoxFit.cover,
                                    errorBuilder:
                                        (context, error, stackTrace) =>
                                            const Icon(Icons.music_note),
                                  )
                                : const Icon(Icons.music_note),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              song.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: controller.shuffleEnabled
                            ? 'Shuffle on'
                            : 'Shuffle off',
                        icon: Icon(
                          Icons.shuffle,
                          color: controller.shuffleEnabled
                              ? const Color(0xFF1DB954)
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        onPressed: controller.toggleShuffle,
                      ),
                      IconButton(
                        tooltip: 'Previous',
                        icon: const Icon(Icons.skip_previous),
                        onPressed: controller.skipPrevious,
                      ),
                      IconButton(
                        tooltip: controller.isPlaying ? 'Pause' : 'Play',
                        iconSize: 40,
                        icon: Icon(
                          controller.isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: const Color(0xFF1DB954),
                        ),
                        onPressed: controller.togglePlayPause,
                      ),
                      IconButton(
                        tooltip: 'Next',
                        icon: const Icon(Icons.skip_next),
                        onPressed: controller.skipNext,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      SizedBox(
                        width: 40,
                        child: Text(
                          _fmt(
                            _dragValue != null
                                ? Duration(
                                    milliseconds:
                                        (dur.inMilliseconds * sliderValue)
                                            .round(),
                                  )
                                : pos,
                          ),
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                          ),
                          child: Slider(
                            value: sliderEnabled
                                ? sliderValue.clamp(0.0, 1.0)
                                : 0.0,
                            onChangeStart: sliderEnabled
                                ? (_) {
                                    controller.setScrubbing(true);
                                    setState(() => _dragValue = liveValue);
                                  }
                                : null,
                            onChanged: sliderEnabled
                                ? (v) {
                                    setState(() => _dragValue = v);
                                  }
                                : null,
                            onChangeEnd: sliderEnabled
                                ? (v) async {
                                    await controller.seekToProgress(v);
                                    setState(() => _dragValue = null);
                                    controller.setScrubbing(false);
                                  }
                                : null,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          _fmt(dur),
                          textAlign: TextAlign.end,
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
