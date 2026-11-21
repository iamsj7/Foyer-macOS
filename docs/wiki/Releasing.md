# Releasing

Foyer releases itself from `main`.

## Branches

| Branch | Purpose |
|---|---|
| `dev` | Everyday work. CI builds every push. |
| `main` | Released code. Every push is checked for a new version and released automatically. |

Work on `dev` (or a feature branch with a pull request into `dev`). Merge `dev` into `main` when it's
ready to ship.

## Shipping a version

1. On `dev`, bump `version` in `Sources/Foyer/About.swift` (for example `0.2.0`) and add a
   `## [0.2.0] - YYYY-MM-DD` section to `CHANGELOG.md`.
2. Merge `dev` into `main` and push.
3. The **Release** workflow sees that `v0.2.0` doesn't exist yet. It builds `Foyer.app`, creates the
   `v0.2.0` tag, and publishes the GitHub Release with the zip, its SHA-256 and the changelog section.

Pushes to `main` that don't change the version don't release anything. If the build fails, nothing is
tagged or published. The workflow can also be run by hand from the Actions tab.

Users get the new version through **Foyer ▸ Check for Updates…** (or the automatic daily check).

## Building a release locally

```bash
scripts/package-app.sh            # dist/Foyer.app + dist/Foyer-<version>-macOS-arm64.zip
```

## Signing and notarization (optional)

Builds are ad-hoc signed by default. With an Apple Developer ID:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/package-app.sh
xcrun notarytool submit dist/Foyer-*.zip --keychain-profile <profile> --wait
xcrun stapler staple dist/Foyer.app
```

## Publishing the wiki

The pages in `docs/wiki/` mirror the GitHub wiki:

```bash
git clone https://github.com/iamsj7/Foyer-macOS.wiki.git /tmp/wiki
cp docs/wiki/*.md /tmp/wiki/ && cd /tmp/wiki && git add . && git commit -m "Update wiki" && git push
```
