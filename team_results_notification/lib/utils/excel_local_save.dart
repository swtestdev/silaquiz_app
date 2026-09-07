import 'excel_local_save_result.dart';
import 'excel_local_save_stub.dart'
    if (dart.library.js_interop) 'excel_local_save_web.dart' as impl;

export 'excel_local_save_result.dart';

Future<ExcelLocalSaveResult> saveExcelLocally(
  List<int> bytes,
  String filename,
) {
  return impl.saveExcelLocally(bytes, filename);
}
