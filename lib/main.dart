import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/io_client.dart';
import 'package:signalr_core/signalr_core.dart';

void main() {
  runApp(const ChatDemoApp());
}

class ChatDemoApp extends StatelessWidget {
  const ChatDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SignalR Chat Demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const ChatPage(),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late final HubConnection _hub;
  final _roomCtrl = TextEditingController(text: 'room1');
  final _msgCtrl = TextEditingController();
  final List<String> _messages = [];

  @override
  void initState() {
    super.initState();

    // 1) build connection
    // 1) Create a dart:io HttpClient that ignores bad certs
    final ioHttpClient = HttpClient()..badCertificateCallback = (cert, host, port) => true;

// 2) Wrap it in an IOClient (which implements BaseClient)
    final httpClient = IOClient(ioHttpClient);

// 3) Build your HubConnection
    _hub = HubConnectionBuilder()
        .withUrl(
          'https://192.168.1.155:5003/chatHub', // ← use 10.0.2.2 on the Android emulator
          HttpConnectionOptions(
            client: httpClient, // ← now it's a BaseClient
            transport: HttpTransportType.webSockets, // skip negotiation if you like
            skipNegotiation: true,
          ),
        )
        .withAutomaticReconnect()
        .build();

    // 2) hook ReceiveMessage
    _hub.on('ReceiveMessage', (args) {
      final room = args![0] as String;
      final user = args[1] as String;
      final text = args[2] as String;
      final ts = DateTime.parse(args[3] as String);
      setState(() {
        _messages.add('[${ts.toLocal().toIso8601String()}][$room][$user]: $text');
      });
    });

    _hub.on('UserTyping', (args) {
      final room = args![0] as String;
      final user = args[1] as String;
      setState(() => _messages.add('--- $user is typing in $room ---'));
    });

    // 3) start connection
    _hub.start()?.catchError((e) => debugPrint('Connection error: $e'));
  }

  @override
  void dispose() {
    _hub.stop();
    _roomCtrl.dispose();
    _msgCtrl.dispose();
    super.dispose();
  }

  Future<void> _joinRoom() async {
    final room = _roomCtrl.text.trim();
    if (room.isEmpty) return;
    await _hub.invoke('JoinRoom', args: [room]);
    setState(() => _messages.add('--- Joined $room ---'));
  }

  Future<void> _sendMessage() async {
    final room = _roomCtrl.text.trim();
    final msg = _msgCtrl.text.trim();
    if (room.isEmpty || msg.isEmpty) return;
    await _hub.invoke('SendMessage', args: [room, 'FlutterUser', msg]);
    _msgCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SignalR Chat Demo')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(children: [
              Expanded(child: TextField(controller: _roomCtrl, decoration: const InputDecoration(labelText: 'Room'))),
              ElevatedButton(onPressed: _joinRoom, child: const Text('Join')),
            ]),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: _messages.length,
                itemBuilder: (_, i) => Text(_messages[i]),
              ),
            ),
            Row(children: [
              Expanded(child: TextField(controller: _msgCtrl, decoration: const InputDecoration(labelText: 'Message'))),
              ElevatedButton(onPressed: _sendMessage, child: const Text('Send')),
            ]),
          ],
        ),
      ),
    );
  }
}
