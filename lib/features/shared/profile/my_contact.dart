/// Shows the signed-in person their own contact details.
///
/// Their phone, email and identity photographs live in a private record
/// that only they and an admin can read (see contact_service.dart), so a
/// profile screen can no longer read them off the user document alongside
/// the name. This fetches them properly, for the one person entitled to see
/// them.
library;

import 'package:flutter/material.dart';

import '../../../core/services/contact_service.dart';

class MyContact extends StatelessWidget {
  const MyContact({super.key, required this.builder});

  final Widget Function(BuildContext context, Contact contact) builder;

  @override
  Widget build(BuildContext context) => StreamBuilder<Contact>(
    stream: ContactService.instance.watchMine(),
    builder: (context, snapshot) =>
        builder(context, snapshot.data ?? Contact.none),
  );
}
