import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:html' as html;
import 'firebase_options.dart';
import 'login_page.dart';
import 'services/playlist_service.dart';
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
  List<PlaylistMeta> _playlists = [];
  String? _selectedPlaylistId;
  String _selectedPlaylistName = 'My Playlist';
  bool _loadingPlaylists = true;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // Load Spotify tokens now that the user is authenticated
    await SpotifyAuth.loadTokens();
    _spotifyConnected = SpotifyAuth.isConnected;
    if (_spotifyConnected) {
      _initializePlayer();
    }
    await _loadPlaylists();
    if (mounted) setState(() {});
  }

  Future<void> _initializePlayer() async {
    await SpotifyPlayer.instance.initialize();
    if (mounted) {
      setState(() => _playerInitialized = true);
    }
  }

  Future<void> _loadPlaylists() async {
    try {
      _playlists = await PlaylistService.getPlaylists();
      if (_playlists.isEmpty) {
        final p = await PlaylistService.createPlaylist('My Playlist');
        _playlists = [p];
      }
      _selectedPlaylistId ??= _playlists.first.id;
      _selectedPlaylistName =
          _playlists.firstWhere((p) => p.id == _selectedPlaylistId).name;
    } catch (e) {
      debugPrint('Error loading playlists: $e');
    }
    _loadingPlaylists = false;
  }

  void _connectSpotify() {
    SpotifyAuth.login();
  }

  Future<void> _disconnectSpotify() async {
    await SpotifyAuth.logout();
    setState(() => _spotifyConnected = false);
  }

  Future<void> _createPlaylist() async {
    final name = await _showTextDialog('New Playlist', 'Enter playlist name');
    if (name == null || name.trim().isEmpty) return;
    final p = await PlaylistService.createPlaylist(name.trim());
    setState(() {
      _playlists.add(p);
      _selectedPlaylistId = p.id;
      _selectedPlaylistName = p.name;
    });
  }

  Future<void> _renamePlaylist(PlaylistMeta playlist) async {
    final name = await _showTextDialog('Rename Playlist', 'Enter new name',
        initialValue: playlist.name);
    if (name == null || name.trim().isEmpty) return;
    await PlaylistService.renamePlaylist(playlist.id, name.trim());
    setState(() {
      final idx = _playlists.indexWhere((p) => p.id == playlist.id);
      if (idx >= 0) {
        _playlists[idx] = PlaylistMeta(id: playlist.id, name: name.trim());
        if (_selectedPlaylistId == playlist.id) {
          _selectedPlaylistName = name.trim();
        }
      }
    });
  }

  Future<void> _deletePlaylist(PlaylistMeta playlist) async {
    if (_playlists.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot delete the last playlist')),
      );
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Playlist'),
        content: Text('Delete "${playlist.name}"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm != true) return;
    await PlaylistService.deletePlaylist(playlist.id);
    setState(() {
      _playlists.removeWhere((p) => p.id == playlist.id);
      if (_selectedPlaylistId == playlist.id) {
        _selectedPlaylistId = _playlists.first.id;
        _selectedPlaylistName = _playlists.first.name;
      }
    });
  }

  Future<String?> _showTextDialog(String title, String hint,
      {String? initialValue}) {
    final controller = TextEditingController(text: initialValue);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
              hintText: hint, border: const OutlineInputBorder()),
          autofocus: true,
          onSubmitted: (_) => Navigator.pop(ctx, controller.text),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cross-Playlist',
            style: TextStyle(fontSize: 36)),
        automaticallyImplyLeading: false,
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
      body: Row(
        children: [
          SizedBox(
            width: 250,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Playlists',
                      style: Theme.of(context).textTheme.headlineSmall),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: _playlists.length,
                    itemBuilder: (context, index) {
                      final p = _playlists[index];
                      return ListTile(
                        title: Text(p.name),
                        selected: p.id == _selectedPlaylistId,
                        onTap: () {
                          setState(() {
                            _selectedPlaylistId = p.id;
                            _selectedPlaylistName = p.name;
                          });
                        },
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'rename') _renamePlaylist(p);
                            if (value == 'delete') _deletePlaylist(p);
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                                value: 'rename', child: Text('Rename')),
                            const PopupMenuItem(
                                value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('New Playlist'),
                  onTap: _createPlaylist,
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: _loadingPlaylists
                ? const Center(child: CircularProgressIndicator())
                : _selectedPlaylistId != null
                    ? Playlist(
                        key: ValueKey(_selectedPlaylistId),
                        spotifyConnected: _spotifyConnected,
                        playlistId: _selectedPlaylistId!,
                        playlistName: _selectedPlaylistName,
                      )
                    : const Center(child: Text('No playlist selected')),
          ),
        ],
      ),
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

  Map<String, dynamic> toMap() => {
        'name': name,
        'artist': artist,
        'album': album,
        'genre': genre,
        'streamingPlatform': streamingPlatform,
        'url': url,
        'imageUrl': imageUrl,
        'previewUrl': previewUrl,
      };

  factory Song.fromMap(Map<String, dynamic> map) => Song(
        map['artist'] as String? ?? '',
        map['album'] as String? ?? '',
        map['genre'] as String? ?? '',
        map['streamingPlatform'] as String? ?? '',
        name: map['name'] as String? ?? '',
        url: map['url'] as String? ?? '',
        imageUrl: map['imageUrl'] as String?,
        previewUrl: map['previewUrl'] as String?,
      );
}

