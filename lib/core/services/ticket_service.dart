/// Support tickets, and the conversation on each one.
///
/// A ticket used to be a note sent into silence: an admin could mark it
/// resolved, but had no way to answer, so the person never learned what was
/// decided. A ticket now carries a thread that both sides write to, and its
/// status says whose turn it is: `open` waits on an admin, `answered` waits
/// on the person, `resolved` is done. Only an admin may resolve one (see the
/// security rules).
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// One thing said on a ticket, by either side.
class TicketMessage {
  const TicketMessage({
    required this.id,
    required this.fromAdmin,
    required this.text,
    this.byName,
    this.at,
  });

  final String id;
  final bool fromAdmin;
  final String text;
  final String? byName;
  final DateTime? at;

  static TicketMessage fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    return TicketMessage(
      id: doc.id,
      fromAdmin: data['from'] == 'admin',
      text: (data['text'] as String?) ?? '',
      byName: data['byName'] as String?,
      at: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// Where a ticket stands, and who it is waiting on.
enum TicketState {
  open('open', 'Waiting for a reply'),
  answered('answered', 'Answered'),
  resolved('resolved', 'Resolved');

  const TicketState(this.wire, this.label);
  final String wire;
  final String label;

  static TicketState of(Map<String, dynamic>? data) {
    final stored = data?['status'] as String?;
    for (final s in TicketState.values) {
      if (s.wire == stored) return s;
    }
    return TicketState.open; // older tickets carry no status
  }
}

class TicketService {
  TicketService._();
  static final TicketService instance = TicketService._();

  CollectionReference<Map<String, dynamic>> get _tickets =>
      FirebaseFirestore.instance.collection('tickets');

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  /// The signed-in person's own tickets, newest first.
  Stream<QuerySnapshot<Map<String, dynamic>>> mine() {
    final uid = _uid;
    if (uid == null) return const Stream.empty();
    return _tickets
        .where('userId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  /// The conversation on [ticketId], oldest first.
  Stream<List<TicketMessage>> thread(String ticketId) => _tickets
      .doc(ticketId)
      .collection('messages')
      .orderBy('createdAt')
      .snapshots()
      .map((snap) => snap.docs.map(TicketMessage.fromDoc).toList());

  /// Adds a reply from the person who raised the ticket, and puts it back
  /// in front of the admins.
  Future<void> reply(String ticketId, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _tickets.doc(ticketId).collection('messages').add({
      'from': 'user',
      'text': trimmed,
      'createdAt': FieldValue.serverTimestamp(),
    });
    try {
      await _tickets.doc(ticketId).set({
        'status': 'open',
        'lastMessageAt': FieldValue.serverTimestamp(),
        'lastFrom': 'user',
      }, SetOptions(merge: true));
    } on FirebaseException catch (e) {
      // The reply is already saved; the status is only a hint to the admin.
      debugPrint('Ticket: could not reopen it (${e.code})');
    }
  }
}
