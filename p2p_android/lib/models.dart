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

/// 共享目录（管理员共享给用户的文件夹）
class ShareEntry {
  final String token; // 共享码
  final String folder; // 电脑端文件夹绝对路径
  final List<String> perms; // download / upload / delete
  final String? targetDeviceId; // 目标设备 id（null=未绑定/公开）
  final String? targetPhone; // 目标手机号（null=未指定/公开）
  final String remark; // 备注名称（v5.21+：电脑端管理员填写，展示优先于文件夹名）

  const ShareEntry({
    required this.token,
    required this.folder,
    required this.perms,
    this.targetDeviceId,
    this.targetPhone,
    this.remark = '',
  });

  factory ShareEntry.fromJson(Map<String, dynamic> json) => ShareEntry(
        token: json['token']?.toString() ?? '',
        folder: json['folder']?.toString() ?? '',
        perms: (json['perms'] as List? ?? [])
            .map((e) => e.toString())
            .toList(),
        targetDeviceId: json['targetDeviceId']?.toString(),
        targetPhone: json['targetPhone']?.toString(),
        remark: json['remark']?.toString() ?? '',
      );

  /// 展示名称：备注优先，其次文件夹末段（不显示全路径）
  String get name => remark.isNotEmpty ? remark : folder.split('/').last;
  bool get canDownload => perms.contains('download');
  bool get canUpload => perms.contains('upload');
  bool get canDelete => perms.contains('delete');

  /// 公开共享（二维码）：未指定目标设备与手机号
  bool get isPublic => targetDeviceId == null && targetPhone == null;
}

/// 服务器共享条目（v4.8+：“共享给我的”列表，登录后免配对码可见）
/// 数据源：GET /api/shares/mine（电脑端同步到服务器，不暴露本地路径）
class ServerShare {
  final String token; // 共享码（连接凭证）
  final String hostName; // 共享所在电脑的备注名
  final String name; // 共享文件夹名
  final List<String> perms; // download / upload / delete
  final bool online; // 电脑端是否在线

  const ServerShare({
    required this.token,
    required this.hostName,
    required this.name,
    required this.perms,
    required this.online,
  });

  factory ServerShare.fromJson(Map<String, dynamic> json) => ServerShare(
        token: json['token']?.toString() ?? '',
        hostName: json['hostName']?.toString() ?? '电脑',
        name: json['name']?.toString() ?? '共享文件夹',
        perms: (json['perms'] as List? ?? [])
            .map((e) => e.toString())
            .toList(),
        online: json['online'] == true,
      );

  bool get canDownload => perms.contains('download');
  bool get canUpload => perms.contains('upload');
  bool get canDelete => perms.contains('delete');
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
  /// 传输时的连接方式快照：direct=点对点直连 relay=服务器中转 unknown=未探测
  /// （显示在传输记录上的是本次传输实际使用的方式，而非当前连接状态）
  String connType;
  /// 上传：手机端本地文件路径（断点续传定位用）
  final String? localPath;
  /// 下载：电脑端文件路径（断点续传用）
  final String? remotePath;
  /// 传输对象电脑端名称（创建时快照，v5.37+；旧数据为空）
  final String peerName;
  /// 完成/失败时间（进行中为 null，v5.37+；旧数据为空）
  DateTime? endTime;

  TransferItem({
    required this.id,
    required this.fileName,
    required this.direction,
    required this.total,
    required this.startTime,
    this.transferred = 0,
    this.status = 'transferring',
    this.speed = '',
    this.connType = 'unknown',
    this.localPath,
    this.remotePath,
    this.peerName = '',
    this.endTime,
  });

  double get progress => total > 0 ? (transferred / total).clamp(0.0, 1.0) : 0.0;

  /// 持久化到本地（App 重启后仍保留最近 7 天传输记录）
  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'direction': direction,
        'total': total,
        'transferred': transferred,
        'status': status,
        'speed': speed,
        'startTime': startTime.toIso8601String(),
        'connType': connType,
        if (localPath != null) 'localPath': localPath,
        if (remotePath != null) 'remotePath': remotePath,
        if (peerName.isNotEmpty) 'peerName': peerName,
        if (endTime != null) 'endTime': endTime!.toIso8601String(),
      };

  factory TransferItem.fromJson(Map<String, dynamic> j) => TransferItem(
        id: j['id']?.toString() ?? '',
        fileName: j['fileName']?.toString() ?? '',
        direction: j['direction']?.toString() ?? 'download',
        total: (j['total'] as num?)?.toInt() ?? 0,
        transferred: (j['transferred'] as num?)?.toInt() ?? 0,
        status: j['status']?.toString() ?? 'error',
        speed: j['speed']?.toString() ?? '',
        startTime: DateTime.tryParse(j['startTime']?.toString() ?? '') ??
            DateTime.now(),
        connType: j['connType']?.toString() ?? 'unknown',
        localPath: j['localPath']?.toString(),
        remotePath: j['remotePath']?.toString(),
        peerName: j['peerName']?.toString() ?? '',
        endTime: DateTime.tryParse(j['endTime']?.toString() ?? ''),
      );

  void update(int transferredBytes, int elapsedMs) {
    transferred = transferredBytes;
    if (elapsedMs > 0 && transferredBytes > 0) {
      final bps = transferredBytes * 1000 / elapsedMs;
      speed = bps >= 1024 * 1024
          ? '${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s'
          : '${(bps / 1024).toStringAsFixed(0)} KB/s';
    }
  }

  /// 传输结束（v5.37+）：设置终态并定格完成时间（历史记录显示固定不再变）
  void finish(String status) {
    this.status = status;
    endTime ??= DateTime.now();
  }
}
