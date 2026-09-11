/// Calling and texting from the app — the driver calling the passenger, the
/// passenger calling the driver.
///
/// The buttons did nothing at all. Each asked `canLaunchUrl` first, and on
/// Android 11 and later that answers false unless the manifest declares
/// that the app uses the dialer and the SMS app, which ours did not — so
/// every tap was silently dropped. The manifest now declares both, and this
/// no longer asks first: it opens the dialer or SMS app, and when that
/// fails it says so with the number, so the call can still be made by hand.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// [raw] as something a dialer accepts: digits, with a leading + kept.
/// "0981 384-8362" → "09813848362", "+63 (981) 384 8362" → "+639813848362".
/// Null when nothing dialable is left.
String? dialableNumber(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length < 3) return null;
  return trimmed.startsWith('+') ? '+$digits' : digits;
}

/// Opens the dialer with [raw] filled in. The call itself is the user's to
/// place — nothing is dialled without them.
Future<void> callNumber(BuildContext context, String? raw, {String? who}) =>
    _open(context, raw, 'tel', who: who, verb: 'call');

/// Opens the SMS app addressed to [raw].
Future<void> textNumber(BuildContext context, String? raw, {String? who}) =>
    _open(context, raw, 'sms', who: who, verb: 'message');

Future<void> _open(
  BuildContext context,
  String? raw,
  String scheme, {
  required String verb,
  String? who,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final number = dialableNumber(raw);
  if (number == null) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          who == null
              ? 'No phone number on file.'
              : "$who's phone number isn't on file.",
        ),
      ),
    );
    return;
  }
  var opened = false;
  try {
    opened = await launchUrl(
      Uri(scheme: scheme, path: number),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    opened = false;
  }
  if (opened) return;
  messenger.showSnackBar(
    SnackBar(
      content: Text("Couldn't open the phone app. $verb $number yourself."),
      action: SnackBarAction(
        label: 'Copy',
        onPressed: () => Clipboard.setData(ClipboardData(text: number)),
      ),
    ),
  );
}
