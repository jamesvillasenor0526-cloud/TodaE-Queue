/// Reading and writing a trip's messages.
///
/// The thread hangs off the booking, so it is reached by anyone who can
/// already see the trip and disappears from neither side when the other
/// app closes. Ordered oldest first, capped: a conversation about finding
/// a pick-up point is a dozen messages, and nothing here should ever pull
/// down hundreds of documents on a driver's phone plan.
///
/// See trip_message.dart for why this only claims to work during a trip.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/trip_message.dart';

/// The most recent messages a thread loads. Beyond this, older ones stay in
/// the database — read by an admin looking into a complaint — but are not
/// pulled onto a phone.
const int kMessagePageSize = 100;

class ChatService {
  static final ChatService instance = ChatService._();
  ChatService._();

  final _firestore = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  CollectionReference<Map<String, dynamic>> _thread(String bookingId) =>
      _firestore.collection('bookings').doc(bookingId).collection('messages');

  /// The conversation, oldest first, updating as it goes.
  ///
  /// Firestore is asked for the newest [kMessagePageSize] and the list is
  /// turned round here: asking for the oldest would pin the thread to the
  /// start of a long conversation instead of its end.
  Stream<List<TripMessage>> watch(String bookingId) => _thread(bookingId)
      .orderBy('sentAt', descending: true)
      .limit(kMessagePageSize)
      .snapshots()
      .map((snap) {
        final messages = <TripMessage>[];
        for (final doc in snap.docs.reversed) {
          final message = TripMessage.fromMap(
            doc.id,
            doc.data(),
            toDate: (v) => v is Timestamp ? v.toDate() : null,
          );
          if (message != null) messages.add(message);
        }
        return messages;
      })
      .handleError((Object e) {
        // A thread failing is never worth taking a trip screen down with it.
        debugPrint('Chat: could not read the thread: $e');
      }, test: (e) => e is FirebaseException);

  /// Sends [text] as [sender]. Does nothing if there is nothing to send.
  ///
  /// Returns false when it could not be written, so the screen can say so
  /// rather than showing a message that is not there.
  Future<bool> send({
    required String bookingId,
    required MessageSender sender,
    required String text,
  }) async {
    final tidy = cleanMessage(text);
    final uid = _auth.currentUser?.uid;
    if (tidy == null || uid == null) return false;
    try {
      await _thread(bookingId).add({
        'senderId': uid,
        'senderRole': sender.wire,
        'text': tidy,
        'sentAt': FieldValue.serverTimestamp(),
      });
      return true;
    } on FirebaseException catch (e) {
      debugPrint('Chat: could not send: ${e.code}');
      return false;
    }
  }
}
