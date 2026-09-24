import 'dart:convert';

/// What a command found, said once and printed in either form.
///
/// A command does not print. It adds facts here, each with the line a person
/// reads it as, and the shell prints the lines or the JSON object. The two
/// forms come from the same calls, so a number cannot reach one form and miss
/// the other: that is what "both forms carry the same facts" rests on, and it
/// is structural rather than a matter of keeping two printers in step.
class Report {
  final Map<String, Object?> _facts = {};
  final List<String> _lines = [];

  /// A fact under [key], shown to a person as [line]. [value] must be what
  /// `jsonEncode` takes: a number, a string, a bool, null, or a list or map of
  /// those. Numbers a person reads in [line] must be in [value].
  void add(String key, Object? value, String line) {
    _facts[key] = value;
    _lines.add(line);
  }

  /// A fact for a program that a person does not need a line for, because
  /// another line already says it.
  void quiet(String key, Object? value) => _facts[key] = value;

  /// A line that carries no fact: a heading, or advice. It must hold no
  /// number that is not also a fact, because the JSON form will not carry it.
  void say(String line) => _lines.add(line);

  Map<String, Object?> get facts => Map.unmodifiable(_facts);
  List<String> get lines => List.unmodifiable(_lines);

  /// The report as one JSON object, keys in the order they were added, so the
  /// same state prints the same bytes.
  String toJson() => jsonEncode(_facts);

  String toText() => _lines.isEmpty ? '' : '${_lines.join('\n')}\n';
}
