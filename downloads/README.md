# downloads/

Staging area for the five release artifacts linked from the **Get Geonix Wrench**
section of `geonix_website/geonix_wrench.html` (`#download`).

Nothing here is committed — see `.gitignore`. Binaries live on the GitHub
Release, not in the repo. This folder is where you build them, check them, and
upload them from.

Current app version: **1.0.0+1** (`geonix_wrench_app/pubspec.yaml`)

## Naming convention

Every artifact is uploaded **twice**, under two names:

```
geonix-wrench-<version>-<platform>.<ext>    archival — cite this one
geonix-wrench-<platform>.<ext>              alias — what the website links to
```

The alias exists so the site's hrefs never need editing again. They point at
`/releases/latest/download/geonix-wrench-<platform>.<ext>`, and GitHub resolves
that only against an asset with exactly that name — a versioned filename cannot
satisfy it. Releasing 1.1.0 moves "latest" and every row on the site follows.

| Slot            | Artifact                        | Website row   | Built by      |
|-----------------|---------------------------------|---------------|---------------|
| `ios/`          | (App Store/TestFlight — no file)| iPhone & iPad | —             |
| `android/`      | `geonix-wrench-android.apk`     | Android       | `release.yml` |
| `macos/`        | `geonix-wrench-macos.dmg`       | macOS         | `release.yml` |
| `windows/`      | `geonix-wrench-windows.exe`     | Windows       | `release.yml` |
| `linux/`        | `geonix-wrench-linux.deb`       | Linux         | disabled      |

iOS is the one row that can never be a download: Apple installs apps only
through the App Store or TestFlight. Android **is** a download — Play is a store
listing, not a link, and a shop that wants the app today installs the `.apk`.
The `android/` folder still holds the `.aab` you upload to Play separately.

## How the builds are produced

`.github/workflows/release.yml` builds each target on its native runner and
attaches them to a **draft** GitHub Release on this repo,
`geonixsoftware/geonix_wrench`.

```bash
git tag v1.0.0 && git push origin v1.0.0     # or run the workflow manually
```

Then: install each artifact on a clean machine, and press **Publish release**.
Draft assets are invisible to everyone but a maintainer, so every link on the
site 404s until you publish — that gate is deliberate.

What the workflow needs before it can run:

- **Four `ANDROID_*` secrets**, or the Android job fails by design.
  `android/app/build.gradle.kts` refuses to sign a release build with the debug
  keystore, and it is right to: that key is publicly known. Set
  `ANDROID_KEYSTORE_BASE64` (`base64 -i upload-keystore.jks`),
  `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`.
- Nothing else. The release lands in this repo, so the built-in `GITHUB_TOKEN`
  is enough — the old `RELEASE_TOKEN` PAT was only needed while the workflow
  published across repos, and is gone.

Not automated, and it shows on the site:

- The **macOS** `.dmg` is ad-hoc signed, not Developer ID signed or notarized,
  so Gatekeeper blocks the first double-click. The site tells people to
  right-click → Open. Fixing it properly means adding the certificate to the
  runner keychain plus `xcrun notarytool submit` — see the comments in the
  macOS job.
- The **Linux** job is commented out after an AOT snapshotter crash.

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

Android, macOS and Windows are **wired**, to `/releases/latest/download/` URLs
that do not carry a version — so a new release needs no website edit at all.
Publish the draft and the rows go live. iPhone (`In review`) and Linux
(`Coming soon`) are the two that are not wired.

To wire one of those later:

```html
<!-- before -->
<span class="dl" aria-disabled="true">
  <span class="dl-text">
    <strong>Linux</strong>
    <small>.deb</small>
  </span>
  <em class="dl-soon">Coming soon</em>
</span>

<!-- after -->
<a class="dl" href="https://github.com/geonixsoftware/geonix_wrench/releases/latest/download/geonix-wrench-linux.deb">
  <span class="dl-text">
    <strong>Linux</strong>
    <small>.deb</small>
  </span>
</a>
```

Delete the `<em class="dl-soon">` line and close with `</a>`. `.dl` styling,
hover and keyboard focus all apply to the anchor automatically — no CSS change.
For Linux, also uncomment the `linux` job in `release.yml` and add it back to
the publish job's `needs:` list, or the link will point at an asset nothing
builds.

## Checksums

Generate alongside each artifact so people can verify what they downloaded:

```bash
shasum -a 256 geonix-wrench-1.0.0-macos.dmg > geonix-wrench-1.0.0-macos.dmg.sha256
```

`.sha256` files are small and text — those *are* kept in git (see `.gitignore`).
