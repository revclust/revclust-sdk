# revclust_flutter_sdk

Flutter SDK for integrating a Flutter app with the Revclust hosted incident-capture service.

Revclust is a product of ASTROSCEND LIMITED.

## Install

Add the SDK from the Revclust Flutter SDK repository using a pinned git tag.

```yaml
dependencies:
  revclust_flutter_sdk:
    git:
      url: https://github.com/revclust/revclust-sdk.git
      ref: v0.4.3
```

Use the released tag provided by Revclust.

## Requirements

- Dart `>=3.3.0 <4.0.0`
- Flutter `>=3.19.0`

## Platform Scope

This SDK is for Flutter mobile apps on `iOS` and `Android`. Flutter web and
desktop runtimes are not part of the current support boundary.

## Supported Entrypoint

Use the supported SDK entrypoint:

```dart
import "package:revclust_flutter_sdk/revclust_flutter.dart";
```

This is the supported entrypoint for app integrations.

## Setup Docs

After adding the dependency, follow the Revclust setup docs for:

- SDK key configuration
- initialization and status checks
- state snapshot setup and the first explicit capture
- first incident verification and troubleshooting

## Release Policy

Revclust publishes supported releases as immutable git tags.

Pin your app to a specific tag. Use a commit only when Revclust explicitly provides one. Do not install from a moving branch head.

## License And Service Boundary

The Revclust Flutter SDK is open-source under the MIT License.

Hosted Revclust service access is governed by your Revclust account and the Revclust Terms.

## Support

For setup help, first-incident verification, and operational support, use the
Revclust docs and support.

This public repository publishes the SDK. External issue
reports and pull requests are not the normal support path unless Revclust has
explicitly invited them.
