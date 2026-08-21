import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Windows Known Folder（特殊文件夹）真实路径解析。
///
/// 用途：「我的电脑」虚拟根中的桌面/文档/下载等条目必须使用系统实际路径，
/// 否则 OneDrive 备份、手动文件夹重定向等场景下会指向空壳目录
/// （如 C:\Users\xxx\Desktop 已被搬空，真实文件在重定向目标）。
/// 非 Windows 或 API 调用失败时返回空 Map，调用方回退 USERPROFILE 硬拼。
final class _GUID extends Struct {
  @Uint32()
  external int data1;

  @Uint16()
  external int data2;

  @Uint16()
  external int data3;

  @Array(8)
  external Array<Uint8> data4;
}

/// 特殊文件夹 key → FOLDERID GUID 字节（小端序，Data1 低字节在前）
const Map<String, List<int>> _folderGuids = {
  'desktop': [
    0x3A, 0xCC, 0xBF, 0xB4, 0x2C, 0xDB, 0x4C, 0x42, //
    0xB0, 0x29, 0x7F, 0xE9, 0x9A, 0x87, 0xC6, 0x41,
  ], // {B4BFCC3A-DB2C-424C-B029-7FE99A87C641}
  'documents': [
    0xD0, 0x9A, 0xD3, 0xFD, 0x8F, 0x23, 0xAF, 0x46, //
    0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7,
  ], // {FDD39AD0-238F-46AF-ADB4-6C85480369C7}
  'downloads': [
    0x90, 0xE2, 0x4D, 0x37, 0x3F, 0x12, 0x65, 0x45, //
    0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B,
  ], // {374DE290-123F-4565-9164-39C4925E467B}
  'pictures': [
    0x30, 0x81, 0xE2, 0x33, 0x1E, 0x4E, 0x76, 0x46, //
    0x83, 0x5A, 0x98, 0x39, 0x5C, 0x3B, 0xC3, 0xBB,
  ], // {33E28130-4E1E-4676-835A-98395C3BC3BB}
  'videos': [
    0x1D, 0x9B, 0x98, 0x18, 0xB5, 0x99, 0x5B, 0x45, //
    0x84, 0x1C, 0xAB, 0x7C, 0x74, 0xE4, 0xDD, 0xFC,
  ], // {18989B1D-99B5-455B-841C-AB7C74E4DDFC}
  'music': [
    0x71, 0xD5, 0xD8, 0x4B, 0x19, 0x6D, 0xD3, 0x48, //
    0xBE, 0x97, 0x42, 0x22, 0x20, 0x08, 0x0E, 0x43,
  ], // {4BD8D571-6D19-48D3-BE97-422220080E43}
};

/// 解析全部特殊文件夹真实路径（识别 OneDrive/文件夹重定向）。
/// 返回 key → 绝对路径（Windows 反斜杠风格）；失败项不包含在结果中。
/// 调用方应回退 USERPROFILE 硬拼路径。
Map<String, String> resolveKnownFolders() {
  final result = <String, String>{};
  if (!Platform.isWindows) return result;

  final shell32 = DynamicLibrary.open('shell32.dll');
  final getKnownFolderPath = shell32.lookupFunction<
      Int32 Function(
          Pointer<_GUID>, Uint32, Pointer<Void>, Pointer<Pointer<Utf16>>),
      int Function(
          Pointer<_GUID>, int, Pointer<Void>, Pointer<Pointer<Utf16>>)>(
      'SHGetKnownFolderPath');
  final ole32 = DynamicLibrary.open('ole32.dll');
  final coTaskMemFree = ole32.lookupFunction<Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('CoTaskMemFree');

  for (final e in _folderGuids.entries) {
    final guid = calloc<_GUID>(1);
    final out = calloc<Pointer<Utf16>>(1);
    try {
      // GUID 按字节写入（小端布局由结构体定义保证）
      final bytes = Uint8List.fromList(e.value);
      for (var i = 0; i < 16; i++) {
        guid.cast<Uint8>()[i] = bytes[i];
      }
      // dwFlags=0, hToken=nullptr（当前用户），输出需 CoTaskMemFree 释放
      final hr = getKnownFolderPath(guid, 0, nullptr, out);
      if (hr == 0 /* S_OK */ && out.value != nullptr) {
        final path = out.value.toDartString();
        if (path.isNotEmpty) result[e.key] = path;
      }
    } finally {
      if (out.value != nullptr) coTaskMemFree(out.value.cast());
      calloc.free(out);
      calloc.free(guid);
    }
  }
  return result;
}
