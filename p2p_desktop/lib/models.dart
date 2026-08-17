/// 远程文件条目（来自电脑端 file-list-result）
class FileEntry {
  final String name;
  final String type; // 'file' | 'directory'
  final int? size;
  final String? path; // 完整路径：我的电脑模式为绝对路径，手动模式为相对共享目录路径

  const FileEntry(
      {required this.name, required this.type, this.size, this.path});

  factory FileEntry.fromJson(Map<String, dynamic> json) => FileEntry(
        name: json['name'] as String? ?? '',
        type: json['type'] as String? ?? 'file',
        size: json['size'] is int ? json['size'] as int : null,
        path: json['path']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type,
        if (size != null) 'size': size,
        if (path != null) 'path': path,
      };

  bool get isDirectory => type == 'directory';
}

/// 传输记录（下载 / 上传）
class TransferItem {
  final String id;
  final String fileName;
  final String direction; // 'download' | 'upload'
  final int total;
  int transferred;
  String status; // transferring | done | error
  String speed;
  final DateTime startTime;
  final String clientName; // 手机端用户名（多用户区分）
  final String clientId; // 手机端会话标识（断开/超时时精确标记失败记录）
  String connType; // 传输时连接方式快照：'direct' | 'relay' | 'probing' | ''（空=未知/旧数据）
  DateTime? endTime; // 完成/失败时间（进行中为 null）

  TransferItem({
    required this.id,
    required this.fileName,
    required this.direction,
    required this.total,
    required this.startTime,
    this.transferred = 0,
    this.status = 'transferring',
    this.speed = '',
    this.clientName = '',
    this.clientId = '',
    this.connType = '',
    this.endTime,
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

  /// 传输结束：设置终态并定格完成时间与连接方式（历史记录显示固定不再变）
  void finish(String status, {String? connType}) {
    this.status = status;
    endTime ??= DateTime.now();
    // 断线/无连接时的当前值可能为空，保留创建时快照不覆盖
    if (connType != null && connType.isNotEmpty) this.connType = connType;
  }

  /// 持久化到本地（程序重启后仍保留最近 7 天传输记录）
  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'direction': direction,
        'total': total,
        'transferred': transferred,
        'status': status,
        'speed': speed,
        'startTime': startTime.toIso8601String(),
        'clientName': clientName,
        'clientId': clientId,
        if (connType.isNotEmpty) 'connType': connType,
        if (endTime != null) 'endTime': endTime!.toIso8601String(),
      };

  factory TransferItem.fromJson(Map<String, dynamic> json) => TransferItem(
        id: json['id']?.toString() ?? '',
        fileName: json['fileName']?.toString() ?? '',
        direction:
            json['direction']?.toString() == 'upload' ? 'upload' : 'download',
        total: json['total'] is int ? json['total'] as int : 0,
        startTime: DateTime.tryParse(json['startTime']?.toString() ?? '') ??
            DateTime.now(),
        transferred:
            json['transferred'] is int ? json['transferred'] as int : 0,
        status: json['status']?.toString() ?? 'done',
        speed: json['speed']?.toString() ?? '',
        clientName: json['clientName']?.toString() ?? '',
        clientId: json['clientId']?.toString() ?? '',
        connType: json['connType']?.toString() ?? '',
        endTime: DateTime.tryParse(json['endTime']?.toString() ?? ''),
      );
}
