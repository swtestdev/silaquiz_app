import 'dart:html' as html;
import 'dart:typed_data';

import 'excel_local_save_result.dart';

Future<ExcelLocalSaveResult> saveExcelLocally(
  List<int> bytes,
  String filename,
) async {
  final blob = html.Blob(
    [Uint8List.fromList(bytes)],
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  );
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = filename
    ..style.display = 'none';

  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);

  return ExcelLocalSaveResult(
    success: true,
    cancelled: false,
    message:
        'Download started: $filename\n'
        'Check your browser Downloads folder (phone: Files/Downloads, desktop: Ctrl+J).',
  );
}
