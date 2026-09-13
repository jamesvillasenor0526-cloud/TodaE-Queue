/// Tests for trip messages: what may be sent, and what a thread shows.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:toda_equeue_plus/core/models/trip_message.dart';

DateTime? _date(dynamic v) => v is DateTime ? v : null;

TripMessage? parse(Map<String, dynamic> data) =>
    TripMessage.fromMap('m1', data, toDate: _date);

final now = DateTime(2026, 9, 13, 12, 0);

TripMessage message({
  String id = 'm',
  String senderId = 'them',
  MessageSender sender = MessageSender.passenger,
  String text = 'hello',
  DateTime? at,
}) => TripMessage(
  id: id,
  senderId: senderId,
  sender: sender,
  text: text,
  sentAt: at,
);

void main() {
  group('what may be sent', () {
    test('ordinary words are kept as they are', () {
      expect(cleanMessage("I'm outside the bakery"), "I'm outside the bakery");
      expect(worthSendingMessage('ok'), isTrue);
    });

    test('nothing but space is not a message', () {
      expect(cleanMessage('   '), isNull);
      expect(cleanMessage('\n\n\n'), isNull);
      expect(cleanMessage(null), isNull);
      expect(worthSendingMessage(''), isFalse);
      expect(worthSendingMessage('  \n '), isFalse);
    });

    test('runs of blank lines are collapsed, so one message stays one', () {
      // Otherwise a screenful of newlines pushes the conversation away.
      expect(cleanMessage('here\n\n\n\n\nnow'), 'here\n\nnow');
      expect(cleanMessage('two   spaces'), 'two spaces');
    });

    test('a very long message is cut, not refused', () {
      final long = cleanMessage('x' * 900);
      expect(long!.length, kMessageMaxLength);
    });

    test('line breaks a person typed on purpose survive', () {
      expect(
        cleanMessage('Aguinaldo St\ncorner Rizal'),
        'Aguinaldo St\ncorner Rizal',
      );
    });
  });

  group('reading a message back', () {
    test('carries who sent it and what they said', () {
      final m = parse({
        'senderId': 'driver-1',
        'senderRole': 'driver',
        'text': '  On my way  ',
        'sentAt': now,
      });
      expect(m!.sender, MessageSender.driver);
      expect(m.senderId, 'driver-1');
      expect(m.text, 'On my way');
      expect(m.sentAt, now);
    });

    test('a message with no words, sender or author is dropped', () {
      // Better nothing than an empty bubble from nobody.
      expect(
        parse({'senderId': 'a', 'senderRole': 'driver', 'text': '  '}),
        isNull,
      );
      expect(
        parse({'senderId': 'a', 'senderRole': 'ghost', 'text': 'hi'}),
        isNull,
      );
      expect(parse({'senderRole': 'driver', 'text': 'hi'}), isNull);
    });

    test('which side of the screen it belongs on', () {
      final mine = message(senderId: 'me');
      expect(mine.mine('me'), isTrue);
      expect(mine.mine('them'), isFalse);
      expect(mine.mine(null), isFalse, reason: 'signed out claims nothing');
    });
  });

  group('the unread badge', () {
    test('counts only what the other person sent', () {
      final count = unreadFrom(
        [
          message(id: 'a', senderId: 'me', at: now),
          message(id: 'b', senderId: 'them', at: now),
          message(id: 'c', senderId: 'them', at: now),
        ],
        'me',
        null,
      );
      expect(count, 2);
    });

    test('ignores what arrived before the thread was last opened', () {
      final opened = now;
      final count = unreadFrom(
        [
          message(
            id: 'old',
            senderId: 'them',
            at: opened.subtract(const Duration(minutes: 5)),
          ),
          message(
            id: 'new',
            senderId: 'them',
            at: opened.add(const Duration(minutes: 1)),
          ),
        ],
        'me',
        opened,
      );
      expect(count, 1);
    });

    test('a message still being sent counts, rather than slipping past', () {
      final count = unreadFrom(
        [message(id: 'pending', senderId: 'them')],
        'me',
        now,
      );
      expect(count, 1);
    });

    test('an empty thread has nothing waiting', () {
      expect(unreadFrom(const [], 'me', null), 0);
    });
  });

  group('what can be sent without typing', () {
    test('both sides have something to say', () {
      expect(kDriverQuickReplies, isNotEmpty);
      expect(kPassengerQuickReplies, isNotEmpty);
    });

    test('every quick reply is actually sendable', () {
      for (final line in [...kDriverQuickReplies, ...kPassengerQuickReplies]) {
        expect(worthSendingMessage(line), isTrue, reason: line);
        expect(
          cleanMessage(line),
          line,
          reason: '$line should need no tidying',
        );
      }
    });
  });
}
