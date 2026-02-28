-keep class net.sqlcipher.** { *; }

# ali_auth SDK
-dontwarn javax.xml.stream.XMLStreamException

# ==========================================
# 阿里云一键登录 SDK 官方 ProGuard 配置
# 来源: SDK Demo/app/proguard-rules.pro
# ==========================================
-keepattributes Exceptions,InnerClasses,Signature,Deprecated,*Annotation*,EnclosingMethod
-keep class android.app.ActivityThread {*;}
-keep class android.os.SystemProperties {*;}

# 保护 AppCompatActivity（SDK 的 LoginAuthActivity 继承自它）
# 来源: https://help.aliyun.com/zh/pnvs/developer-reference/the-android-client-access
-keep class androidx.appcompat.app.AppCompatActivity { *; }
-keep class androidx.core.content.ContextCompat { *; }

# 保护 SDK 所有类
-keep class com.mobile.auth.gatewayauth.** { *; }
-keep class com.nirvana.** { *; }
-keep class com.cmic.** { *; }
-keep class cn.com.chinatelecom.** { *; }
-keep class com.unicom.** { *; }

# 保护 JSON 类（防止 NoSuchMethodError）
-keep class org.json.** { *; }

# 禁止警告
-dontwarn com.mobile.auth.gatewayauth.**
-dontwarn com.nirvana.**
-dontwarn com.cmic.**
-dontwarn cn.com.chinatelecom.**
-dontwarn com.unicom.**

# ==========================================
# 阿里云移动推送 SDK ProGuard 配置
# ==========================================
-keepclasseswithmembernames class ** {
    native <methods>;
}
-keep class com.taobao.** {*;}
-keep class com.alibaba.** {*;}
-keep class com.alipay.** {*;}
-keep class com.ut.** {*;}
-keep class com.ta.** {*;}
-keep class anet.** {*;}
-keep class anetwork.** {*;}
-keep class org.android.agoo.** {*;}
-keep class org.android.spdy.** {*;}

-keep public class **.R$* {
    public static final int *;
}

-keepattributes Signature
-keep class sun.misc.Unsafe { *; }

-dontwarn com.taobao.**
-dontwarn com.alibaba.**
-dontwarn com.alipay.**
-dontwarn anet.**
-dontwarn org.android.agoo.**
-dontwarn org.android.spdy.**

# 华为 HMS 厂商通道（暂未接入，忽略缺失类）
-dontwarn com.huawei.**
-dontwarn org.bouncycastle.**

# 小米/OPPO/vivo 厂商通道
-keep class com.xiaomi.** {*;}
-dontwarn com.xiaomi.**
-keep public class * extends android.app.Service
-keep class com.heytap.** { *; }
-dontwarn com.heytap.**
-dontwarn com.coloros.**
-keep class com.vivo.** { *; }
-dontwarn com.vivo.**
-dontwarn com.meizu.**

# 荣耀厂商通道
-keep class com.hihonor.push.** { *; }
-dontwarn com.hihonor.**
