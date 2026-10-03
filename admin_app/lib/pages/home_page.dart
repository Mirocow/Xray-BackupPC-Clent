/// Каркас приложения: нижняя навигация по разделам.
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'dashboard_page.dart';
import 'clients_page.dart';
import 'sessions_page.dart';
import 'filter_page.dart';
import 'more_page.dart';

class HomePage extends StatefulWidget {
  final AppState state;
  const HomePage(this.state, {super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final pages = [
      DashboardPage(state),
      ClientsPage(state),
      SessionsPage(state),
      FilterPage(state),
      MorePage(state),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('BackupPC Admin'),
        actions: [
          ListenableBuilder(
            listening: state,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  state.loginInfo?.version ?? '',
                  style: const TextStyle(color: _dimTag, fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tab,
        onTap: (i) => setState(() => _tab = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard_outlined),
            activeIcon: Icon(Icons.dashboard),
            label: 'Дашборд',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.group_outlined),
            activeIcon: Icon(Icons.group),
            label: 'Клиенты',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.swap_vert_outlined),
            activeIcon: Icon(Icons.swap_vert),
            label: 'Сессии',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.shield_outlined),
            activeIcon: Icon(Icons.shield),
            label: 'Фильтр',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.more_horiz),
            activeIcon: Icon(Icons.more_horiz),
            label: 'Ещё',
          ),
        ],
      ),
    );
  }
}

const _dimTag = Color(0xFF8B98A9);
