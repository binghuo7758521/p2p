import 'package:flutter/material.dart';

import 'connect_page.dart';
import 'host_controller.dart';

void main() {
  runApp(const P2pDesktopApp());
}

class P2pDesktopApp extends StatelessWidget {
  const P2pDesktopApp({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = HostController();
    return MaterialApp(
      title: 'P2P 文件助手 - 电脑端',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF38BDF8),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      home: ConnectPage(controller: controller),
    );
  }
}
