# downloads/

Staging area for the five release artifacts linked from the **Get Geonix Wrench**
section of `geonix_website/geonix_wrench.html` (`#download`).

Nothing here is committed — see `.gitignore`. Binaries live on the GitHub
Release, not in the repo. This folder is where you build them, check them, and
upload them from.

Current app version: **1.0.0+1** (`geonix_wrench_app/pubspec.yaml`)

## Naming convention

Keep it identical across platforms so the site links stay predictable:

```
geonix-wrench-<version>-<platform>.<ext>
```

| Slot            | File                                | Website row       |
|-----------------|-------------------------------------|-------------------|
| `ios/`          | (App Store — no file)               | iPhone & iPad     |
| `android/`      | `geonix-wrench-1.0.0-android.apk`   | Android           |
| `macos/`        | `geonix-wrench-1.0.0-macos.dmg`     | macOS             |
| `windows/`      | `geonix-wrench-1.0.0-windows.exe`   | Windows           |
| `linux/`        | `geonix-wrench-1.0.0-linux.deb`     | Linux             |

iOS and Android ship through the App Store and Google Play, so those two rows
point at store pages rather than files. The `android/` folder still holds the
`.aab` you upload to Play, plus a sideloadable `.apk` if you want one for shop
testing.

## How the desktop builds are produced

`.github/workflows/release.yml` builds all three on their native runners and
attaches them to a **draft** GitHub Release on `geonixsoftware/geonix` — the
public website repo, so the download URLs work without a token even if the app
source repo is private.

```bash
git tag v1.0.0 && git push origin v1.0.0     # or run the workflow manually
```

Then: install each artifact on a clean machine, and press **Publish release**.
The site's three desktop links point at those exact URLs, so they stay dead
until you publish — that gate is deliberate.

Two things the workflow needs before it can run:

- The repo holding `geonix_wrench_app/` must be on GitHub. It currently has no
  remote, so nothing triggers.
- A `RELEASE_TOKEN` secret: a PAT with `contents: write` on
  `geonixsoftware/geonix`. The built-in `GITHUB_TOKEN` cannot write to another
  repository, so cross-repo publishing fails without it.

Packaging inputs live beside the platform they belong to:
`windows/installer.iss` (Inno Setup) and `linux/com.geonixsoftware.wrench.desktop`.

## Building each artifact by hand

Run from `geonix_wrench_app/`.

**macOS** (needs macOS + Xcode)
```bash
flutter build macos --release
# build/macos/Build/Products/Release/*.app → sign, notarize, then wrap in a .dmg
```

**iOS** (needs macOS + Xcode)
```bash
flutter build ipa --release
# build/ios/ipa/*.ipa → upload via Transporter / App Store Connect
```

**Android** (any host)
```bash
flutter build appbundle --release   # .aab for Play
flutter build apk --release         # .apk for direct install
```

**Windows** (needs a Windows host)
```bash
flutter build windows --release
# build/windows/x64/runner/Release/ → package with Inno Setup / MSIX into an .exe
```

**Linux** (needs a Linux host)
```bash
flutter build linux --release
# build/linux/x64/release/bundle/ → package into a .deb
```

Windows and Linux cannot be built on macOS — either use a CI runner or a real
machine for those two.

## Publishing a download

The macOS, Windows and Linux rows on the site are **already wired** to the
v1.0.0 release URLs. iPhone and Android are still `Coming soon`, since they
link to store pages rather than files.

To wire a row (the site's own comment at `geonix_wrench.html:240` says the same):

```html
<!-- before -->
<span class="dl" aria-disabled="true">
  <span class="dl-text">
    <strong>macOS</strong>
    <small>.dmg</small>
  </span>
  <em class="dl-soon">Coming soon</em>
</span>

<!-- after -->
<a class="dl" href="https://github.com/geonixsoftware/geonix/releases/download/v1.0.0/geonix-wrench-1.0.0-macos.dmg">
  <span class="dl-text">
    <strong>macOS</strong>
    <small>.dmg</small>
  </span>
</a>
```

Delete the `<em class="dl-soon">` line and close with `</a>`. `.dl` styling,
hover and keyboard focus all apply to the anchor automatically — no CSS change.

**Every new version bumps the URLs.** The filenames carry the version, so
releasing 1.1.0 means editing those three `href`s to match.

## Checksums

Generate alongside each artifact so people can verify what they downloaded:

```bash
shasum -a 256 geonix-wrench-1.0.0-macos.dmg > geonix-wrench-1.0.0-macos.dmg.sha256
```

`.sha256` files are small and text — those *are* kept in git (see `.gitignore`).
