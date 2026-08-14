# Flutter / engine
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.**

# Keep line numbers for readable crash reports.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# Reflection-based libraries (Firebase, JSON (de)serialization, etc.)
-keepattributes *Annotation*
-keepattributes Signature
-keep class com.google.firebase.** { *; }
-keep class kotlin.Metadata { *; }
-keep class kotlin.coroutines.** { *; }
-dontwarn com.google.firebase.**
