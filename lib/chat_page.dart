import 'dart:async';
import 'dart:math'; // For generating unique IDs

import 'package:flutter/material.dart';
// Ensure you have the signalr_netcore package in your pubspec.yaml
import 'package:signalr_netcore/signalr_client.dart' as signalr;
// Import foundation for debugPrint
import 'package:flutter/foundation.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  // --- Configuration ---
  // TODO: Replace with your actual server URL and username mechanism
  static const _serverUrl = 'https://staging.voyagerapi.com.tr/api/chatHub';
  // Using a static username for simplicity in this example.
  // In a real app, this would come from authentication.
  static const _username = 'Wekewenk';

  // --- SignalR Connection ---
  late final signalr.HubConnection _hub;
  signalr.ConnectionState _hubState = signalr.ConnectionState.Disconnected;

  // --- UI Controllers ---
  final _roomCtrl = TextEditingController(text: 'room1'); // Default room
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  // --- State ---
  final List<_ChatMessage> _messages = [];
  final Set<String> _typingUsers = {};
  final List<String> _onlineUsers = []; // Track online users globally
  final List<String> _currentRoomMembers =
      []; // Track users in the current room
  Timer? _typingDebounce;
  String? _currentRoom;

  @override
  void initState() {
    super.initState();

    // --- Build & Configure HubConnection ---
    _hub = signalr.HubConnectionBuilder()
        .withUrl(
          _serverUrl,
          // Optional: Configure transport type, logging, headers, etc.
          // options: signalr.HttpConnectionOptions(
          //   // accessTokenFactory: () async => await _getAccessToken(), // Example: Auth
          //   // logging: (level, message) => print(message), // Example: Logging
          // ),
        )
        .build();

    // --- Connection Lifecycle Handlers ---
    _hub.onclose((error) {
      debugPrint('Connection Closed: $error');
      // Check if the widget is still mounted before calling setState
      if (mounted) {
        setState(() => _hubState = signalr.ConnectionState.Disconnected);
      }
    });

    // --- Register Hub Event Handlers ---
    _registerHubEventHandlers();

    // --- Debounce Typing Indicator ---
    _msgCtrl.addListener(_onMessageChanged);

    // --- Start Connection ---
    _startConnection();
  }

  /// Registers all handlers for messages coming *from* the server hub.
  void _registerHubEventHandlers() {
    // --- Presence ---
    _hub.on('UserOnline', _handleUserOnline);
    _hub.on('UserOffline', _handleUserOffline);

    // --- Room Membership ---
    _hub.on('UserJoined', _handleUserJoined);
    _hub.on('UserLeft', _handleUserLeft);

    // --- Messaging ---
    _hub.on('ReceiveMessage', _handleReceiveMessage);
    _hub.on('ReceivePrivateMessage', _handleReceivePrivateMessage);
    _hub.on('UserTyping', _handleUserTyping);
    _hub.on('MessageRead', _handleMessageRead); // Added
    _hub.on('MessageEdited', _handleMessageEdited); // Added
    _hub.on('MessageDeleted', _handleMessageDeleted); // Added
  }

  // --- Hub Event Handler Implementations ---

  void _handleUserOnline(List<Object?>? args) {
    if (args != null && args.isNotEmpty) {
      final user = args[0] as String;
      debugPrint('User Online: $user');
      if (mounted) {
        setState(() {
          _onlineUsers.add(user);
          // Optional: Add a system message or update a user list UI
          _messages.add(_ChatMessage.system('-- $user is online --'));
        });
        _scrollToBottom();
      }
    }
  }

  void _handleUserOffline(List<Object?>? args) {
    if (args != null && args.isNotEmpty) {
      final user = args[0] as String;
      debugPrint('User Offline: $user');
      if (mounted) {
        setState(() {
          _onlineUsers.remove(user);
          _currentRoomMembers
              .remove(user); // Also remove from room if they were there
          // Optional: Add a system message or update a user list UI
          _messages.add(_ChatMessage.system('-- $user went offline --'));
        });
        _scrollToBottom();
      }
    }
  }

  void _handleUserJoined(List<Object?>? args) {
    if (args != null && args.length >= 2) {
      final room = args[0] as String;
      final userConnectionId = args[1] as String; // C# sends ConnectionId here
      // TODO: You might want the Hub to send the Username instead of ConnectionId
      // For now, we'll display the ConnectionId.
      final userIdentifier =
          userConnectionId; // Replace with username if available
      debugPrint('User Joined Room: $userIdentifier in $room');
      if (room == _currentRoom && mounted) {
        setState(() {
          _currentRoomMembers.add(userIdentifier);
          _messages
              .add(_ChatMessage.system('-- $userIdentifier joined $room --'));
        });
        _scrollToBottom();
      }
    }
  }

  void _handleUserLeft(List<Object?>? args) {
    if (args != null && args.length >= 2) {
      final room = args[0] as String;
      final userConnectionId = args[1] as String; // C# sends ConnectionId
      final userIdentifier =
          userConnectionId; // Replace with username if available
      debugPrint('User Left Room: $userIdentifier from $room');
      if (room == _currentRoom && mounted) {
        setState(() {
          _currentRoomMembers.remove(userIdentifier);
          _messages
              .add(_ChatMessage.system('-- $userIdentifier left $room --'));
        });
        _scrollToBottom();
      }
    }
  }

  void _handleReceiveMessage(List<Object?>? args) {
    if (args != null && args.length >= 4) {
      final room = args[0] as String;
      final user = args[1] as String;
      final text = args[2] as String;
      final timestampStr = args[3] as String;
      // Assuming the C# Hub sends a message ID as the 5th argument now
      // If not, you'll need to adjust the C# Hub method `SendMessage`
      final messageId = args.length > 4 && args[4] is String
          ? args[4] as String
          : _generateUniqueId(); // Generate ID if not sent or not string

      final ts = DateTime.tryParse(timestampStr)?.toLocal() ?? DateTime.now();

      debugPrint('Message Received: [$room] $user: $text (ID: $messageId)');

      if (room == _currentRoom && mounted) {
        setState(() {
          // Prevent adding duplicate messages if server echoes back sent message
          // (Depends on server implementation - adjust if needed)
          if (!_messages.any((m) => m.messageId == messageId)) {
            _messages.add(_ChatMessage(messageId, user, text, ts));
          }
        });
        _scrollToBottom();
      }
    }
  }

  void _handleReceivePrivateMessage(List<Object?>? args) {
    if (args != null && args.length >= 4) {
      final senderConnectionId = args[0] as String; // Sent by Hub
      final fromUser = args[1] as String;
      final message = args[2] as String;
      final timestampStr = args[3] as String;
      final messageId = args.length > 4 && args[4] is String
          ? args[4] as String
          : _generateUniqueId(); // Generate ID if not sent or not string

      final ts = DateTime.tryParse(timestampStr)?.toLocal() ?? DateTime.now();
      debugPrint(
          'Private Message Received from $fromUser (ID: $senderConnectionId): $message');

      // Add to message list, potentially with different styling
      if (mounted) {
        setState(() {
          _messages.add(_ChatMessage(
            messageId,
            fromUser,
            message,
            ts,
            isPrivate: true,
            senderConnectionId: senderConnectionId,
          ));
        });
        _scrollToBottom();
      }
      // TODO: Implement UI to distinguish private messages
      // TODO: Potentially open a separate chat window/tab for private messages
    }
  }

  void _handleUserTyping(List<Object?>? args) {
    if (args != null && args.length >= 2) {
      final room = args[0] as String;
      final user = args[1] as String;
      if (room == _currentRoom && user != _username && mounted) {
        setState(() => _typingUsers.add(user));
        // Simple timeout to remove typing indicator
        Timer(const Duration(seconds: 3), () {
          if (mounted) {
            // Check again if widget is still mounted before removing
            setState(() => _typingUsers.remove(user));
          }
        });
      }
    }
  }

  void _handleMessageRead(List<Object?>? args) {
    if (args != null && args.length >= 4) {
      final room = args[0] as String;
      final messageId = args[1] as String;
      final user = args[2] as String;
      final timestampStr = args[3] as String;
      final ts = DateTime.tryParse(timestampStr)?.toLocal() ?? DateTime.now();

      debugPrint('Message Read: ID $messageId by $user in $room at $ts');

      if (room == _currentRoom && mounted) {
        setState(() {
          // Find the message and update its read status
          final messageIndex =
              _messages.indexWhere((m) => m.messageId == messageId);
          if (messageIndex != -1) {
            _messages[messageIndex].markAsRead(user, ts);
            // TODO: Update UI to show read receipt (e.g., checkmarks)
          }
        });
      }
    }
  }

  void _handleMessageEdited(List<Object?>? args) {
    if (args != null && args.length >= 4) {
      final room = args[0] as String;
      final messageId = args[1] as String;
      final newText = args[2] as String;
      final timestampStr = args[3] as String;
      final ts = DateTime.tryParse(timestampStr)?.toLocal() ?? DateTime.now();

      debugPrint('Message Edited: ID $messageId in $room to "$newText" at $ts');

      if (room == _currentRoom && mounted) {
        setState(() {
          final messageIndex =
              _messages.indexWhere((m) => m.messageId == messageId);
          if (messageIndex != -1) {
            _messages[messageIndex].updateText(newText, ts);
            // TODO: Update UI to indicate the message was edited
          }
        });
      }
    }
  }

  void _handleMessageDeleted(List<Object?>? args) {
    if (args != null && args.length >= 2) {
      final room = args[0] as String;
      final messageId = args[1] as String;

      debugPrint('Message Deleted: ID $messageId in $room');

      if (room == _currentRoom && mounted) {
        setState(() {
          final messageIndex =
              _messages.indexWhere((m) => m.messageId == messageId);
          if (messageIndex != -1) {
            // Option 1: Remove the message entirely
            // _messages.removeAt(messageIndex);

            // Option 2: Replace with a "Message deleted" placeholder
            _messages[messageIndex].markAsDeleted();
            // TODO: Update UI to show "Message deleted" or similar
          }
        });
      }
    }
  }

  // --- Connection Management ---

  Future<void> _startConnection() async {
    if (_hubState == signalr.ConnectionState.Connected) {
      debugPrint('Already connected.');
      return;
    }
    if (mounted) {
      setState(() => _hubState = signalr.ConnectionState.Connecting);
    }
    try {
      await _hub.start();
      if (mounted) {
        setState(() => _hubState = signalr.ConnectionState.Connected);
        debugPrint('SignalR Connection Started. ConnectionId: ${_hub}');
        // Optional: Notify server that user is online immediately after connecting
        // This depends if OnConnectedAsync on server is sufficient
        // await _hub.invoke('NotifyOnline', args: [_username]);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _hubState = signalr.ConnectionState.Disconnected);
      }
      debugPrint('Connection error: $e');
      // Consider showing an error message to the user
    }
  }

  Future<void> _stopConnection() async {
    // Ensure we have a connection to stop and we are mounted
    if (_hubState != signalr.ConnectionState.Disconnected && mounted) {
      await _hub.stop();
      // Check mounted *again* after await before setting state
      if (mounted) {
        setState(() => _hubState = signalr.ConnectionState.Disconnected);
      }
      debugPrint('SignalR Connection Stopped.');
    }
  }

  // --- Client Action Methods (Invoking Hub Methods) ---

  /// Internal method to join a room without clearing messages (used on reconnect).
  Future<void> _joinRoomInternal(String roomName) async {
    if (_hubState != signalr.ConnectionState.Connected) return;
    try {
      await _hub.invoke('JoinRoom', args: [roomName]);
      debugPrint('Joined room internally: $roomName');
      // Optionally refresh room members after joining
      await _getGroupMembers(roomName);
    } catch (e) {
      debugPrint('Error joining room $roomName internally: $e');
      // Handle error appropriately
    }
  }

  /// Public method called by UI to join a room. Clears messages.
  Future<void> _joinRoom() async {
    final room = _roomCtrl.text.trim();
    if (room.isEmpty || _hubState != signalr.ConnectionState.Connected) return;

    // Leave current room first if already in one
    if (_currentRoom != null && _currentRoom != room) {
      await _leaveRoom(_currentRoom!);
    }

    // Clear state for the new room only if mounted
    if (mounted) {
      setState(() {
        _currentRoom = room;
        _messages.clear();
        _typingUsers.clear();
        _currentRoomMembers.clear();
        _messages.add(_ChatMessage.system('--- Joining $room... ---'));
      });
    } else {
      return; // Don't proceed if not mounted
    }

    try {
      await _hub.invoke('JoinRoom', args: [room]);
      // Check mounted again before setting state after await
      if (mounted) {
        setState(() {
          // Update system message after successful join
          _messages.removeWhere((m) => m.text == '--- Joining $room... ---');
          _messages.add(_ChatMessage.system('--- Joined $room ---'));
        });
      }
      debugPrint('Joined room: $room');
      await _getGroupMembers(room); // Fetch members after joining
    } catch (e) {
      debugPrint('Error joining room $room: $e');
      if (mounted) {
        setState(() {
          _messages.add(_ChatMessage.system('--- Failed to join $room ---'));
          _currentRoom = null; // Reset current room on failure
        });
      }
    }
  }

  /// Leaves the specified room.
  Future<void> _leaveRoom(String roomName) async {
    if (roomName.isEmpty || _hubState != signalr.ConnectionState.Connected)
      return;
    try {
      await _hub.invoke('LeaveRoom', args: [roomName]);
      debugPrint('Left room: $roomName');
      if (_currentRoom == roomName && mounted) {
        setState(() {
          _messages.add(_ChatMessage.system('--- You left $roomName ---'));
          _currentRoom = null;
          _currentRoomMembers.clear();
          _typingUsers.clear();
        });
      }
    } catch (e) {
      debugPrint('Error leaving room $roomName: $e');
      // Handle error appropriately
    }
  }

  /// Sends a message to the current room.
  Future<void> _sendMessage() async {
    final room = _currentRoom;
    final msg = _msgCtrl.text.trim();
    if (room == null ||
        msg.isEmpty ||
        _hubState != signalr.ConnectionState.Connected) return;

    // Generate a temporary client-side ID for optimistic UI update
    final tempId = _generateUniqueId();
    final now = DateTime.now();

    // Optimistically add message to UI
    final chatMessage = _ChatMessage(tempId, _username, msg, now);
    if (mounted) {
      setState(() {
        _messages.add(chatMessage);
      });
      _msgCtrl.clear();
      _scrollToBottom(); // Scroll after adding the message
    } else {
      return; // Don't proceed if not mounted
    }

    try {
      // Send to server. Ensure the server Hub method `SendMessage`
      // now accepts and potentially returns a message ID.
      // If the server sends back the same message via 'ReceiveMessage'
      // including the ID, the handler `_handleReceiveMessage` should
      // ideally update the existing message or ignore the duplicate.
      // Pass the timestamp and tempId
      await _hub.invoke('SendMessage', args: [room, _username, msg]);
      debugPrint('Message Sent: [$room] $_username: $msg (TempID: $tempId)');
    } catch (e) {
      debugPrint('Error sending message: $e');
      // Handle error: Mark the message as failed, allow retry?
      if (mounted) {
        setState(() {
          final index = _messages.indexWhere((m) => m.messageId == tempId);
          if (index != -1) {
            _messages[index].markAsFailed();
            // TODO: Update UI to show failed status
          }
        });
      }
    }
  }

  /// Sends a private message to a specific user (identified by Connection ID).
  Future<void> _sendPrivateMessage(
      String targetConnectionId, String message) async {
    if (targetConnectionId.isEmpty ||
        message.isEmpty ||
        _hubState != signalr.ConnectionState.Connected) return;

    final tempId = _generateUniqueId();
    final now = DateTime.now();

    // Optimistically add to UI (optional, depends on desired UX)
    // if(mounted) {
    //    setState(() {
    //      _messages.add(_ChatMessage(tempId, _username, message, now, isPrivate: true, recipientConnectionId: targetConnectionId));
    //    });
    //    _scrollToBottom();
    // }

    try {
      // Pass timestamp and tempId
      await _hub.invoke('SendPrivateMessage', args: [
        targetConnectionId,
        _username,
        message,
        now.toUtc().toIso8601String(),
        tempId
      ]);
      debugPrint(
          'Private Message Sent to $targetConnectionId: $message (TempID: $tempId)');
      // TODO: Add UI confirmation or handle server response if needed
    } catch (e) {
      debugPrint('Error sending private message: $e');
      // TODO: Handle error (e.g., sh43443ow snackbar)
    }
  }

  /// Notifies the room that the current user is typing.
  /// UPDATED: Use await and try-catch
  Future<void> _sendTypingNotification() async {
    // Changed to async
    if (_hubState != signalr.ConnectionState.Connected || _currentRoom == null)
      return;
    // Basic debounce check
    if (_typingDebounce?.isActive ?? false) return;

    // Set debounce timer immediately
    _typingDebounce =
        Timer(const Duration(seconds: 2), () {}); // Prevent spamming

    try {
      // Await the invoke call
      await _hub.invoke('Typing', args: [_currentRoom!, _username]);
      debugPrint('Sent typing notification successfully.');
    } catch (e) {
      // Catch potential errors during invoke/response processing
      debugPrint('Error sending typing notification: $e');
      // Check if it's the specific error we encountered
      if (e
          .toString()
          .contains("type 'Null' is not a subtype of type 'Object'")) {
        debugPrint(
            "Caught the 'Null' subtype error during Typing invoke. This might be a library issue with void returns.");
        // Potentially inform the user or log differently
      }
      // Optionally, reset debounce if sending failed?
      // _typingDebounce?.cancel();
    }
  }

  /// Sends a read receipt for a specific message.
  Future<void> _sendReadReceipt(String messageId) async {
    if (messageId.isEmpty ||
        _currentRoom == null ||
        _hubState != signalr.ConnectionState.Connected) return;
    try {
      // Pass timestamp
      await _hub.invoke('SendReadReceipt', args: [
        _currentRoom!,
        messageId,
        _username,
        DateTime.now().toUtc().toIso8601String()
      ]);
      debugPrint('Sent read receipt for message: $messageId');
    } catch (e) {
      debugPrint('Error sending read receipt: $e');
    }
  }

  /// Requests the list of members in the specified room.
  Future<void> _getGroupMembers(String roomName) async {
    if (roomName.isEmpty || _hubState != signalr.ConnectionState.Connected)
      return;
    try {
      final members = await _hub.invoke('GetGroupMembers', args: [roomName]);
      if (members is List) {
        // The Hub method returns List<string> which maps to List<dynamic> here
        final memberList = members.map((m) => m.toString()).toList();
        debugPrint('Members in room $roomName: $memberList');
        if (roomName == _currentRoom && mounted) {
          setState(() {
            _currentRoomMembers.clear();
            _currentRoomMembers.addAll(memberList);
            // TODO: Update UI to display room members
          });
        }
        // You might want to map ConnectionIDs to Usernames if possible
      } else {
        debugPrint(
            'Received unexpected type for group members: ${members?.runtimeType}');
      }
    } catch (e) {
      debugPrint('Error getting group members for $roomName: $e');
    }
  }

  /// Edits a previously sent message.
  Future<void> _editMessage(String messageId, String newText) async {
    if (messageId.isEmpty ||
        newText.isEmpty ||
        _currentRoom == null ||
        _hubState != signalr.ConnectionState.Connected) return;
    try {
      // Optimistic UI update (optional)
      // if(mounted) {
      //    setState(() {
      //      final index = _messages.indexWhere((m) => m.messageId == messageId);
      //      if (index != -1) _messages[index].updateText(newText, DateTime.now());
      //    });
      // }

      // Pass timestamp
      await _hub.invoke('EditMessage', args: [
        _currentRoom!,
        messageId,
        newText,
        DateTime.now().toUtc().toIso8601String()
      ]);
      debugPrint('Sent edit request for message $messageId to "$newText"');
    } catch (e) {
      debugPrint('Error editing message $messageId: $e');
      // TODO: Revert optimistic update or show error
    }
  }

  /// Deletes a message.
  Future<void> _deleteMessage(String messageId) async {
    if (messageId.isEmpty ||
        _currentRoom == null ||
        _hubState != signalr.ConnectionState.Connected) return;
    try {
      // Optimistic UI update (optional)
      // if(mounted) {
      //    setState(() {
      //      final index = _messages.indexWhere((m) => m.messageId == messageId);
      //      if (index != -1) _messages[index].markAsDeleted();
      //    });
      // }

      await _hub.invoke('DeleteMessage', args: [_currentRoom!, messageId]);
      debugPrint('Sent delete request for message $messageId');
    } catch (e) {
      debugPrint('Error deleting message $messageId: $e');
      // TODO: Revert optimistic update or show error
    }
  }

  // --- UI Logic ---

  /// Called when the message input text changes to send typing notification.
  void _onMessageChanged() {
    // Check if mounted before accessing controllers or sending notifications
    if (mounted && _msgCtrl.text.isNotEmpty) {
      _sendTypingNotification();
    }
  }

  /// Scrolls the message list to the bottom.
  void _scrollToBottom() {
    // Use addPostFrameCallback to ensure scrolling happens after the frame is built
    // and check if scroll controller is attached
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250), // Smooth scroll
          curve: Curves.easeOut,
        );
      }
    });
  }

  // --- Lifecycle ---

  @override
  void dispose() {
    // Clean up resources
    _typingDebounce?.cancel();
    // Don't call async methods like _stopConnection directly in dispose
    // The connection stop is initiated, but we don't await it here.
    // Consider if _hub.stop() needs to be awaited earlier in lifecycle if critical.
    _hub.stop();
    _roomCtrl.dispose();
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    debugPrint('ChatPage disposed.');
    super.dispose();
  }

  // --- Build Method ---

  @override
  Widget build(BuildContext context) {
    // Check mounted status at the beginning of build
    if (!mounted) {
      return const SizedBox.shrink(); // Return empty widget if not mounted
    }

    final bool isConnected = _hubState == signalr.ConnectionState.Connected;
    final bool isInRoom = _currentRoom != null && isConnected;
    final String statusText = {
      signalr.ConnectionState.Connecting: 'Connecting…',
      signalr.ConnectionState.Connected:
          'Connected as $_username', // Show username
      signalr.ConnectionState.Disconnected: 'Disconnected',
    }[_hubState]!;

    return Scaffold(
      appBar: AppBar(
        title: Text(_currentRoom ?? 'SignalR Chat'), // Show room name in title
        actions: [
          // Example: Button to leave the current room
          if (isInRoom)
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Leave Room',
              onPressed: () => _leaveRoom(_currentRoom!),
            ),
          // Example: Button to view room members (implement dialog/panel)
          if (isInRoom)
            IconButton(
              icon: const Icon(Icons.people),
              tooltip: 'Show Members (${_currentRoomMembers.length})',
              onPressed: () {
                // Ensure context is valid before showing dialog
                if (!mounted) return;
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('Members in $_currentRoom'),
                    content: SizedBox(
                      // Constrain height
                      height: 200,
                      width: 200,
                      child: _currentRoomMembers.isEmpty
                          ? const Center(child: Text('No other members found.'))
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: _currentRoomMembers.length,
                              itemBuilder: (ctx, index) => ListTile(
                                title: Text(_currentRoomMembers[index]),
                                // You might want to resolve ConnectionID to Username here
                              ),
                            ),
                    ),
                    actions: [
                      TextButton(
                          onPressed: Navigator.of(context).pop,
                          child: const Text('Close'))
                    ],
                  ),
                );
              },
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Text(statusText,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.white70)),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // --- Join Room Section ---
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _roomCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Room Name',
                      hintText: 'Enter room to join',
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    enabled: isConnected, // Can only change room if connected
                    onSubmitted: (_) =>
                        isConnected ? _joinRoom() : null, // Join on enter
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.login),
                  label: const Text('Join'),
                  onPressed: isConnected ? _joinRoom : null,
                  style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10)),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // --- Message List ---
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                // Use ClipRRect to ensure children respect the border radius
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) {
                      // Check bounds to prevent range errors if messages list changes rapidly
                      if (i >= _messages.length) return const SizedBox.shrink();
                      final m = _messages[i];
                      final isMe = m.user == _username;

                      // TODO: Add context menu (on long press) for edit/delete
                      return _buildMessageTile(m, isMe);
                    },
                  ),
                ),
              ),
            ),

            // --- Typing Indicator ---
            // Use AnimatedOpacity for smoother appearance/disappearance
            AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: _typingUsers.isNotEmpty ? 1.0 : 0.0,
              child: _typingUsers.isNotEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 4, horizontal: 8),
                      child: Text(
                        '${_typingUsers.join(', ')} ${_typingUsers.length > 1 ? "are" : "is"} typing…',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontStyle: FontStyle.italic),
                      ),
                    )
                  : const SizedBox(
                      height: 20), // Reserve space even when hidden
            ),

            // --- Message Input ---
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _msgCtrl,
                      decoration: InputDecoration(
                        labelText: 'Message',
                        hintText: isInRoom
                            ? 'Enter message...'
                            : 'Join a room to send messages',
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                      ),
                      enabled:
                          isInRoom, // Can only send if connected AND in a room
                      onSubmitted: (_) =>
                          isInRoom ? _sendMessage() : null, // Send on enter
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.send),
                    label: const Text('Send'),
                    onPressed: isInRoom ? _sendMessage : null,
                    style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Helper widget to build message list tiles
  Widget _buildMessageTile(_ChatMessage m, bool isMe) {
    // TODO: Enhance styling significantly
    // TODO: Add indicators for edited, deleted, failed, read receipts
    // TODO: Add long-press menu for edit/delete actions

    Widget title;
    if (m.isSystem) {
      title = Text(m.text,
          style:
              const TextStyle(fontStyle: FontStyle.italic, color: Colors.grey));
    } else if (m.isDeleted) {
      title = Text(
          isMe ? 'You deleted this message' : '${m.user} deleted this message',
          style:
              const TextStyle(fontStyle: FontStyle.italic, color: Colors.grey));
    } else if (m.isPrivate) {
      // Ensure recipientConnectionId is not null before using it
      final recipientText = m.recipientConnectionId ?? 'unknown recipient';
      title = Text.rich(
        TextSpan(children: [
          TextSpan(
              text: isMe ? 'You (to $recipientText)' : '${m.user} (private)',
              style: TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.purple[300])),
          TextSpan(text: ': ${m.text}'),
          if (m.isEdited)
            const TextSpan(
                text: ' (edited)',
                style: TextStyle(fontSize: 10, color: Colors.grey)),
        ]),
      );
    } else {
      title = Text.rich(
        TextSpan(children: [
          TextSpan(
              text: isMe ? 'You' : m.user,
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isMe ? Colors.blue : Colors.green)),
          TextSpan(text: ': ${m.text}'),
          if (m.isEdited)
            const TextSpan(
                text: ' (edited)',
                style: TextStyle(fontSize: 10, color: Colors.grey)),
        ]),
      );
    }

    return Align(
      // Use FractionallySizedBox to limit width of message bubbles
      alignment: isMe
          ? Alignment.centerRight
          : (m.isSystem ? Alignment.center : Alignment.centerLeft),
      child: FractionallySizedBox(
        widthFactor: 0.8, // Max width 80% of available space
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
          decoration: BoxDecoration(
              // Use theme colors for better adaptability
              color: isMe
                  ? Theme.of(context).colorScheme.primaryContainer
                  : (m.isSystem
                      ? Theme.of(context)
                          .colorScheme
                          .secondaryContainer
                          .withOpacity(0.5)
                      : Theme.of(context).colorScheme.secondaryContainer),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                // Add subtle shadow
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                )
              ]),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min, // Ensure column takes minimum space
            children: [
              title,
              if (!m.isSystem && !m.isDeleted)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Text(
                    // Format timestamp more nicely
                    '${m.timestamp.hour}:${m.timestamp.minute.toString().padLeft(2, '0')}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSecondaryContainer
                            .withOpacity(0.7)),
                  ),
                ),
              // TODO: Add read receipt indicator here based on m.readBy
              // Example: if (isMe && m.readBy.isNotEmpty) Icon(Icons.done_all, size: 12, color: Colors.blue)
              if (m.hasFailed) // Indicate failed messages
                const Padding(
                  padding: EdgeInsets.only(top: 2.0),
                  child: Icon(Icons.error_outline, size: 12, color: Colors.red),
                )
            ],
          ),
        ),
      ),
    );
  }

  // Helper to generate unique IDs (replace with a proper UUID package if needed)
  String _generateUniqueId() {
    // Use time and random for slightly better uniqueness than just random double
    return '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(99999)}';
  }
}

