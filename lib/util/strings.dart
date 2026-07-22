/// `time_frame` -> `Time Frame`. Used for both nav labels and screen titles
/// so a table only needs a `TableConfig`, never a separate display name.
String titleCase(String snakeCaseName) {
  return snakeCaseName
      .split('_')
      .map((word) => word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
}
