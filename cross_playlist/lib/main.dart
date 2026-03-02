import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'login_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized(); //Firebase initialization
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
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
          if (snapshot.hasData) {  //Goes to Home page on sucessful login 
            return const MyHomePage();
          }
          return const LoginPage();
        },
      ),
    );
  }
}

// Displays the playlist on the homepage after successful login
class MyHomePage  extends StatelessWidget {
  const MyHomePage ({super.key});

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

// Song class that will handle the playing of music
class Song {
  const Song(this.artist, this.album, this.genre, this.streamingPlatform, 
             {required this.name, required this.url});
  
  final String name, url, artist, album, genre, streamingPlatform;
    
  // Connects music streaming service. NEEDS IMPLEMENTATION
  void _stream(String command) {
    // This will handle the logic when the user press the Play/Pause and Stop buttons
    // Below is some testing code to make sure the buttons were working correctly.
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

// Creates the user's playlist and allow easy rearranging the order of the list
// ***Note: Things to work on****
//    1. a way to take user input for the song information 
//    2. a way to save the playlist so it doesn't get deleted every time the app boots
//       also saving multiple playlist with a custom name
//    3. a way to keep track of what song is playing to auto play the next song
//       since every song has a play button, multiple songs should not be able to play
//       over eachother.
//    4. NEEDS a delete song/s option 

class _PlaylistState extends State<Playlist> {
  
  final List<Song> songList = List<Song>.generate(2, (int index) => Song("", "", "", "", name: "", url: "") ,growable: true);
  void _addSong() {
    setState(() {
      // Need to add user input to fill the song information
      String artist = 'artist', album = 'album', genre = '', streamingPlatform = '', name = 'Test Name', url = 'test.com';
      songList.add(Song(artist, album, genre, streamingPlatform, name: name, url: url));
    });
  }

  // Builds the song list into a scrollable and reorderable playlist
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

            // Addes Play/Pause and Stop bottons. When pressed, they call stream() function from the song class
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

