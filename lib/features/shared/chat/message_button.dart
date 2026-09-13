/// The Message button on a trip screen: how many messages are waiting, and
/// the way into the thread.
///
/// It holds the listener rather than the chat screen, for two reasons. A
/// driver must hear a message whether or not they opened the thread — they
/// are driving — and hearing it once, which needs one place deciding what
/// has already been said. And the badge has to count while the thread is
/// closed, which is the only time it means anything.
library;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../config/theme.dart';
import '../../../core/models/trip_message.dart';
import '../../../core/services/chat_service.dart';
import '../../../core/services/voice_service.dart';
import 'trip_chat_screen.dart';

class MessageButton extends StatefulWidget {
  const MessageButton({
    super.key,
    required this.bookingId,
    required this.role,
    required this.otherName,
    this.speakIncoming = false,
    this.compact = false,
  });

  final String bookingId;

  /// Which side this phone is.
  final MessageSender role;

  /// Who the thread is with, for the title and the spoken line.
  final String otherName;

  /// Read arriving messages aloud — on for the driver, who should not be
  /// reading a screen.
  final bool speakIncoming;

  /// A narrower button, for rows that already carry a Call beside it.
  final bool compact;

  @override
  State<MessageButton> createState() => _MessageButtonState();
}

class _MessageButtonState extends State<MessageButton> {
  /// When the thread was last opened on this phone. In memory on purpose:
  /// it only has to outlive the trip, and a badge that survives a restart
  /// would need a write per read message.
  DateTime? _lastOpened;

  /// The newest message already spoken, so a rebuild does not repeat it.
  String? _spokenUpTo;
  bool _seenFirstBatch = false;

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  void _speakNew(List<TripMessage> messages) {
    if (!widget.speakIncoming || messages.isEmpty) return;
    final last = messages.last;
    if (last.mine(_uid)) return;
    // The first batch is the backlog, not news: speaking it would recite
    // the whole conversation the moment the trip screen opens.
    if (!_seenFirstBatch) {
      _seenFirstBatch = true;
      _spokenUpTo = last.id;
      return;
    }
    if (_spokenUpTo == last.id) return;
    _spokenUpTo = last.id;
    VoiceService.instance.speak('${widget.otherName} says: ${last.text}');
  }

  Future<void> _open() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TripChatScreen(
          bookingId: widget.bookingId,
          role: widget.role,
          otherName: widget.otherName,
        ),
      ),
    );
    if (mounted) setState(() => _lastOpened = DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<TripMessage>>(
      stream: ChatService.instance.watch(widget.bookingId),
      builder: (context, snapshot) {
        final messages = snapshot.data ?? const <TripMessage>[];
        _speakNew(messages);
        final unread = unreadFrom(messages, _uid, _lastOpened);

        final label = Text(
          unread > 0 ? 'Message ($unread)' : 'Message',
          style: TextStyle(fontSize: widget.compact ? 12 : 14),
        );
        return OutlinedButton.icon(
          onPressed: _open,
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(Icons.chat_bubble_outline, size: widget.compact ? 16 : 18),
              if (unread > 0)
                Positioned(
                  top: -4,
                  right: -4,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppTheme.errorRed,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
          label: label,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.primaryGreen,
            side: const BorderSide(color: AppTheme.primaryGreen),
          ),
        );
      },
    );
  }
}