/// Enhanced model for a chat message
class _ChatMessage {
  final String messageId; // Unique ID for the message
  final String user;
  String text; // Mutable for edits
  DateTime timestamp; // Mutable for edits
  final bool isSystem;
  final bool isPrivate;
  final String? senderConnectionId; // For received private messages
  final String? recipientConnectionId; // For sent private messages
  bool isEdited;
  bool isDeleted;
  bool hasFailed; // For optimistic UI send failures
  final Map<String, DateTime> readBy; // Track who read it and when

  _ChatMessage(this.messageId, this.user, this.text, this.timestamp,
      {this.isPrivate = false,
      this.senderConnectionId,
      this.recipientConnectionId})
      : isSystem = false,
        isEdited = false,
        isDeleted = false,
        hasFailed = false,
        readBy = {};

  _ChatMessage.system(this.text)
      : messageId = _generateUniqueIdStatic(), // System messages need IDs too
        user = '',
        timestamp = DateTime.now(),
        isSystem = true,
        isPrivate = false,
        senderConnectionId = null,
        recipientConnectionId = null,
        isEdited = false,
        isDeleted = false,
        hasFailed = false,
        readBy = {};

  // Static helper for system message IDs
  static String _generateUniqueIdStatic() =>
      'sys_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(99999)}';

  void updateText(String newText, DateTime editTimestamp) {
    text = newText;
    timestamp = editTimestamp; // Update timestamp to reflect edit time
    isEdited = true;
  }

  void markAsDeleted() {
    isDeleted = true;
    text = ''; // Clear text or set placeholder
    isEdited = false; // Cannot be edited if deleted
  }

  void markAsFailed() {
    hasFailed = true;
  }

  void markAsRead(String readerUser, DateTime readTimestamp) {
    // Only add if not already marked by this user, or update timestamp
    readBy[readerUser] = readTimestamp;
  }
}
