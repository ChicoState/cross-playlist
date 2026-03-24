import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:html' as html;
import 'firebase_options.dart';
import 'login_page.dart';
import 'services/spotify_auth.dart';
import 'services/spotify_api.dart';
import 'services/spotify_player.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Handle Spotify OAuth redirect (needs Firebase for Firestore token save)
  await SpotifyAuth.handleRedirect();

  // Load saved Spotify tokens from Firestore if user is already logged in
  await SpotifyAuth.loadTokens();

  runApp(const MyApp());
}

// Handles the login page from Firebase to get into the homepage
// of the app
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cross-Playlist',
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasData) {
            return const MyHomePage();
          }
          return const LoginPage();
        },
      ),
    );
  }
}

// Displays the playlist on the homepage after successful login
class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  bool _spotifyConnected = false;
  bool _playerInitialized = false;

  @override
  void initState() {
    super.initState();
    _spotifyConnected = SpotifyAuth.isConnected;
    if (_spotifyConnected) {
      _initializePlayer();
    }
  }

  Future<void> _initializePlayer() async {
    await SpotifyPlayer.instance.initialize();
    if (mounted) {
      setState(() => _playerInitialized = true);
    }
  }

  void _connectSpotify() {
    // Just redirect - when we come back, initState will check isConnected
    SpotifyAuth.login();
  }

  Future<void> _disconnectSpotify() async {
    await SpotifyAuth.logout();
    setState(() => _spotifyConnected = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cross-Playlist', style: TextStyle(fontSize: 36)),
        actions: [
          if (_spotifyConnected)
            TextButton.icon(
              onPressed: _disconnectSpotify,
              icon: const Icon(Icons.check_circle, color: Color(0xFF1DB954)),
              label: const Text('Spotify Connected',
                  style: TextStyle(color: Color(0xFF1DB954))),
            )
          else
            TextButton.icon(
              onPressed: _connectSpotify,
              icon: const Icon(Icons.link, color: Colors.white),
              label: const Text('Connect Spotify',
                  style: TextStyle(color: Colors.white)),
              style: TextButton.styleFrom(
                backgroundColor: const Color(0xFF1DB954),
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Playlist(spotifyConnected: _spotifyConnected),
    );
  }
}

// Song class that will handle the playing of music
class Song {
  const Song(this.artist, this.album, this.genre, this.streamingPlatform,
      {required this.name, required this.url, this.imageUrl, this.previewUrl});

  final String name, url, artist, album, genre, streamingPlatform;
  final String? imageUrl;
  final String? previewUrl; // 30-second preview MP3
}

// Refreshes Playlist state on adding a song to the playlist
class Playlist extends StatefulWidget {
  const Playlist({super.key, required this.spotifyConnected});

  final bool spotifyConnected;

  @override
  State<Playlist> createState() => _PlaylistState();
}

class _PlaylistState extends State<Playlist> {
  final List<Song> songList = [];

  void _addSong(Song song) {
    setState(() {
      songList.add(song);
    });
  }

  void _deleteSong(int index) {
    setState(() {
      songList.removeAt(index);
    });
  }

  /// Opens a search dialog to find songs on Spotify and add them.
  Future<void> _showSpotifySearchDialog() async {
    final song = await showDialog<Song>(
      context: context,
      builder: (context) => const SpotifySearchDialog(),
    );
    if (song != null) {
      _addSong(song);
    }
  }

  /// Fallback: add a song manually (for when Spotify is not connected).
  void _addManualSong() {
    setState(() {
      songList.add(const Song('Unknown Artist', 'Unknown Album', '', 'Manual',
          name: 'New Song', url: '', previewUrl: null));
    });
  }

  @override
  Widget build(BuildContext context) {
    return ReorderableListView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      onReorder: (int oldIndex, int newIndex) {
        setState(() {
          if (oldIndex < newIndex) newIndex -= 1;
          final switchedSong = songList.removeAt(oldIndex);
          songList.insert(newIndex, switchedSong);
        });
      },
      header: Padding(
        padding: const EdgeInsets.all(16),
        child: FloatingActionButton.extended(
          onPressed: widget.spotifyConnected
              ? _showSpotifySearchDialog
              : _addManualSong,
          tooltip: widget.spotifyConnected
              ? 'Search Spotify for a song'
              : 'Add a song (connect Spotify to search)',
          icon: Icon(widget.spotifyConnected ? Icons.search : Icons.add),
          label: Text(widget.spotifyConnected ? 'Search Spotify' : 'Add Song'),
          backgroundColor:
              widget.spotifyConnected ? const Color(0xFF1DB954) : null,
        ),
      ),
      children: <Widget>[
        for (int index = 0; index < songList.length; index += 1)
          SongTile(
            key: Key('$index'),
            song: songList[index],
            index: index,
            onLongPress: () => _deleteSong(index),
          ),
      ],
    );
  }
}
// ---------------------------------------------------------------------------
// Spotify Search Dialog
// ---------------------------------------------------------------------------

class SpotifySearchDialog extends StatefulWidget {
  const SpotifySearchDialog({super.key});

  @override
  State<SpotifySearchDialog> createState() => _SpotifySearchDialogState();
}

class _SpotifySearchDialogState extends State<SpotifySearchDialog> {
  final _searchController = TextEditingController();
  List<SpotifyTrack> _results = [];
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    final results = await SpotifyApi.searchTracks(query);

    if (mounted) {
      setState(() {
        _results = results;
        _loading = false;
        if (results.isEmpty) _error = 'No results found for "$query"';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Search Spotify',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: const InputDecoration(
                        hintText: 'Song name, artist...',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.search),
                      ),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _loading ? null : _search,
                    child: const Text('Search'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_loading) const CircularProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final track = _results[index];
                    return ListTile(
                      leading: track.imageUrl != null
                          ? Image.network(track.imageUrl!,
                              width: 48, height: 48, fit: BoxFit.cover)
                          : const Icon(Icons.music_note, size: 48),
                      title: Text(track.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${track.artist} • ${track.album}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () {
                        final song = Song(
                          track.artist,
                          track.album,
                          '', // genre (Spotify search doesn't return genre)
                          'Spotify',
                          name: track.name,
                          url: track.spotifyUrl,
                          imageUrl: track.imageUrl,
                          previewUrl: track.previewUrl,
                        );
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
      ),    );
  }
}
// ---------------------------------------------------------------------------
// Song Tile with Audio Playback
// ---------------------------------------------------------------------------

class SongTile extends StatefulWidget {
  const SongTile({
    super.key,
    required this.song,
    required this.index,
    this.onLongPress
  });
  final VoidCallback? onLongPress;
  final Song song;
  final int index;


  @override
  State<SongTile> createState() => _SongTileState();
}

class _SongTileState extends State<SongTile> {
  html.AudioElement? _audioElement;
  bool _isPlaying = false;
  bool _isCurrentTrack = false;

  @override
  void initState() {
    super.initState();
    // Set up preview player as fallback
    if (widget.song.previewUrl != null) {
      _audioElement = html.AudioElement(widget.song.previewUrl!);
      _audioElement!.onEnded.listen((_) {
        if (mounted) {
          setState(() => _isPlaying = false);
        }
      });
    }

    // Listen to SDK playback state
    SpotifyPlayer.instance.playbackState.listen((state) {
      if (!mounted) return;
      final currentUri = SpotifyPlayer.instance.currentTrackUri;
      final thisTrackUri = _getTrackUri();
      
      setState(() {
        _isCurrentTrack = currentUri == thisTrackUri;
        if (_isCurrentTrack) {
          _isPlaying = state == PlaybackState.playing;
        } else if (_isPlaying && !_isCurrentTrack) {
          _isPlaying = false;
        }
      });
    });
  }

  @override
  void dispose() {
    _audioElement?.pause();
    _audioElement = null;
    super.dispose();
  }

  /// Extract Spotify track URI from URL (e.g., spotify:track:xxx).
  String? _getTrackUri() {
    final url = widget.song.url;
    if (url.isEmpty) return null;
    
    // URL format: https://open.spotify.com/track/TRACK_ID
    final match = RegExp(r'track/([a-zA-Z0-9]+)').firstMatch(url);
    if (match != null) {
      return 'spotify:track:${match.group(1)}';
    }
    return null;
  }

  Future<void> _togglePlayback() async {
    final player = SpotifyPlayer.instance;
    final trackUri = _getTrackUri();

    // Use SDK if available and song is from Spotify
    if (player.isReady && trackUri != null) {
      if (_isCurrentTrack && _isPlaying) {
        // Pause current track
        player.pause();
      } else if (_isCurrentTrack && !_isPlaying) {
        // Resume current track
        player.resume();
      } else {
        // Play new track
        await player.playTrack(trackUri);
      }
      return;
    }

    // Fallback to preview
    if (_audioElement != null) {
      setState(() {
        if (_isPlaying) {
          _audioElement!.pause();
          _isPlaying = false;
        } else {
          _audioElement!.play();
          _isPlaying = true;
        }
      });
    } else {
      // No preview or SDK, open in Spotify
      _openInSpotify();
    }
  }

  void _openInSpotify() {
    if (widget.song.url.isNotEmpty) {
      html.window.open(widget.song.url, '_blank');
    }
  }


  @override
  Widget build(BuildContext context) {
    final hasFullPlayback = SpotifyPlayer.instance.isReady && _getTrackUri() != null;
    
    return ListTile(
      shape: Border.all(width: 3, color: Colors.white),
      key: Key('${widget.index}'),
      tileColor: Colors.lightBlue,
      contentPadding: const EdgeInsets.symmetric(vertical: 30, horizontal: 80),
      leading: GestureDetector(
        onTap: _openInSpotify,
        child: Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.black, width: 2),
          ),
          child: widget.song.imageUrl != null
              ? Image.network(widget.song.imageUrl!, fit: BoxFit.cover)
              : const Center(child: Text("Album\nCover")),
        ),
      ),
      title: GestureDetector(
        onTap: _openInSpotify,
        child: Container(
          width: 80,
          height: 90,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.black, width: 2),
          ),
          child: Center(
            child: Text(
              '${widget.song.name}\n${widget.song.artist}\n${widget.song.album}'
              '${hasFullPlayback ? '\n(Full playback)' : widget.song.previewUrl != null ? '\n(30s preview)' : '\n(No preview)'}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ),
      ),
      trailing: SizedBox(
        width: 56,
        height: 80,
        child: FloatingActionButton(
          onPressed: _togglePlayback,
          tooltip: hasFullPlayback
              ? _isPlaying
                  ? "Pause"
                  : "Play full song"
              : widget.song.previewUrl != null
                  ? _isPlaying
                      ? "Pause preview"
                      : "Play 30s preview"
                  : "Open in Spotify",
          child: Icon(
            _isPlaying ? Icons.pause : Icons.play_arrow,
            size: 40,
            color: _isCurrentTrack ? Colors.greenAccent : Colors.green,
          ),
        ),
      ),
      onLongPress: widget.onLongPress,
      
    );
  }
}