// Refreshes Playlist state on adding a song to the playlist
class Playlist extends StatefulWidget {
  const Playlist(
      {super.key,
      required this.spotifyConnected,
      required this.playlistId,
      required this.playlistName});

  final bool spotifyConnected;
  final String playlistId;
  final String playlistName;

  @override
  State<Playlist> createState() => _PlaylistState();
}

class _PlaylistState extends State<Playlist> {
  final List<Song> songList = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSongs();
  }

  Future<void> _loadSongs() async {
    try {
      final maps = await PlaylistService.getSongs(widget.playlistId);
      songList.clear();
      for (final m in maps) {
        songList.add(Song.fromMap(m));
      }
    } catch (e) {
      debugPrint('Error loading songs: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _saveSongs() async {
    try {
      await PlaylistService.saveSongs(
        widget.playlistId,
        songList.map((s) => s.toMap()).toList(),
      );
    } catch (e) {
      debugPrint('Error saving songs: $e');
    }
  }

  void _addSong(Song song) {
    setState(() {
      songList.add(song);
    });
    _saveSongs();
  }

  void _deleteSong(int index) {
    setState(() {
      songList.removeAt(index);
    });
    _saveSongs();
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
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ReorderableListView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      onReorder: (int oldIndex, int newIndex) {
        setState(() {
          if (oldIndex < newIndex) newIndex -= 1;
          final switchedSong = songList.removeAt(oldIndex);
          songList.insert(newIndex, switchedSong);
        });
        _saveSongs();
      },
      header: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(widget.playlistName,
                style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 12),
            FloatingActionButton.extended(
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
          ],
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
    
    return GestureDetector(
      onLongPress: widget.onLongPress,
      child: ListTile(
        shape: Border.all(width: 3, color: Colors.white),
        key: Key('${widget.index}'),
        tileColor: Colors.lightBlue,
        hoverColor: Colors.lightBlue,
        splashColor: Colors.transparent,
        mouseCursor: SystemMouseCursors.basic,
        contentPadding: const EdgeInsets.symmetric(vertical: 30, horizontal: 80),
      leading: Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.black, width: 2),
          ),
          child: widget.song.imageUrl != null
              ? Image.network(widget.song.imageUrl!, fit: BoxFit.cover)
              : const Center(child: Text("Album\nCover")),
      ),
      title: Container(
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
      onLongPress: null,
      
    ),
    );
  }
}
