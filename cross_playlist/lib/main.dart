import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'login_page.dart';
import 'services/spotify_auth.dart';
import 'services/spotify_api.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Handle Spotify redirect before Firebase, so code can be exchanged
  await SpotifyAuth.handleRedirect();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  
  // Load Spotify tokens from Firestore if user is logged in
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

  @override
  void initState() {
    super.initState();
    _spotifyConnected = SpotifyAuth.isConnected;
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
      {required this.name, required this.url, this.imageUrl});

  final String name, url, artist, album, genre, streamingPlatform;
  final String? imageUrl;

  // Connects music streaming service. NEEDS IMPLEMENTATION
  void _stream(String command) {
    if (command == 'play') {
      print("Play");
    } else if (command == 'stop') {
      print("Stop");
    }
  }
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
          name: 'New Song', url: ''));
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
      footer: Padding(
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
          ListTile(
            shape: Border.all(width: 3, color: Colors.white),
            key: Key('$index'),
            tileColor: Colors.lightBlue,
            contentPadding:
                const EdgeInsets.symmetric(vertical: 30, horizontal: 80),
            leading: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black, width: 2),
              ),
              child: songList[index].imageUrl != null
                  ? Image.network(songList[index].imageUrl!, fit: BoxFit.cover)
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
                  '${songList[index].name}\n${songList[index].artist}\n${songList[index].album}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            trailing: SizedBox(
              width: 112,
              height: 80,
              child: Row(
                children: [
                  FloatingActionButton(
                    onPressed: () => songList[index]._stream('play'),
                    tooltip: "Plays/Pauses music",
                    child: const Icon(Icons.play_arrow,
                        size: 40, color: Colors.green),
                  ),
                  FloatingActionButton(
                    onPressed: () => songList[index]._stream('stop'),
                    tooltip: "Stops music",
                    child: const Icon(Icons.stop, size: 40, color: Colors.red),
                  ),
                ],
              ),
            ),
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