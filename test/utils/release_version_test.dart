import 'package:PiliPlus/utils/release_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compares numeric versions and build numbers without downgrades', () {
    expect(ReleaseVersion.isNewer('v2.1.6', '2.1.5', 2), isTrue);
    expect(ReleaseVersion.isNewer('v2.1.10', '2.1.9', 20), isTrue);
    expect(ReleaseVersion.isNewer('v2.1.5+3', '2.1.5', 2), isTrue);
    expect(ReleaseVersion.isNewer('v2.1.5+2', '2.1.5', 2), isFalse);
    expect(ReleaseVersion.isNewer('v2.1.5', '2.1.5', 2), isFalse);
    expect(ReleaseVersion.isNewer('v2.1.4+99', '2.1.5', 2), isFalse);
    expect(ReleaseVersion.isNewer('v2.1.6-beta.1', '2.1.5', 2), isFalse);
    expect(ReleaseVersion.isNewer('invalid', '2.1.5', 2), isFalse);
  });
}
