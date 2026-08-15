class ExcelLocalSaveResult {
  final bool success;
  final bool cancelled;
  final String message;

  const ExcelLocalSaveResult({
    required this.success,
    required this.cancelled,
    required this.message,
  });
}
