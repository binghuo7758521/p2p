/// 远程文件条目（来自电脑端 file-list-result）
class FileEntry {
  final String name;
  final String type; // 'file' | 'directory'
  final int? size;
  final String? path; // 完整路径：我的电脑模式为绝对路径，手动模式为相对路径

  const FileEntry(
      {required this.name, required this.type, this.size, this.path});

  factory FileEntry.fromJson(Map<String, dynamic> json) => FileEntry(
        name: json['name'] as String? ?? '',
        type: json['type'] as String? ?? 'file',
        size: json['size'] is int ? json['size'] as int : null,
        path: json['path']?.toString(),
      );

  bool get isDirectory => type == 'directory';
}

/// 传输记录（下载 / 上传）
class TransferItem {
  final String id;
  final String fileName;
  final String direction; // 'download' | 'upload'
  int total; // 断线续传时源文件可能变化，允许更新
  int transferred;
  String status; // transferring | done | error
  String speed;
  final DateTime startTime;
  /// 上传：手机端本地文件路径（断点续传定位用）
  final String? localPath;
  /// 下载：电脑端文件路径（断点续传用）
  final String? remotePath;

  TransferItem({
    required this.id,
    required this.fileName,
    required this.direction,
    required this.total,
    required this.startTime,
    this.transferred = 0,
    this.status = 'transferring',
    this.speed = '',
    this.localPath,
    this.remotePath,
  });

  double get progress => total > 0 ? (transferred / total).clamp(0.0, 1.0) : 0.0;

  void update(int transferredBytes, int elapsedMs) {
    transferred = transferredBytes;
    if (elapsedMs > 0 && transferredBytes > 0) {
      final bps = transferredBytes * 1000 / elapsedMs;
      speed = bps >= 1024 * 1024
          ? '${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s'
          : '${(bps / 1024).toStringAsFixed(0)} KB/s';
    }
  }
}
