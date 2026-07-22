import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:client/theme/hops_theme.dart';

enum GameRole { runner, robber }

class HopsAndRobbersPage extends StatefulWidget {
  final Stream<List<ScanResult>> radarStream;
  final String myUsername;
  final Future<void> Function(String action, Map<String, String> data) onSendGameAction;
  final Stream<Map<String, dynamic>> gameEventStream;

  const HopsAndRobbersPage({
    super.key,
    required this.radarStream,
    required this.myUsername,
    required this.onSendGameAction,
    required this.gameEventStream,
  });

  @override
  State<HopsAndRobbersPage> createState() => _HopsAndRobbersPageState();
}

class _HopsAndRobbersPageState extends State<HopsAndRobbersPage> {
  // ---------- Lobby state ----------
  final Map<String, _Lobby> _lobbies = {};
  String? _myLobbyId;
  bool _isHost = false;
  bool _gameActive = false;

  // ---------- Game state ----------
  GameRole _myRole = GameRole.runner;
  String _gameId = '';
  final Map<String, GameRole> _playerRoles = {};
  final Map<String, int> _nearbyRunners = {};

  StreamSubscription? _scanSub;
  StreamSubscription? _gameSub;
  Timer? _lobbyAdTimer;

  final _lobbyIdGenerator = const Uuid();

  @override
  void initState() {
    super.initState();

    _gameSub = widget.gameEventStream.listen((event) {
      handleGameAction(
        event['action'] as String,
        (event['data'] as Map).cast<String, String>(),
      );
    });

    _scanSub = widget.radarStream.listen((results) {
      final now = DateTime.now();
      for (final r in results) {
        final name = r.advertisementData.advName;

        // ---------- LOBBY ADVERTISEMENT ----------
        if (name.startsWith("GAME_LOBBY_AD:")) {
          final data = _parseActionData(name.substring(14));
          final lobbyId = data['lobby_id'];
          final host = data['host'];
          final lobbyName = data['name'] ?? '$host\'s Lobby';
          print("📡 Lobby seen: $lobbyName by $host");
          if (lobbyId != null && host != null && host != widget.myUsername) {
            _lobbies[lobbyId] = _Lobby(
              id: lobbyId,
              host: host,
              name: lobbyName,
              lastSeen: now,
            );
          }
        }

        // ---------- JOIN REQUEST ----------
        if (name.startsWith("GAME_JOIN_REQ:")) {
          final data = _parseActionData(name.substring(14));
          final lobbyId = data['lobby_id'];
          final player = data['player'];
          print("📩 Join request for lobby $lobbyId from $player");
          if (lobbyId != null && player != null && _myLobbyId == lobbyId && _isHost) {
            setState(() {
              _lobbies[lobbyId]?.players.add(player);
            });
          }
        }
      }

      _lobbies.removeWhere((id, lobby) => now.difference(lobby.lastSeen).inSeconds > 15);
      setState(() {});
    });
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _gameSub?.cancel();
    _lobbyAdTimer?.cancel();
    super.dispose();
  }

  Map<String, String> _parseActionData(String rawData) {
    final map = <String, String>{};
    for (final pair in rawData.split(';')) {
      final kv = pair.split('=');
      if (kv.length == 2) {
        map[kv[0]] = kv[1];
      }
    }
    return map;
  }

