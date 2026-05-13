import 'dart:async';

import 'package:flutter/material.dart';

import 'services/youtube_api.dart';
import 'song.dart';

class YoutubeSearchDialog extends StatefulWidget {
  const YoutubeSearchDialog({super.key});

  @override
  State<YoutubeSearchDialog> createState() => _YoutubeSearchDialogState();
}

class _YoutubeSearchDialogState extends State<YoutubeSearchDialog> {
  final _searchController = TextEditingController();
  List<YoutubeSearchVideo> _results = [];
  bool _loading = false;
  String? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    if (!YoutubeApi.isConfigured) {
      _error =
          'YouTube search needs a Data API key. Paste it into _youtubeDataApiKey in lib/services/youtube_api.dart (same pattern as the Spotify client id in spotify_auth.dart).';
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      _search();
    });
  }

  Future<void> _search() async {
    if (!YoutubeApi.isConfigured) return;

    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _results = [];
        _error = null;
        _loading = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final results = await YoutubeApi.searchVideos(query);

    if (mounted && _searchController.text.trim() == query) {
      setState(() {
        _results = results;
        _loading = false;
        if (results.isEmpty) {
          _error = 'No results found for "$query"';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Search YouTube',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Results are added to this playlist like Spotify tracks.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                autofocus: true,
                enabled: YoutubeApi.isConfigured,
                decoration: const InputDecoration(
                  hintText: 'Song name, artist, lyrics…',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 12),
              if (_loading) const CircularProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final v = _results[index];
                    return ListTile(
                      leading: v.thumbnailUrl != null
                          ? Image.network(
                              v.thumbnailUrl!,
                              width: 88,
                              height: 50,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  const Icon(
                                    Icons.play_circle_outline,
                                    size: 48,
                                  ),
                            )
                          : const Icon(Icons.play_circle_outline, size: 48),
                      title: Text(
                        v.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        v.channelTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        final Song song = v.toSong();
                        Navigator.of(context).pop(song);
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
