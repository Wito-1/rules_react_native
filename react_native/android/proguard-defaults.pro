# Default R8 rules for react_native_android_app(minify = True): the essentials of AGP's
# proguard-android-optimize.txt, plus line numbers for symbolicating stack traces with the
# mapping file. React Native's own keep rules come with react-android's consumer proguard.txt.

-allowaccessmodification
-dontusemixedcaseclassnames
-keepattributes AnnotationDefault,RuntimeVisibleAnnotations,RuntimeVisibleParameterAnnotations,RuntimeVisibleTypeAnnotations
-keepattributes Signature,InnerClasses,EnclosingMethod,Exceptions
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# JNI: native methods are looked up by name.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

-keepclassmembers class * implements android.os.Parcelable {
    public static final ** CREATOR;
}

# Views are inflated and animated by reflection.
-keepclassmembers public class * extends android.view.View {
    void set*(***);
    *** get*();
}

-keepclassmembers class * extends android.app.Activity {
    public void *(android.view.View);
}

-keepclassmembers class **.R$* {
    public static <fields>;
}

-keep class androidx.annotation.Keep
-keep @androidx.annotation.Keep class * { *; }
-keepclasseswithmembers class * {
    @androidx.annotation.Keep <methods>;
}
-keepclasseswithmembers class * {
    @androidx.annotation.Keep <fields>;
}
-keepclasseswithmembers class * {
    @androidx.annotation.Keep <init>(...);
}
-dontwarn androidx.annotation.Keep
