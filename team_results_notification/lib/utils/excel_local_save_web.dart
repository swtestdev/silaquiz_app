import 'excel_local_save_result.dart';
import 'browser/browser.dart';

Future<ExcelLocalSaveResult> saveExcelLocally(
  List<int> bytes,
  String filename,
) async {
  await downloadBytesAsFile(bytes, filename);

  return ExcelLocalSaveResult(
    success: true,
    cancelled: false,
    message:
        'Download started: $filename\n'
        'Check your browser Downloads folder (phone: Files/Downloads, desktop: Ctrl+J).',
  );
}
