# Deprecation policy

Merchants integrate against a payment SDK once and expect it to keep working. When we need to change a public API, we mark the old one deprecated, give merchants time to migrate, then remove it in a major release. This document is the contract.

## The guarantee

| Stage          | What we do                                                                                                          | What merchants do                                                    |
| -------------- | ------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| **Deprecate**  | Mark the API with `@available(*, deprecated, message:)` pointing at its replacement. Document in the CHANGELOG.     | Build still succeeds. Xcode warning surfaces the replacement.        |
| **Notice**    | Deprecated APIs remain functional for **at least 12 months** after the release that introduced the deprecation.     | Plan and execute the migration at your own pace inside the window.   |
| **Remove**     | Remove the API in the next MAJOR release after the 12-month window has elapsed. Migration guide explains the move.  | Adopt the migration guide as part of upgrading to the new major.     |

12 months is the minimum. We may extend the window for a specific API if the migration path is non-trivial or if we know widely-used integrations depend on it.

## How a deprecation looks in code

```swift
@available(*, deprecated, message: "Use `MolliePaymentSheet.present(from:)` — see docs/migration/2.0.md")
public func presentPaymentSheet(viewController: UIViewController) {
    // existing implementation kept working
}
```

Three things must be present:

1. The `@available(*, deprecated, message:)` attribute.
2. A human-readable message that names the replacement and points at a migration target.
3. The original behaviour preserved until removal — a deprecated API that has already changed behaviour is a breaking change in disguise.

## CHANGELOG signal

Every deprecation appears under a `### Deprecated` heading in the [CHANGELOG](../../CHANGELOG.md) entry of the release that introduces it. The entry names:

- The deprecated symbol.
- The replacement.
- The earliest version in which the symbol may be removed (release date + 12 months).

Example:

```markdown
### Deprecated

- `MolliePaymentSheet.present(from:)` — use `MolliePaymentSheet.present(from:configuration:)`. Removable from 2027-06-01.
```

## What never deprecates

Some changes are bug fixes, not deprecations. We do not deprecate:

- Internal symbols (`internal`, `package`, `@_spi`).
- Bug-fix behaviour changes — if the documented contract said one thing and the code did another, we fix the code without notice.
- Server-side contract changes — those are governed by the Sessions Service and Tokeniser, not this SDK.

If you are relying on observable behaviour that the SDK does not document, treat it as undefined.

## Reporting a deprecation problem

If a deprecation message is unclear, if the replacement does not actually cover your use case, or if 12 months is not enough notice for your migration, file an issue. The notice window is a floor, not a ceiling — we extend it when the case is real.
