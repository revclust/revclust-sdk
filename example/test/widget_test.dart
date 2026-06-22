import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:revclust_flutter_sdk_example/main.dart";

void main() {
  testWidgets("quickstart app explains missing build-time config", (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const RevclustQuickstartApp());

    expect(find.text("Revclust Hosted Quickstart"), findsOneWidget);
    expect(
      find.text(
        "Provide REVCLUST_PROJECT_KEY via --dart-define to enable the quickstart flow.",
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, "Initialize SDK"), findsOne);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, "Initialize SDK"),
          )
          .onPressed,
      isNull,
    );
    expect(
      find.widgetWithText(OutlinedButton, "Queue Sample Incident"),
      findsOne,
    );
    expect(find.text("SDK status"), findsOneWidget);
    expect(find.text("Current status: disabled"), findsOneWidget);
  });
}
