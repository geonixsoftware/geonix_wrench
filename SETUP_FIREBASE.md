# Firebase setup

The app and backend are written against Firebase Auth already, but no real Firebase
project exists yet. Everything below is a manual, one-time setup a human needs to do
in the Firebase console and locally. Nothing here can be scripted safely (API keys,
Xcode capabilities, and signing fingerprints all require console/IDE access).

## 1. Create the Firebase project

1. Go to https://console.firebase.google.com and create a new project (e.g. "Geonix Wrench").
2. Under **Build → Authentication → Sign-in method**, enable:
   - **Email/Password**
   - **Google**
   - **Apple**
   - Leave **Phone** disabled — it's out of scope for this app.

## 2. Register the Android app

1. In the Firebase console, add an Android app with package name `com.geonixsoftware.wrench`.
2. Download the generated `google-services.json` and place it at
   `geonix_wrench_app/android/app/google-services.json` (replacing nothing — this
   filename does not exist yet; only the `.example` placeholder does).
3. Register the debug and release keystore **SHA-1** and **SHA-256** fingerprints for
   this app in the Firebase console (Project settings → Your apps → Android app) —
   required for Google Sign-In to work on Android. Get them with:
   ```
   keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
   ```
   and the equivalent command against your release keystore.

## 3. Register the iOS app

1. In the Firebase console, add an iOS app with bundle ID `com.geonixsoftware.wrench`.
2. Download the generated `GoogleService-Info.plist` and place it at
   `geonix_wrench_app/ios/Runner/GoogleService-Info.plist` (replacing nothing — only
   the `.example` placeholder exists today).
3. iOS Google Sign-In additionally needs the reversed client ID added as a URL scheme
   in `ios/Runner/Info.plist`. Running `flutterfire configure` (next step) or following
   the `google_sign_in` package's iOS setup instructions will give you the exact
   `REVERSED_CLIENT_ID` string to add.
4. In Xcode, open `ios/Runner.xcworkspace`, select the Runner target, go to
   **Signing & Capabilities**, and manually add the **Sign In with Apple** capability.
   This cannot be scripted — it edits the Xcode project's entitlements.

## 4. Register a Web app (optional)

If the Flutter web target will be used, also register a Web app in the Firebase
console under the same project.

## 5. Regenerate real Firebase options

From within `geonix_wrench_app/`, run:

```
dart pub global activate flutterfire_cli
flutterfire configure
```

This overwrites the placeholder `lib/firebase_options.dart` (currently full of
`REPLACE_ME` values) with real values, and wires up the Android Gradle
`google-services` plugin if it isn't already.

## 6. Backend service account

1. In the Firebase console, go to **Project settings → Service accounts** and generate
   a new private key.
2. Save it as `geonix_wrench_backend/firebase-service-account.json` (the backend already
   ships a `.example` placeholder next to where this real file belongs).
3. Make sure `firebase-service-account.json` is added to `.gitignore` in the backend
   directory — it must never be committed.

## Notes

- Until the steps above are done, the Flutter app fails loudly at
  `Firebase.initializeApp()` on startup (the placeholder API keys are rejected by
  Firebase), and the backend's `get_current_user` dependency fails closed with 401 on
  every request — both are the intended, safe behavior for an unconfigured project.
- Phone auth, invite-by-email for non-existent users, and ownership transfer are out of
  scope and intentionally not wired up anywhere.
