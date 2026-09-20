/// Where a ticket stands, as the app reads it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:toda_equeue_plus/core/services/ticket_service.dart';

void main() {
  test('a ticket says who it is waiting on', () {
    expect(TicketState.of({'status': 'open'}), TicketState.open);
    expect(TicketState.of({'status': 'answered'}), TicketState.answered);
    expect(TicketState.of({'status': 'resolved'}), TicketState.resolved);
  });

  test('a ticket with no status is waiting for a reply', () {
    // Tickets sent before there was anything to answer them with.
    expect(TicketState.of(const {}), TicketState.open);
    expect(TicketState.of(null), TicketState.open);
    expect(TicketState.of({'status': 'nonsense'}), TicketState.open);
  });

  test('each state says something a person can read', () {
    expect(TicketState.open.label, 'Waiting for a reply');
    expect(TicketState.answered.label, 'Answered');
    expect(TicketState.resolved.label, 'Resolved');
  });
}
