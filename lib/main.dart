import 'package:chat_signalr/chat_page.dart';
import 'package:flutter/material.dart';

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
      home: ChatPage(),
    );
  }
}
