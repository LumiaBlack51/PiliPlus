/// Release tags use vMAJOR.MINOR.PATCH, optionally followed by +BUILD.
abstract final class ReleaseVersion {
  static List<int>? parse(String value) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$')
        .firstMatch(value);
    if (match == null) return null;
    return [for (var i = 1; i <= 4; i++) int.parse(match[i] ?? '0')];
  }

  static bool isNewer(String tag, String current, int currentBuild) {
    final remote = parse(tag);
    final local = parse(current);
    if (remote == null || local == null) return false;
    local[3] = currentBuild;
    for (var i = 0; i < 4; i++) {
      if (remote[i] != local[i]) return remote[i] > local[i];
    }
    return false;
  }
}
