# Flutter / R8 minification kurallarý
# Bu dosya, release build sýrasýnda R8'in gereksiz uyarýlarý hata olarak
# deðerlendirmesini önler.

# --- missing_rules.txt'den otomatik üretilen kural ---
-dontwarn org.slf4j.impl.StaticLoggerBinder

# --- SLF4J tüm paketi (jcifs-ng baðýmlýlýðý) ---
-dontwarn org.slf4j.**

# --- Kerberos / JGSS (jcifs-ng baðýmlýlýðý) ---
-dontwarn org.ietf.jgss.**
-dontwarn javax.security.auth.kerberos.**
