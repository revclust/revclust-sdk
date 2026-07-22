# revclust_flutter

Flutter SDK for capturing structured incident evidence from Flutter apps.

Use it to capture app state, device context, and expected/observed values around
production incidents.

## Install

```yaml
dependencies:
  revclust_flutter: ^0.5.1
```

## Quick Start

Create an app in Revclust, copy its SDK key, then initialize the SDK.

```dart
import "package:flutter/widgets.dart";
import "package:revclust_flutter/revclust_flutter.dart";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final revclust = await Revclust.initialize(
    RevclustConfig(
      projectKey: const String.fromEnvironment("REVCLUST_PROJECT_KEY"),
    ),
  );

  runApp(MyApp(revclust: revclust));
}
```

Pass the SDK key at run or build time:

```bash
flutter run --dart-define=REVCLUST_PROJECT_KEY=rpk_...
```

## What Next

Follow the setup guide to add a state snapshot provider, capture your first
incident, and open it in Revclust.

[Read the docs](https://revclust.com/docs)

## Platforms

Revclust supports Flutter mobile apps on Android and iOS.

## License

This package is licensed under the MIT License. See [LICENSE](LICENSE).
