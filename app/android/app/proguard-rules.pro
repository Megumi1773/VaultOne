# flutter_rust_bridge / JNI 入口保留
-keep class io.flutter.** { *; }
-dontwarn io.flutter.embedding.**
# Play Core（Flutter deferred components 引用，未使用）
-dontwarn com.google.android.play.core.**
