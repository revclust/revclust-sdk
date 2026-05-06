import "dart:ffi";
import "dart:io";

import "package:sqlite3/open.dart";
import "package:sqflite/sqflite.dart" as sqflite;
import "package:sqflite_common_ffi/sqflite_ffi.dart";

bool _desktopSqfliteReady = false;
bool _linuxSqliteLoaderConfigured = false;

bool get isRevclustSupportedDesktopRuntime {
  return Platform.isLinux || Platform.isMacOS || Platform.isWindows;
}

sqflite.DatabaseFactory resolveRevclustDatabaseFactory() {
  if (!isRevclustSupportedDesktopRuntime) {
    return sqflite.databaseFactory;
  }
  _ensureRevclustDesktopSqfliteReady();
  return databaseFactoryFfiNoIsolate;
}

void _ensureRevclustDesktopSqfliteReady() {
  if (_desktopSqfliteReady) {
    return;
  }
  _configureLinuxSqliteLoader();
  sqfliteFfiInit();
  _desktopSqfliteReady = true;
}

void _configureLinuxSqliteLoader() {
  if (!Platform.isLinux || _linuxSqliteLoaderConfigured) {
    return;
  }

  final String? envPath =
      Platform.environment["REVCLUST_SQLITE_LIB_PATH"]?.trim();
  final List<String> candidates = <String>[
    if (envPath != null && envPath.isNotEmpty) envPath,
    "libsqlite3.so",
    "libsqlite3.so.0",
    "/usr/lib/libsqlite3.so",
    "/usr/lib64/libsqlite3.so",
    "/lib/libsqlite3.so",
    "/lib64/libsqlite3.so",
    "/usr/lib/x86_64-linux-gnu/libsqlite3.so.0",
    "/lib/x86_64-linux-gnu/libsqlite3.so.0",
    "/usr/lib/aarch64-linux-gnu/libsqlite3.so.0",
    "/lib/aarch64-linux-gnu/libsqlite3.so.0",
  ];

  for (final String candidate in candidates) {
    try {
      final DynamicLibrary library = DynamicLibrary.open(candidate);
      open.overrideFor(OperatingSystem.linux, () => library);
      _linuxSqliteLoaderConfigured = true;
      return;
    } on Object {
      // Probe the next candidate without failing runtime initialization here.
    }
  }
}
