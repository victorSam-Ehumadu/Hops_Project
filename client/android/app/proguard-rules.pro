# R8 keep rules for release builds.
#
# WHY THIS FILE EXISTS
#
# Flutter enables R8 for `flutter build apk --release`, and there were no
# keep rules at all. R8 strips generic signatures by default, which breaks
# any library that reflects on them at runtime. flutter_local_notifications
# does exactly that — it persists scheduled notifications through Gson, and
# Gson's TypeToken needs the generic signature to survive.
#
# The symptom was not a crash on startup. It was this, in release only:
#
#   PlatformException(error, TypeToken must be created with a type
#   argument: new TypeToken<...>() {}; When using code shrinkers (ProGuard,
#   R8, ...) make sure that generic signatures are preserved.
#     at FlutterLocalNotificationsPlugin.cancelNotification
#     at FlutterLocalNotificationsPlugin.cancel
#   #3 NotificationService.cancelAlertsMatching
#
# i.e. EVERY notification cancel threw. An Emergency Flare's stand-down was
# received correctly and then could not dismiss the alert it was cancelling,
# so the alarm kept ringing until the process died — which read as "the
# stand-down doesn't work" and cost a day to find, because debug builds are
# not shrunk and behave perfectly.
#
# Showing a notification worked fine. Only cancelling it went through the
# Gson path, which is why the feature looked half-working rather than
# broken.

# Generic signatures — the actual fix. Annotations and inner-class info are
# kept alongside because the same reflection paths rely on them.
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# flutter_local_notifications' own classes, including the Gson model types
# it serialises. Recommended by the plugin itself.
-keep class com.dexterous.** { *; }

# Gson's reflection machinery. TypeToken subclasses are anonymous inner
# classes created for their generic parameter alone; shrinking or
# obfuscating them is exactly what produced the exception above.
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}
