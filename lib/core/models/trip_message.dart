/// Messages between the driver and the passenger of one trip.
///
/// Why in the app at all: today the Message button hands the other person's
/// real mobile number to the SMS app, so every trip swaps two phone numbers
/// that neither party can take back. A thread that lives on the booking
/// keeps them apart, and keeps the conversation where a TODA admin can read
/// it if someone complains.
///
/// Why only during a trip: a message is delivered by the live listener both
/// apps already hold open on the booking. Waking a phone whose app is
/// closed needs a push, and a push needs a server — so this promises what
/// it can keep, and the screens say so. Call is still the honest choice
/// before a driver accepts and after the trip ends.
///
/// Pure — no Firebase — so the rules about what may be sent are tested
/// without a device.
library;

/// Who sent it. Stored so a thread reads correctly even after a driver or
/// passenger is renamed or removed.
enum MessageSender {
  driver('driver'),
  passenger('passenger');

  const MessageSender(this.wire);
  final String wire;

  static MessageSender? fromWire(String? s) {
    for (final v in values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

/// Long enough for an address or a landmark, short enough that one message
/// cannot fill a booking document's neighbours or a driver's screen.
const int kMessageMaxLength = 500;

/// Tidies what was typed: trimmed, runs of blank lines collapsed to one, and
/// cut to [kMessageMaxLength]. Nothing usable becomes null.
String? cleanMessage(String? typed) {
  if (typed == null) return null;
  final tidy = typed
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  if (tidy.isEmpty) return null;
  return tidy.length <= kMessageMaxLength
      ? tidy
      : tidy.substring(0, kMessageMaxLength).trimRight();
}

/// Whether there is anything worth sending.
bool worthSendingMessage(String? typed) => cleanMessage(typed) != null;

/// What a driver can send without typing.
///
/// A driver reading a keyboard at 30 km/h is how people crash, so their side
/// is taps by default. These are the things a tricycle driver actually says
/// while looking for someone.
const List<String> kDriverQuickReplies = [
  'On my way',
  '5 minutes away',
  "I'm here",
  "I can't find you — where exactly?",
  'Please wait a moment',
];

/// And what a passenger can send without typing, for the same reason in
/// reverse: they are often standing in the sun with one hand full.
const List<String> kPassengerQuickReplies = [
  "I'm waiting outside",
  'Coming out now',
  'Please wait a moment',
  'Where are you?',
];

class TripMessage {
  final String id;
  final String senderId;
  final MessageSender sender;
  final String text;
  final DateTime? sentAt;

  const TripMessage({
    required this.id,
    required this.senderId,
    required this.sender,
    required this.text,
    this.sentAt,
  });

  /// True when this was written by [uid] — which is how a thread decides
  /// which side of the screen a bubble sits on.
  bool mine(String? uid) => uid != null && uid == senderId;

  static TripMessage? fromMap(
    String id,
    Map<String, dynamic> data, {
    required DateTime? Function(dynamic) toDate,
  }) {
    final text = cleanMessage(data['text'] as String?);
    final sender = MessageSender.fromWire(data['senderRole'] as String?);
    final senderId = data['senderId'];
    // A message with no words, no sender, or no author is not a message.
    // Dropped rather than rendered as an empty bubble from nobody.
    if (text == null || sender == null || senderId is! String) return null;
    return TripMessage(
      id: id,
      senderId: senderId,
      sender: sender,
      text: text,
      sentAt: toDate(data['sentAt']),
    );
  }
}

/// How many messages from the other person arrived after [lastRead].
///
/// Used for the badge on the Message button. Messages with no timestamp yet
/// — written locally and not confirmed by the server — count as new, so a
/// message never slips past the badge while it is being sent.
int unreadFrom(List<TripMessage> messages, String? myUid, DateTime? lastRead) {
  var count = 0;
  for (final m in messages) {
    if (m.mine(myUid)) continue;
    final at = m.sentAt;
    if (lastRead == null || at == null || at.isAfter(lastRead)) count++;
  }
  return count;
}
