import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// U 盘（可移动磁盘）信息
class UsbDriveInfo {
  /// 盘符，如 "F"
  final String letter;

  /// 卷标，可能为空（无卷标）
  final String volumeLabel;

  /// 卷序列号，如 "1234-ABCD"（格式化后，每块 U 盘唯一）
  final String serial;

  const UsbDriveInfo({
    required this.letter,
    required this.volumeLabel,
    required this.serial,
  });

  @override
  String toString() =>
      '$letter: ${volumeLabel.isEmpty ? '(无卷标)' : volumeLabel} · ID: $serial';
}

/// DRIVE_REMOVABLE：可移动磁盘（U 盘）
const int _driveRemovable = 2;
/// MAX_PATH：卷标/文件系统名缓冲区长度
const int _maxPath = 260;

/// 枚举所有 U 盘（可移动磁盘）：盘符 + 卷标 + 卷序列号。
/// 非 Windows 平台返回空列表。
///
/// 注意：Dart 3.12 的 lookupFunction 已不再需要 NativeFunction 包装，
/// native 侧直接写 Uint32 Function(...) 形式（参数用 dart:ffi 原生类型），
/// Dart 侧标量映射为 int。
List<UsbDriveInfo> listUsbDrives() {
  final results = <UsbDriveInfo>[];
  if (!Platform.isWindows) return results;

  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getLogicalDrives = kernel32.lookupFunction<
      Uint32 Function(), int Function()>('GetLogicalDrives');
  final getDriveType = kernel32.lookupFunction<
      Uint32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)>('GetDriveTypeW');
  final getVolumeInfo = kernel32.lookupFunction<
      Uint32 Function(
        Pointer<Utf16>, // lpRootPathName
        Pointer<Utf16>, // lpVolumeNameBuffer
        Uint32, // nVolumeNameSize
        Pointer<Uint32>, // lpVolumeSerialNumber
        Pointer<Uint32>, // lpMaximumComponentLength
        Pointer<Uint32>, // lpFileSystemFlags
        Pointer<Utf16>, // lpFileSystemNameBuffer
        Uint32, // nFileSystemNameSize
      ),
      int Function(
        Pointer<Utf16>,
        Pointer<Utf16>,
        int,
        Pointer<Uint32>,
        Pointer<Uint32>,
        Pointer<Uint32>,
        Pointer<Utf16>,
        int,
      )>('GetVolumeInformationW');

  final mask = getLogicalDrives();
  for (var i = 0; i < 26; i++) {
    if ((mask & (1 << i)) == 0) continue; // 不存在的盘符
    final rootPtr = ('${String.fromCharCode(65 + i)}:\\').toNativeUtf16();
    try {
      // 只统计可移动磁盘（U 盘），排除本地磁盘/光驱/网络盘
      if (getDriveType(rootPtr) != _driveRemovable) continue;
      final volumeName = calloc<Uint16>(_maxPath);
      final serialPtr = calloc<Uint32>(1);
      final maxCompLen = calloc<Uint32>(1);
      final fsFlags = calloc<Uint32>(1);
      final fsName = calloc<Uint16>(_maxPath);
      try {
        final ok = getVolumeInfo(
          rootPtr,
          volumeName.cast<Utf16>(),
          _maxPath,
          serialPtr,
          maxCompLen,
          fsFlags,
          fsName.cast<Utf16>(),
          _maxPath,
        );
        if (ok != 0) {
          final label = volumeName.cast<Utf16>().toDartString();
          final serial = serialPtr.value;
          results.add(UsbDriveInfo(
            letter: String.fromCharCode(65 + i),
            volumeLabel: label,
            serial: _formatSerial(serial),
          ));
        }
      } finally {
        calloc.free(volumeName);
        calloc.free(serialPtr);
        calloc.free(maxCompLen);
        calloc.free(fsFlags);
        calloc.free(fsName);
      }
    } finally {
      malloc.free(rootPtr);
    }
  }
  return results;
}

/// 卷序列号格式化为 Windows 风格的 "XXXX-XXXX"（高位字-低位字）
String _formatSerial(int serial) {
  final hi = ((serial >> 16) & 0xFFFF)
      .toRadixString(16)
      .toUpperCase()
      .padLeft(4, '0');
  final lo = (serial & 0xFFFF).toRadixString(16).toUpperCase().padLeft(4, '0');
  return '$hi-$lo';
}
