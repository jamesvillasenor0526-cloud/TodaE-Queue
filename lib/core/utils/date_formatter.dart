class DateFormatter {
  static String formatDate(DateTime? date) {
    if (date == null) return '';

    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  static String formatTime(DateTime? date) {
    if (date == null) return '';

    final hour = date.hour > 12 ? date.hour - 12 : date.hour;
    final minute = date.minute.toString().padLeft(2, '0');
    final period = date.hour >= 12 ? 'PM' : 'AM';

    return '$hour:$minute $period';
  }

  static String formatDateTime(DateTime? date) {
    if (date == null) return '';
    return '${formatDate(date)} at ${formatTime(date)}';
  }
}
