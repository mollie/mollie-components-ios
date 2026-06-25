# Versioning policy

The Mollie iOS SDK follows [Semantic Versioning 2.0.0](https://semver.org/).

Every release carries a `MAJOR.MINOR.PATCH` version. The component that changes tells you what to expect.

## What the parts mean

| Bump  | When                                                                                  | Merchant impact                                      |
| ----- | ------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| MAJOR | A breaking change to the public API.                                                  | Source-incompatible. Plan an upgrade window.         |
| MINOR | A new public API, or new behaviour that is backwards-compatible.                      | Safe to adopt without code changes.                  |
| PATCH | A bug fix that does not change the public API or its observable contract.             | Safe to adopt without code changes.                  |

A pre-release suffix (`-beta.1`, `-rc.1`) may be attached to any of these.

## Public surface, defined

A change is **breaking** if it would force a recompile or a source change in a merchant app that uses only the SDK's public surface. The surface is enforced by the `PublicSurfaceTests` target. It covers:

- Any `public` or `open` symbol exported from `MollieCore`, `MolliePayments`, `MolliePaymentsUI`, or `MollieComponents`.
- The public model layer and its DocC-documented types.
- The minimum supported iOS version (currently iOS 16).
- The supported Swift toolchain.

Symbols marked `internal`, `package`, `@_spi`, `@_documentation(visibility: internal)`, or otherwise not part of the public surface are **not** covered by SemVer guarantees and may change in any release.

## What counts as a breaking change

Any of the following bumps the MAJOR version:

- Removing a public symbol.
- Renaming a public symbol.
- Changing the signature (parameters, return type, throws, async) of a public symbol.
- Changing a public type's storage in a way that breaks existing call sites.
- Tightening accepted input or loosening returned output beyond the documented contract.
- Removing a documented enum case.
- Raising the minimum supported iOS version.
- Raising the minimum supported Swift toolchain.

What does **not** count as breaking:

- Adding a new public type, method, or property.
- Adding a new enum case to a `@frozen`-not-marked enum that callers `default:` over.
- Internal refactors that do not change the public surface or observable behaviour.
- Adding new optional parameters with default values, when the surface tests confirm source compatibility.

## Pre-1.0 caveat

This SDK is currently at `0.0.1`. Under SemVer, anything below `1.0.0` may break in any release. Until we cut `1.0.0`, treat MINOR bumps as potentially source-incompatible.

`1.0.0` is the first version where the guarantees above bind us. Cutting `1.0.0` is a deliberate moment — see the production-readiness brief for sequencing.

## Migration guides

Every MAJOR version is accompanied by a migration guide under `docs/migration/`. The guide lists every breaking change, why it was made, and what to change in your integration. Pre-`1.0.0` there are no guides to publish; this section will fill in as majors are cut.

A minor version may publish a migration note if it deprecates an API (see [DEPRECATION.md](DEPRECATION.md)) — the note tells merchants how to move off the deprecation before it is removed.

## Release artefacts

Every release ships with:

- An annotated git tag matching the version (`1.2.3`).
- An entry in [CHANGELOG.md](../../CHANGELOG.md) under the matching version heading.
- The full source published to the public GitHub repository at that tag; Swift Package Manager resolves the tag directly.
- A migration guide under `docs/migration/` if the release contains breaking changes.
