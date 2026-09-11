import 'package:flutter_test/flutter_test.dart';
import 'package:toda_equeue_plus/core/services/phone_actions.dart';

void main() {
  test('spaces, dashes and brackets are dropped', () {
    expect(dialableNumber('0981 384-8362'), '09813848362');
    expect(dialableNumber('(0981) 384 8362'), '09813848362');
  });

  test('an international number keeps its plus', () {
    expect(dialableNumber('+63 981 384 8362'), '+639813848362');
  });

  test('nothing dialable is null, not an empty call', () {
    expect(dialableNumber(null), isNull);
    expect(dialableNumber('   '), isNull);
    expect(dialableNumber('n/a'), isNull);
  });

  test('a clean number is left as it is', () {
    expect(dialableNumber('09813848362'), '09813848362');
  });
}
