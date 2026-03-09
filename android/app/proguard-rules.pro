# Flutter wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.google.firebase.** { *; }

# SQLite
-keep class androidx.sqlite.** { *; }

# Local authentication
-keep class androidx.biometric.** { *; }

# File picker
-keep class * extends java.lang.reflect.Member { *; }
-keepclassmembers class * { @android.webkit.JavascriptInterface <methods>; }

# Ignore missing Play Core classes (app doesn't use deferred components)
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
