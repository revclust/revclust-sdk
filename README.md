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
      ref: v0.4.0
```

Use the released tag provided by Revclust.

## Requirements

- Dart `>=3.3.0 <4.0.0`
- Flutter `>=3.19.0`

## Platform Scope

This SDK is for Flutter apps. The current managed setup supports Flutter
mobile apps on `iOS` and `Android` only. Flutter web and desktop runtimes are
not part of the current support boundary.

## Supported Entrypoint

Use the supported SDK entrypoint:

```dart
import "package:revclust_flutter_sdk/revclust_flutter.dart";
```

This is the supported entrypoint for app integrations.

## Setup Docs

After adding the dependency, follow the Revclust setup docs for:

- project key configuration
- initialization and status checks
- state snapshot setup and the first explicit capture
- first incident verification and troubleshooting

## Release Policy

Revclust publishes supported releases as immutable git tags.

Pin your app to a specific tag. Use a commit only when Revclust explicitly provides one. Do not install from a moving branch head.

## License And Service Boundary

This SDK is source-available under the Revclust SDK License. It is not open source.

The SDK license covers the SDK source code only. Access to the hosted Revclust service, app access, setup docs, and support is provisioned for your team by Revclust.

## Support

For setup help, first-incident verification, and operational support, use the
setup docs and support channel provided by Revclust.

This public repository publishes the SDK. External issue
reports and pull requests are not the normal support path unless Revclust has
explicitly invited them.
