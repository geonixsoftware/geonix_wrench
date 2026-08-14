# Geonix wrench software files removed

This directory is a **failsafe staging area**, not a trash can.

Per the project's hard rule ("do not delete files/packages/code blocks
entirely"), anything that was taken out of the active build during the
security hardening pass was **moved here** (or a verified backup was placed
here) so the change can be reverted if a build or runtime breaks.

## How to revert
- The pre-edit copy of `pubspec.yaml` is backed up as `pubspec.yaml.bak`.
- The pre-edit copy of `android/app/build.gradle.kts` is backed up as
  `android_app_build.gradle.kts.bak`.
- To undo the unused-package cleanup, restore `pubspec.yaml.bak` over
  `pubspec.yaml` and re-run `flutter pub get`.

Nothing in here is referenced by the build. It is safe to keep or, once you
have confirmed the release works, to delete this whole folder.