  // ---------- Lobby host advertising ----------
  void _startLobbyAd() {
    _lobbyAdTimer?.cancel();

    final safeName = '${widget.myUsername}\'s Lobby'
        .replaceAll(';', '')
        .replaceAll('=', '');

    widget.onSendGameAction('LOBBY_AD', {
      'lobby_id': _myLobbyId!,
      'host': widget.myUsername,
      'name': safeName,
    });
    print("📢 Broadcasting lobby: $safeName");

    _lobbyAdTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      widget.onSendGameAction('LOBBY_AD', {
        'lobby_id': _myLobbyId!,
        'host': widget.myUsername,
        'name': safeName,
      });
    });
  }

  void _stopLobbyAd() {
    _lobbyAdTimer?.cancel();
  }

  // ---------- Create lobby ----------
  void _createLobby() {
    final lobbyId = _lobbyIdGenerator.v4().substring(0, 8);
    _myLobbyId = lobbyId;
    _isHost = true;
    _lobbies[lobbyId] = _Lobby(
      id: lobbyId,
      host: widget.myUsername,
      name: '${widget.myUsername}\'s Lobby'.replaceAll(';', '').replaceAll('=', ''),
      lastSeen: DateTime.now(),
    );
    _startLobbyAd();
    setState(() {});
  }

  // ---------- Join lobby ----------
  void _joinLobby(String lobbyId) async {
    final lobby = _lobbies[lobbyId];
    if (lobby == null) return;

    await widget.onSendGameAction('JOIN_REQ', {
      'lobby_id': lobbyId,
      'player': widget.myUsername,
    });
    print("📩 Sending join request to lobby $lobbyId");

    _myLobbyId = lobbyId;
    _isHost = false;
    setState(() {});
  }

  // ---------- Leave lobby ----------
  void _leaveLobby() {
    if (_isHost) _stopLobbyAd();
    setState(() {
      _myLobbyId = null;
      _isHost = false;
      _gameActive = false;
      _playerRoles.clear();
      _myRole = GameRole.runner;
    });
  }

  // ---------- Host starts the game ----------
  void _startGameAsHost() {
    if (!_isHost || _myLobbyId == null) return;
    final lobby = _lobbies[_myLobbyId];
    if (lobby == null) return;

    final players = List<String>.from(lobby.players)..add(widget.myUsername);
    if (players.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Need at least 2 players to start")),
      );
      return;
    }

    final robber = players[Random().nextInt(players.length)];

    widget.onSendGameAction('START', {
      'lobby_id': _myLobbyId!,
      'players': players.join(','),
      'robber': robber,
    });

    _startGameInternal(players, robber);
  }

  void _startGameInternal(List<String> players, String robber) {
    _playerRoles.clear();
    for (final p in players) {
      _playerRoles[p] = p == robber ? GameRole.robber : GameRole.runner;
    }
    _myRole = _playerRoles[widget.myUsername] ?? GameRole.runner;
    _gameActive = true;
    _gameId = _myLobbyId ?? DateTime.now().millisecondsSinceEpoch.toString();
    _stopLobbyAd();
    setState(() {});
    if (_myRole == GameRole.robber) _startTagScanner();
  }

  // ---------- Game action handler (TAG) ----------
  void handleGameAction(String action, Map<String, String> data) {
    if (action == 'TAG') {
      if (data['target'] == widget.myUsername) {
        _myRole = GameRole.robber;
        _playerRoles[widget.myUsername] = GameRole.robber;
        _startTagScanner();
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("You've been tagged by ${data['tagger']}! You're now a Robber.")),
        );
      }
      if (data['target'] != null) {
        _playerRoles[data['target']!] = GameRole.robber;
        setState(() {});
      }
    }
  }

  // ---------- Tag scanner ----------
  void _startTagScanner() {
    _scanSub?.cancel();
    _scanSub = widget.radarStream.listen((results) {
      if (!_gameActive || _myRole != GameRole.robber) return;
      final runners = <String, int>{};
      for (final r in results) {
        final name = r.advertisementData.advName;
        if (name.startsWith("HPS:") && r.rssi > -45) {
          final username = name.substring(4);
          if (_playerRoles[username] == GameRole.runner) {
            runners[username] = r.rssi;
          }
        }
      }
      setState(() => _nearbyRunners
        ..clear()
        ..addAll(runners));
    });
  }

  void _tagRunner(String username) {
    widget.onSendGameAction('TAG', {
      'game_id': _gameId,
      'target': username,
      'tagger': widget.myUsername,
    });
  }

  bool get _allRobbers => _playerRoles.values.every((r) => r == GameRole.robber);

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
  final theme = Theme.of(context);      // ← here
  final colors = theme.colorScheme;     // ← here
    // ---- GAME OVER ----
    if (_gameActive && _allRobbers) {
      return Scaffold(
        appBar: AppBar(
          title: Flexible(
            child: Text(
              "Hops & Robbers",
              style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          elevation: 0,
          backgroundColor: Colors.transparent,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.emoji_events, size: 80, color: Colors.amber),
              const Text(
                "Game Over! All players are Robbers.",
                style: TextStyle(fontSize: 20),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _leaveLobby,
                child: const Text("Back to Lobbies"),
              ),
            ],
          ),
        ),
      );
    }

    // ---- ACTIVE GAME ----
    if (_gameActive) {
      return Scaffold(
        appBar: AppBar(
          title: Flexible(
            child: Text(
              "Hops & Robbers",
              style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          elevation: 0,
          backgroundColor: Colors.transparent,
        ),
        body: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              color: _myRole == GameRole.robber
                  ? Colors.red.withOpacity(0.2)
                  : Colors.green.withOpacity(0.2),
              child: Row(
                children: [
                  Icon(
                    _myRole == GameRole.robber
                        ? Icons.person_off
                        : Icons.directions_run,
                    size: 36,
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      _myRole == GameRole.robber
                          ? "You are a Robber"
                          : "You are a Runner",
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: _myRole == GameRole.robber
                            ? Colors.red
                            : Colors.green,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: _playerRoles.entries
                    .map((entry) => ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                    entry.value == GameRole.robber
                        ? Colors.red
                        : Colors.green,
                    child: Icon(
                      entry.value == GameRole.robber
                          ? Icons.person_off
                          : Icons.directions_run,
                      color: Colors.white,
                    ),
                  ),
                  title: Text(
                    entry.key,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    entry.value == GameRole.robber
                        ? "Robber"
                        : "Runner",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ))
                    .toList(),
              ),
            ),
            if (_myRole == GameRole.robber && _nearbyRunners.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.red.withOpacity(0.1),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Nearby Runners:",
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: _nearbyRunners.entries.map((e) {
                        return ElevatedButton.icon(
                          icon: const Icon(Icons.sports_kabaddi, size: 18),
                          label: Flexible(
                            child: Text(
                              "Tag ${e.key}",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => _tagRunner(e.key),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    // ---- INSIDE LOBBY (Waiting for players) ----
    if (_myLobbyId != null) {
      final lobby = _lobbies[_myLobbyId];
      final players = lobby?.players ?? [];
      return Scaffold(
        appBar: AppBar(
          title: Flexible(
            child: Text(
              "Lobby",
              style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          elevation: 0,
          backgroundColor: Colors.transparent,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _leaveLobby,
          ),
        ),
        body: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              color: _isHost
                  ? Colors.blue.withOpacity(0.1)
                  : Colors.green.withOpacity(0.1),
              child: Row(
                children: [
                  Icon(
                    _isHost ? Icons.star : Icons.person,
                    size: 36,
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      _isHost
                          ? "You are the host"
                          : "Waiting for host to start...",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.blue,
                      child: Icon(Icons.star, color: Colors.white),
                    ),
                    title: Text(
                      lobby?.host ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: const Text("Host"),
                  ),
                  ...players.map((p) => ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.green,
                      child: Icon(Icons.person, color: Colors.white),
                    ),
                    title: Text(
                      p,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: const Text("Player"),
                  )),
                ],
              ),
            ),
            if (_isHost)
              Padding(
                padding: const EdgeInsets.all(24),
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text("Start Game"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 16),
                  ),
                  onPressed: _startGameAsHost,
                ),
              ),
          ],
        ),
      );
    }

    // ---- LOBBY BROWSER ----
    final availableLobbies = _lobbies.values
        .where((l) => l.host != widget.myUsername)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Flexible(
          child: Text(
            "Hops & Robbers",
            style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: _createLobby,
            tooltip: "Create Lobby",
          ),
        ],
      ),
      body: availableLobbies.isEmpty
          ? const Center(
        child: Text(
          "No lobbies found.\nCreate one with the + button.",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      )
          : ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: availableLobbies.length,
        itemBuilder: (context, index) {
          final lobby = availableLobbies[index];
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor:
                colors.primary.withOpacity(0.1),
                child: Icon(Icons.person,
                    color: colors.primary),
              ),
              title: Text(
                lobby.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                "${lobby.players.length} player(s)",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => _joinLobby(lobby.id),
                child: const Text("Join"),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Lobby {
  final String id;
  final String host;
  String name;
  final List<String> players = [];
  DateTime lastSeen;
  _Lobby({
    required this.id,
    required this.host,
    this.name = '',
    required this.lastSeen,
  });
}