/// The tickets this person has sent, and what the admin said back.
///
/// Without this the app could only send: an answer written in the dashboard
/// had nowhere to appear, so every ticket ended in silence.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../config/routes.dart';
import '../../config/theme.dart';
import '../../core/services/ticket_service.dart';
import '../../widgets/state_views.dart';

class MyTicketsScreen extends StatelessWidget {
  const MyTicketsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My tickets'),
        actions: [
          IconButton(
            tooltip: 'Send a new ticket',
            onPressed: () => Navigator.pushNamed(context, AppRoutes.sendTicket),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: TicketService.instance.mine(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ErrorView(
              message: 'Could not load your tickets.',
              onRetry: () => (context as Element).markNeedsBuild(),
            );
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.support_agent,
                      size: 56,
                      color: AppTheme.textMuted,
                    ),
                    SizedBox(height: 12),
                    Text(
                      'You have not sent any tickets yet.\nUse the + button to '
                      'tell your TODA admin about a problem.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.textMuted),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final doc = docs[i];
              final data = doc.data();
              final state = TicketState.of(data);
              return Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListTile(
                  title: Text(
                    (data['subject'] as String?) ?? 'Ticket',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    (data['description'] as String?) ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: _StateChip(state: state),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          TicketThreadScreen(ticketId: doc.id, ticket: data),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});

  final TicketState state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      TicketState.open => AppTheme.warning,
      TicketState.answered => AppTheme.info,
      TicketState.resolved => AppTheme.success,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        state.label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// One ticket: what was written, what the admin answered, and a box to
/// write back.
class TicketThreadScreen extends StatefulWidget {
  const TicketThreadScreen({
    super.key,
    required this.ticketId,
    required this.ticket,
  });

  final String ticketId;
  final Map<String, dynamic> ticket;

  @override
  State<TicketThreadScreen> createState() => _TicketThreadScreenState();
}

class _TicketThreadScreenState extends State<TicketThreadScreen> {
  final _text = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await TicketService.instance.reply(widget.ticketId, text);
      _text.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final subject = (widget.ticket['subject'] as String?) ?? 'Ticket';
    return Scaffold(
      appBar: AppBar(title: Text(subject)),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<TicketMessage>>(
              stream: TicketService.instance.thread(widget.ticketId),
              builder: (context, snapshot) {
                final messages = snapshot.data ?? const <TicketMessage>[];
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // What they first wrote starts the conversation.
                    _Bubble(
                      mine: true,
                      text: (widget.ticket['description'] as String?) ?? '',
                      at: (widget.ticket['createdAt'] as Timestamp?)?.toDate(),
                    ),
                    for (final m in messages)
                      _Bubble(
                        mine: !m.fromAdmin,
                        text: m.text,
                        at: m.at,
                        who: m.fromAdmin
                            ? (m.byName ?? 'Your TODA admin')
                            : null,
                      ),
                  ],
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 2000,
                      decoration: const InputDecoration(
                        hintText: 'Write a reply…',
                        counterText: '',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.mine, required this.text, this.at, this.who});

  final bool mine;
  final String text;
  final DateTime? at;
  final String? who;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: mine
              ? AppTheme.primaryGreen
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (who != null || at != null)
              Text(
                [?who, if (at != null) _time(at!)].join(' · '),
                style: TextStyle(
                  fontSize: 11,
                  color: mine ? Colors.white70 : AppTheme.textMuted,
                ),
              ),
            Text(
              text,
              style: TextStyle(color: mine ? Colors.white : null, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  static String _time(DateTime t) =>
      '${t.day}/${t.month} ${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}
