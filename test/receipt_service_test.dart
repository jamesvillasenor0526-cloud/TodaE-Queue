import 'package:flutter_test/flutter_test.dart';
import 'package:toda_equeue_plus/core/services/receipt_service.dart';

void main() {
  test('a receipt number carries the date paid and the trip', () {
    expect(
      ReceiptService.receiptNumberFor('8f3k2a9QwErTy', DateTime(2026, 9, 12)),
      'TODA-20260912-8F3K2A',
    );
  });

  test('asking twice for the same trip gives the same number', () {
    // What makes making a receipt safe to retry.
    final first = ReceiptService.receiptNumberFor('abc123xyz', DateTime(2026, 1, 5));
    final again = ReceiptService.receiptNumberFor('abc123xyz', DateTime(2026, 1, 5));
    expect(first, again);
    expect(first, 'TODA-20260105-ABC123');
  });

  test('different trips get different numbers', () {
    final a = ReceiptService.receiptNumberFor('aaaaaa1', DateTime(2026, 9, 12));
    final b = ReceiptService.receiptNumberFor('bbbbbb2', DateTime(2026, 9, 12));
    expect(a, isNot(b));
  });

  test('a short id is used as it is, not cut short', () {
    expect(
      ReceiptService.receiptNumberFor('ab1', DateTime(2026, 9, 12)),
      'TODA-20260912-AB1',
    );
  });
}
