# Releasing

1. Update `version` in `Sources/Foyer/About.swift` and add a section to `CHANGELOG.md`.
2. Commit, then tag and push:
   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```
3. The **Release** workflow builds `Foyer.app`, zips it, and publishes a GitHub Release with the
   zip, its SHA-256 and the changelog section.

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

The pages in `docs/wiki/` mirror the GitHub wiki. After enabling the wiki on GitHub:

```bash
git clone https://github.com/iamsj7/Foyer-macOS.wiki.git /tmp/wiki
cp docs/wiki/*.md /tmp/wiki/ && cd /tmp/wiki && git add . && git commit -m "Update wiki" && git push
```
