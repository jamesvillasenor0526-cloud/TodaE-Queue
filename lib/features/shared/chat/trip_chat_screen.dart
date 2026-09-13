/// The conversation between a driver and their passenger, for one trip.
///
/// One screen, both sides, told apart by [role]:
///
///   * the driver's side leads with taps, not a keyboard. Reading and
///     typing at 30 km/h is how people crash, so the quick replies sit
///     above the fold. Arriving messages are read aloud, but by the button
///     that opens this screen (see message_button.dart) — it is on the trip
///     screen the whole time, so a driver hears a message whether or not
///     they opened the thread, and hears it exactly once.
///   * the passenger's side leads with the keyboard: they are standing
///     still.
///
/// Both are told plainly that messages reach the other phone while the trip
/// is running. Nothing here can wake a closed app — see trip_message.dart.
library;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../config/theme.dart';
import '../../../core/models/trip_message.dart';
import '../../../core/services/chat_service.dart';

class TripChatScreen extends StatefulWidget {
  const TripChatScreen({
    super.key,
    required this.bookingId,
    required this.role,
    required this.otherName,
  });

  final String bookingId;

  /// Which side this phone is.
  final MessageSender role;

  /// Who they are talking to, for the title.
  final String otherName;

  @override
  State<TripChatScreen> createState() => _TripChatScreenState();
}

class _TripChatScreenState extends State<TripChatScreen> {
  final _field = TextEditingController();
  final _scroll = ScrollController();

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  bool _sending = false;

  @override
  void dispose() {
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send(String text) async {
    if (_sending || !worthSendingMessage(text)) return;
    setState(() => _sending = true);
    final sent = await ChatService.instance.send(
      bookingId: widget.bookingId,
      sender: widget.role,
      text: text,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (sent) {
      _field.clear();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("That didn't send. Check your signal and try again."),
        ),
      );
    }
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final quickReplies = widget.role == MessageSender.driver
        ? kDriverQuickReplies
        : kPassengerQuickReplies;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.otherName),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(22),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Messages arrive while the trip is running',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<TripMessage>>(
              stream: ChatService.instance.watch(widget.bookingId),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  );
                }
                final messages = snapshot.data!;
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _scrollToEnd(),
                );

                if (messages.isEmpty) {
                  return const _EmptyThread();
                }
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(AppSpacing.md),
                  itemCount: messages.length,
                  itemBuilder: (context, i) => _Bubble(
                    message: messages[i],
                    mine: messages[i].mine(_uid),
                  ),
                );
              },
            ),
          ),
          _QuickReplies(replies: quickReplies, onPick: _sending ? null : _send),
          _Composer(
            field: _field,
            sending: _sending,
            // The driver's keyboard is there if they are stopped and want
            // it; it is simply not what their side leads with.
            hint: widget.role == MessageSender.driver
                ? 'Type only when stopped'
                : 'Type a message',
            onSend: () => _send(_field.text),
          ),
        ],
      ),
    );
  }
}

class _EmptyThread extends StatelessWidget {
  const _EmptyThread();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.chat_bubble_outline,
            size: 44,
            color: AppTheme.textMuted,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'No messages yet. Tap one of the lines below, or type.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppTheme.textMuted),
          ),
        ],
      ),
    ),
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});

  final TripMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final at = message.sentAt;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: mine ? AppTheme.primaryGreen : Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: mine ? null : Border.all(color: AppTheme.borderLight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.text,
              style: TextStyle(
                color: mine ? Colors.white : AppTheme.textPrimaryLight,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              // No timestamp yet means it is still on its way out.
              at == null
                  ? 'Sending…'
                  : TimeOfDay.fromDateTime(at).format(context),
              style: TextStyle(
                fontSize: 11,
                color: mine ? Colors.white70 : AppTheme.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickReplies extends StatelessWidget {
  const _QuickReplies({required this.replies, required this.onPick});

  final List<String> replies;
  final void Function(String)? onPick;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      itemCount: replies.length,
      separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
      itemBuilder: (context, i) => Center(
        child: ActionChip(
          label: Text(replies[i]),
          onPressed: onPick == null ? null : () => onPick!(replies[i]),
        ),
      ),
    ),
  );
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.field,
    required this.sending,
    required this.hint,
    required this.onSend,
  });

  final TextEditingController field;
  final bool sending;
  final String hint;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: field,
              enabled: !sending,
              maxLength: kMessageMaxLength,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText: hint,
                counterText: '',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          IconButton.filled(
            onPressed: sending ? null : onSend,
            icon: sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.send),
          ),
        ],
      ),
    ),
  );
}
