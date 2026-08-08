import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'auth_service.dart';
import 'connect_page.dart';
import 'login_page.dart';

void main() {
  runApp(const P2pApp());
}

class P2pApp extends StatelessWidget {
  const P2pApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'P2P 文件助手',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF38BDF8),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      home: const _AuthGate(),
    );
  }
}

/// 启动门禁：已登录直接进连接页，未登录先进登录页
class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  bool _loading = true;
  bool _loggedIn = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final ok = await AuthService.instance.load();
    if (!mounted) return;
    setState(() {
      _loggedIn = ok;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_loggedIn) {
      return ConnectPage(controller: AppController());
    }
    return const LoginPage();
  }
}
