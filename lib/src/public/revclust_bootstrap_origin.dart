import "revclust_config.dart";

final Uri _canonicalBootstrapOrigin = Uri.parse("https://revclust.com");

Uri resolveInternalRevclustBootstrapOrigin(RevclustConfig config) {
  return config.debugOptions.bootstrapOriginOverride ??
      _canonicalBootstrapOrigin;
}
