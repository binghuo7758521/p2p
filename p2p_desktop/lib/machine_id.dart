import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';

/// 本机唯一硬件标识。
///
/// 用途：服务器按设备分配配对码——同一台电脑配对码稳定（重装/重启不变），
/// 不同电脑互不相同（修复 v2.1 之前所有电脑端共用服务器全局配对码的问题）。
///
/// Windows 下读取注册表 MachineGuid（HKLM\SOFTWARE\Microsoft\Cryptography），
/// 该 GUID 每台机器唯一；读取失败或非 Windows 平台时降级为随机 ID 并持久化
/// 到用户目录（重装前保持稳定）。
class MachineId {
  MachineId._();

  static String? _cached;

  static String get() {
    if (_cached != null) return _cached!;
    _cached = _readWindowsMachineGuid() ?? _fallbackPersisted();
    return _cached!;
  }

  /// 读取 Windows MachineGuid（进程内只读一次）
  static String? _readWindowsMachineGuid() {
    if (!Platform.isWindows) return null;
    try {
      final advapi32 = DynamicLibrary.open('advapi32.dll');
      // Dart 3.12：lookupFunction 无需 NativeFunction 包装，native 侧直接写
      // dart:ffi 原生类型，Dart 侧标量映射为 int
      final regOpenKey = advapi32.lookupFunction<
          Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<IntPtr>),
          int Function(int, Pointer<Utf16>, int, int,
              Pointer<IntPtr>)>('RegOpenKeyExW');
      final regQueryValue = advapi32.lookupFunction<
          Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Uint32>,
              Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>),
          int Function(int, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
              Pointer<Uint8>, Pointer<Uint32>)>('RegQueryValueExW');
      final regCloseKey =
          advapi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
              'RegCloseKey');

      const hklm = 0x80000002; // HKEY_LOCAL_MACHINE
      const keyRead = 0x00020019; // KEY_READ
      final hKey = calloc<IntPtr>(1);
      try {
        final subKey =
            r'SOFTWARE\Microsoft\Cryptography'.toNativeUtf16();
        try {
          // 打开 Cryptography 键失败（理论不会）：直接降级
          if (regOpenKey(hklm, subKey, 0, keyRead, hKey) != 0) return null;
        } finally {
          malloc.free(subKey);
        }
        final valueName = 'MachineGuid'.toNativeUtf16();
        final sizePtr = calloc<Uint32>(1);
        final typePtr = calloc<Uint32>(1);
        try {
          // 先查询值大小（lpData 传 nullptr）
          final r1 = regQueryValue(
              hKey.value, valueName, nullptr, typePtr, nullptr, sizePtr);
          if (r1 != 0 || sizePtr.value == 0) return null;
          final buf = calloc<Uint8>(sizePtr.value);
          try {
            final r2 = regQueryValue(
                hKey.value, valueName, nullptr, typePtr, buf, sizePtr);
            if (r2 != 0) return null;
            // MachineGuid 为 REG_SZ（UTF-16LE，含结尾 \0）
            final guid = buf.cast<Utf16>().toDartString();
            return guid.isEmpty ? null : guid;
          } finally {
            calloc.free(buf);
          }
        } finally {
          malloc.free(valueName);
          calloc.free(sizePtr);
          calloc.free(typePtr);
        }
      } finally {
        regCloseKey(hKey.value);
        calloc.free(hKey);
      }
    } catch (e) {
      return null;
    }
  }

  /// 降级：随机 ID 持久化到用户目录（读取失败/非 Windows 时保证设备标识稳定）
  static String _fallbackPersisted() {
    try {
      final base = Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.systemTemp.path;
      final dir = Directory('$base/p2p_desktop');
      dir.createSync(recursive: true);
      final f = File('${dir.path}/machine_id');
      if (f.existsSync()) {
        final saved = f.readAsStringSync().trim();
        if (saved.isNotEmpty) return saved;
      }
      final r = Random();
      final id = 'M${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
          '${r.nextInt(0xFFFFFF).toRadixString(36)}';
      f.writeAsStringSync(id);
      return id;
    } catch (_) {
      // 极端兜底：仅影响配对码稳定性，不崩溃
      return 'H-${Platform.localHostname}';
    }
  }
}
