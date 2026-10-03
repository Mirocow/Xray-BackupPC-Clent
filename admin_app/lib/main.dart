/// BackupPC Admin — Android-клиент управления сервером xray-backuppc.
///
/// Функциональность REST Admin API (docs/ADMIN-API.md): дашборд,
/// клиенты (CRUD + share-ссылки), сессии и история, фильтр/DNS, TLS,
/// журнал. Токен администратора хранится только на устройстве.
library;

import 'package:flutter/material.dart';

import 'ui.dart';
import 'state/app_state.dart';
import 'pages/login_page.dart';
import 'pages/home_page.dart';

void main() {
  runApp(const BackupPcAdminApp());
}

class BackupPcAdminApp extends StatelessWidget {
  const BackupPcAdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState();
    state.loadSaved();
    return MaterialApp(
      title: 'BackupPC Admin',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          secondary: kUp,
          surface: kCard,
          onPrimary: Colors.white,
          onSurface: kInk,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: kCard,
          foregroundColor: kInk,
          elevation: 0,
        ),
        cardTheme: const CardThemeData(
          color: kCard,
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
        tabBarTheme: const TabBarThemeData(
          labelColor: kInk,
          unselectedLabelColor: kDim,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: kCard,
          selectedItemColor: kAccent,
          unselectedItemColor: kDim,
          type: BottomNavigationBarType.fixed,
        ),
        dividerColor: const Color(0xFF21293B),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          fillColor: Color(0xFF0E1626),
          filled: true,
          hintStyle: TextStyle(color: kDim),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: kAccent,
          foregroundColor: Colors.white,
        ),
      ),
      home: ListenableBuilder(
        listening: state,
        builder: (context, _) =>
            state.api == null ? LoginPage(state) : HomePage(state),
      ),
    );
  }
}
