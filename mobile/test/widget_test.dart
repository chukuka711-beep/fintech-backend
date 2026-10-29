import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/screens/screens.dart';

void main() {
  test('formats wallet balances from integer kobo', () {
    expect(formatNaira('10001'), '₦100.01');
    expect(formatNaira('0'), '₦0.00');
  });
}
