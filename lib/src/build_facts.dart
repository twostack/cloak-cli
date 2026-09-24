/// What the release build knows about this binary, and a development build
/// does not.
///
/// `dart build cli`, which a program depending on native assets must be built
/// with, takes no `--define`, so these are written into this file instead:
/// `tool/release/facts.dart` writes the release's values here just before a
/// release is built, and the build puts the committed file back afterwards.
/// As committed, it describes a development build, which is what `dart run`,
/// the suite and a person's own `dart build cli` are.
class BuildFacts {
  /// Whether this is a released build, which takes its native libraries from
  /// the bundle it was installed from and nowhere else.
  static const release = false;

  /// The `cloak-cli` commit a release was built from.
  static const commit = '';

  /// The version of each sibling library a release was built against, from
  /// `pubspec.lock`.
  static const libraries = <String, String>{};
}
