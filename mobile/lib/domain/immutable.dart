/// Copies JSON-compatible values so a caller cannot mutate a saved snapshot.
Object? immutableValue(Object? value) => switch (value) {
  Map value => Map<String, Object?>.unmodifiable(
    value.map((key, item) => MapEntry(key as String, immutableValue(item))),
  ),
  List value => List<Object?>.unmodifiable(value.map(immutableValue)),
  _ => value,
};

Map<String, Object?> immutableMap(Map<String, Object?> value) =>
    immutableValue(value) as Map<String, Object?>;
