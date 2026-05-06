/// Typed, schema-aligned update-context snapshot captured during SDK init.
class UpdateContextSnapshot {
  UpdateContextSnapshot({
    required this.isFirstRunAfterUpdate,
    required this.prevAppVersion,
    required String installType,
  }) : installType = _validateInstallType(installType);

  static const String installTypeFreshInstall = "fresh_install";
  static const String installTypeUpdate = "update";
  static const String installTypeUnknown = "unknown";

  static const Set<String> allowedInstallTypes = <String>{
    installTypeFreshInstall,
    installTypeUpdate,
    installTypeUnknown,
  };

  final bool isFirstRunAfterUpdate;
  final String? prevAppVersion;
  final String installType;

  static String _validateInstallType(String value) {
    if (!allowedInstallTypes.contains(value)) {
      throw ArgumentError.value(
        value,
        "installType",
        "must be one of: ${allowedInstallTypes.join("|")}",
      );
    }
    return value;
  }

  static final UpdateContextSnapshot unknown = UpdateContextSnapshot(
    isFirstRunAfterUpdate: false,
    prevAppVersion: null,
    installType: installTypeUnknown,
  );

  static final UpdateContextSnapshot freshInstall = UpdateContextSnapshot(
    isFirstRunAfterUpdate: false,
    prevAppVersion: null,
    installType: installTypeFreshInstall,
  );

  factory UpdateContextSnapshot.update({required String prevAppVersion}) {
    final String normalizedPrevVersion = prevAppVersion.trim();
    if (normalizedPrevVersion.isEmpty) {
      throw ArgumentError.value(
        prevAppVersion,
        "prevAppVersion",
        "must not be empty",
      );
    }
    return UpdateContextSnapshot(
      isFirstRunAfterUpdate: true,
      prevAppVersion: normalizedPrevVersion,
      installType: installTypeUpdate,
    );
  }

  @override
  int get hashCode => Object.hash(
        isFirstRunAfterUpdate,
        prevAppVersion,
        installType,
      );

  @override
  bool operator ==(Object other) {
    return other is UpdateContextSnapshot &&
        other.isFirstRunAfterUpdate == isFirstRunAfterUpdate &&
        other.prevAppVersion == prevAppVersion &&
        other.installType == installType;
  }
}
