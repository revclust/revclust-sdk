import "package:flutter_test/flutter_test.dart";
import "package:revclust_flutter/src/network/path_sanitizer.dart";

void main() {
  test("strips query params and fragments", () {
    expect(
      sanitizeNetworkPath("/users/123?expand=cart#section"),
      "/users/{id}",
    );
    expect(
      sanitizeNetworkPath("https://api.example.com/orders/456?foo=bar#frag"),
      "/orders/{id}",
    );
  });

  test("replaces integer, UUID-like, and long hex segments with {id}", () {
    final String input =
        "/orders/123/items/550e8400-e29b-41d4-a716-446655440000/"
        "tokens/abcdef1234567890abcdef1234567890";
    expect(
      sanitizeNetworkPath(input),
      "/orders/{id}/items/{id}/tokens/{id}",
    );
  });

  test("replaces percent-encoded URL components that could leak secrets", () {
    expect(
      sanitizeNetworkPath(
        "/reset/abc%3Ftoken%3Dmarker%26email%3Dperson@example.invalid",
      ),
      "/reset/{id}",
    );
    expect(
      sanitizeNetworkPath(
        "/proxy/https%3A%2F%2Finternal.example.invalid%2Forders%2F123%3Fauth%3Dmarker",
      ),
      "/proxy/{id}",
    );
    expect(
      sanitizeNetworkPath("/profiles/user%40example.com"),
      "/profiles/{id}",
    );
  });

  test("does not over-sanitize normal semantic segments", () {
    expect(
      sanitizeNetworkPath("/v1/orders/latest/by-customer"),
      "/v1/orders/latest/by-customer",
    );
    expect(
      sanitizeNetworkPath("orders/detail/abc123xyz"),
      "orders/detail/abc123xyz",
    );
  });

  test("keeps leading slash semantics and normalizes empty URL path", () {
    expect(sanitizeNetworkPath("users/123"), "users/{id}");
    expect(sanitizeNetworkPath("/users/123"), "/users/{id}");
    expect(sanitizeNetworkPath("https://api.example.com?x=1"), "/");
  });
}
