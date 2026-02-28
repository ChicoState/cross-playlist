import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'login_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

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


class MyHomePage  extends StatelessWidget {
  const MyHomePage ({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
        title: const Text('Cross-Playlist', style: TextStyle(fontSize: 36))
        ),
      body: const Playlist(),
      ),
    );
  }
}


class Song {
  const Song(this.artist, this.album, this.genre, this.streamingPlatform, {required this.name, required this.url});
  

  final String name, url, artist, album, genre, streamingPlatform;
    
  // Connects music streaming service. NEEDS IMPLEMENTATION
  void _stream(String command) {
    if (command == 'play') {
      print("Play"); // Delete, Only used for testing buttons. Prints to consol only, not App
    } else if (command == 'stop') {
      print("Stop"); // Delete, Only used for testing buttons. Prints to consol only, not App
    }
    
  }

}

// Refreshes Playlist state on adding a song to the playlist
class Playlist extends StatefulWidget {
  const Playlist({super.key});

  @override
  State<Playlist> createState() => _PlaylistState();
}


class _PlaylistState extends State<Playlist> {
  
  final List<Song> songList = List<Song>.generate(2, (int index) => Song("", "", "", "", name: "", url: "") ,growable: true);
  void _addSong() {
    setState(() {
      // String artist = "", album = "", genre = "", streamingPlatform = "", name = "", url = "";
      String artist = 'artist', album = 'album', genre = '', streamingPlatform = '', name = 'Test Name', url = 'test.com';
      songList.add(Song(artist, album, genre, streamingPlatform, name: name, url: url));
    });
  }
  @override
  Widget build(BuildContext context) {
    return ReorderableListView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      onReorder: (int oldIndex, int newIndex){
        setState(() {
          if (oldIndex < newIndex) {
            newIndex -= 1;
          }
          final Song switchedSong = songList.removeAt(oldIndex);
          songList.insert(newIndex, switchedSong);
        });
      },
      footer: FloatingActionButton(
        onPressed: _addSong,
        tooltip: "Adds song to playlist",
        child: Icon(Icons.add),
        ),

      children: <Widget> [
        //Loops the number of songs on the playlist to display in Reorderable List View
        for(int index = 0; index < songList.length; index += 1)
          ListTile(
            shape: Border.all(width: 3, color: Colors.white),
            key: Key('$index'),
            tileColor: Colors.lightBlue,
            contentPadding: EdgeInsets.symmetric(vertical: 30, horizontal: 80),
            leading: Container(
              width: 100,
              height: 150,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black, width: 2)
              ),
              child: Center(
                child: Text("Album\nCover"),
              ),
            ),      
            title: Container(
              width: 80,
              height: 90,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black, width: 2)
              ),
              child: Center(
                child: Text('songList[index].name \nsongList[index].artist \nsongList[index].album'),
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
                  child: const Icon(Icons.play_arrow, size: 40, color: Colors.green)),
                  FloatingActionButton(
                  onPressed: () => songList[index]._stream('stop'),
                  tooltip: "Stops music",
                  child: const Icon(Icons.stop, size: 40, color: Colors.red,),
                  ),
                ],
              ),
            ),
          ),
        ],
    );
  }
}

