/// The private half of a person's profile: phone, email, ID photograph,
/// selfie.
///
/// These used to sit on the user document itself, which every signed-in
/// account could read — 78 phone numbers and 14 government ID photographs
/// available to anyone who registered. They now live at
/// `users/{uid}/private/contact`, readable only by that person and by the
/// admins who verify them.
///
/// What replaces the old access: the two people on a trip exchange phone
/// numbers through the booking, which only they and an admin can read. Each
/// side writes their own number there — nobody reads anyone else's private
/// document to get it.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class Contact {
  final String? phone;
  final String? email;
  final String? idPhotoUrl;
  final String? selfieUrl;

  const Contact({this.phone, this.email, this.idPhotoUrl, this.selfieUrl});

  static const Contact none = Contact();

  bool get isEmpty =>
      phone == null && email == null && idPhotoUrl == null && selfieUrl == null;

  static Contact fromMap(Map<String, dynamic>? data) {
    String? s(String key) {
      final v = data?[key];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    return Contact(
      phone: s('phone'),
      email: s('email'),
      idPhotoUrl: s('idPhotoUrl'),
      selfieUrl: s('selfieUrl'),
    );
  }

  Map<String, dynamic> toMap() => {
    if (phone != null) 'phone': phone,
    if (email != null) 'email': email,
    if (idPhotoUrl != null) 'idPhotoUrl': idPhotoUrl,
    if (selfieUrl != null) 'selfieUrl': selfieUrl,
  };
}

class ContactService {
  static final ContactService instance = ContactService._();
  ContactService._();

  static DocumentReference<Map<String, dynamic>> refFor(String uid) =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('private')
          .doc('contact');

  /// [uid]'s contact details — only readable for yourself or as an admin.
  /// Anything else comes back empty rather than throwing.
  Future<Contact> of(String uid) async {
    try {
      final snap = await refFor(uid).get();
      return Contact.fromMap(snap.data());
    } on FirebaseException catch (e) {
      debugPrint('Contact: could not read $uid (${e.code})');
      return Contact.none;
    }
  }

  /// The signed-in person's own details.
  Future<Contact> mine() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Contact.none;
    return of(uid);
  }

  /// Follows the signed-in person's own details, for a profile screen.
  Stream<Contact> watchMine() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value(Contact.none);
    return refFor(uid)
        .snapshots()
        .map((snap) => Contact.fromMap(snap.data()))
        .handleError((Object e) {
          debugPrint('Contact: listener stopped ($e)');
        }, test: (e) => e is FirebaseException);
  }

  /// Writes [contact] for [uid], merging so one field can be changed alone.
  Future<void> save(String uid, Contact contact) async {
    if (contact.isEmpty) return;
    await refFor(uid).set(contact.toMap(), SetOptions(merge: true));
  }

  /// Puts the signed-in person's own phone number onto [bookingId], so the
  /// other party can reach them for the length of the trip without either
  /// side being able to read the user directory.
  Future<void> shareNumberOnBooking({
    required String bookingId,
    required bool asDriver,
  }) async {
    final phone = (await mine()).phone;
    if (phone == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('bookings')
          .doc(bookingId)
          .set({
            asDriver ? 'driverPhone' : 'passengerPhone': phone,
          }, SetOptions(merge: true));
    } on FirebaseException catch (e) {
      // The trip works without it; Call simply stays unavailable.
      debugPrint('Contact: could not share the number (${e.code})');
    }
  }
}
