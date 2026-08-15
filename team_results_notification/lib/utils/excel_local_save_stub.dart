import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'excel_local_save_result.dart';

Future<ExcelLocalSaveResult> saveExcelLocally(
  List<int> bytes,
  String filename,
) async {
  final savedPath = await FilePicker.platform.saveFile(
    dialogTitle: 'Save Excel export',
    fileName: filename,
    bytes: Uint8List.fromList(bytes),
    type: FileType.custom,
    allowedExtensions: const ['xlsx'],
  );

  if (savedPath != null && savedPath.isNotEmpty) {
    return ExcelLocalSaveResult(
      success: true,
      cancelled: false,
      message: 'Saved locally:\n$savedPath',
    );
  }

  return const ExcelLocalSaveResult(
    success: false,
    cancelled: true,
    message: 'Local save cancelled (workbook was built successfully).',
  );
}
