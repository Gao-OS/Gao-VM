String formatPersistenceTimestamp(DateTime value) {
  final utc = value.toUtc();
  final fraction = utc.millisecond * 1000 + utc.microsecond;
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}T'
      '${utc.hour.toString().padLeft(2, '0')}:'
      '${utc.minute.toString().padLeft(2, '0')}:'
      '${utc.second.toString().padLeft(2, '0')}.'
      '${fraction.toString().padLeft(6, '0')}Z';
}
