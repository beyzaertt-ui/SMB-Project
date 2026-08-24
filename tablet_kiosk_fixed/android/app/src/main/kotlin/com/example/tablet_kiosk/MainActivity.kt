package com.example.tablet_kiosk

import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import jcifs.context.SingletonContext
import jcifs.smb.SmbFile
import jcifs.smb.NtlmPasswordAuthenticator
import java.io.File
import java.io.FileOutputStream
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.os.Environment
import android.util.Log
import java.net.Inet4Address
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject

class MainActivity: FlutterActivity() {
    // Flutter ile haberleşeceğimiz kanalın adı
    private val CHANNEL = "com.mg_tablet/smb"

    // ŞİRKET SUNUCUSU BİLGİLERİ - varsayılan değerler.
    // Dart tarafından "serverIp", "shareName", "username", "password"
    // gönderilirse onlar kullanılır; gönderilmezse buradaki varsayılanlara düşer.
    // NOT: Üretimde bu değerleri kod içine sabit yazmak yerine cihaza
    // kurulumda bırakılan şifrelenmiş bir config dosyasından okumanı öneririm.
    private val DEFAULT_SERVER_IP = "172.16.111.67"
    private val DEFAULT_SHARE_NAME = "tablet_dosyalar"
    private val DEFAULT_USERNAME = "beyza.erturk"
    private val DEFAULT_PASSWORD = "Mege@123"

    /**
     * ConnectivityManager kullanarak tabletin Wi-Fi IPv4 adresini döndürür.
     * Bulunamazsa "0.0.0.0" döner.
     */
    private fun getDeviceIpAddress(): String {
        try {
            val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            val network = cm.activeNetwork ?: return "0.0.0.0"
            val linkProps: LinkProperties = cm.getLinkProperties(network) ?: return "0.0.0.0"
            for (addr in linkProps.linkAddresses) {
                val inetAddr = addr.address
                if (inetAddr is Inet4Address && !inetAddr.isLoopbackAddress) {
                    return inetAddr.hostAddress ?: "0.0.0.0"
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return "0.0.0.0"
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getDeviceIp" -> {
                    val ip = getDeviceIpAddress()
                    result.success(ip)
                }

                "listServerFiles" -> {
                    val serverIp = call.argument<String>("serverIp") ?: DEFAULT_SERVER_IP
                    val shareName = call.argument<String>("shareName") ?: DEFAULT_SHARE_NAME
                    val username = call.argument<String>("username") ?: DEFAULT_USERNAME
                    val password = call.argument<String>("password") ?: DEFAULT_PASSWORD

                    val deviceIp = getDeviceIpAddress()

                    Log.d("SMB_DEBUG", "=== listServerFiles BASLADI ===")
                    Log.d("SMB_DEBUG", "  deviceIp        : '$deviceIp'")
                    Log.d("SMB_DEBUG", "  serverIp        : '$serverIp'")
                    Log.d("SMB_DEBUG", "  shareName       : '$shareName'")
                    Log.d("SMB_DEBUG", "  username        : '$username'")
                    Log.d("SMB_DEBUG", "  SMB URL hedef   : smb://$serverIp/$shareName/$deviceIp/")

                    if (deviceIp == "0.0.0.0") {
                        Log.e("SMB_DEBUG", "  HATA: Tablet IP alinamadi! Wi-Fi baglantisinizi kontrol edin.")
                        result.error("NETWORK_HATA", "Tabletin IP adresi alınamadı", null)
                        return@setMethodCallHandler
                    }

                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val auth = NtlmPasswordAuthenticator("", username, password)
                            val context = SingletonContext.getInstance().withCredentials(auth)

                            val smbUrl = "smb://$serverIp/$shareName/$deviceIp/"
                            Log.d("SMB_DEBUG", "  SMB baglantisi deneniyor: $smbUrl")

                            val smbDir = SmbFile(smbUrl, context)

                            val dirExists = try { smbDir.exists() } catch (ex: Exception) {
                                Log.e("SMB_DEBUG", "  exists() HATA: ${ex.javaClass.simpleName}: ${ex.message}")
                                false
                            }
                            val dirCanRead = if (dirExists) {
                                try { smbDir.canRead() } catch (ex: Exception) {
                                    Log.e("SMB_DEBUG", "  canRead() HATA: ${ex.javaClass.simpleName}: ${ex.message}")
                                    false
                                }
                            } else false

                            Log.d("SMB_DEBUG", "  klasor exists=$dirExists  canRead=$dirCanRead")

                            val fileNames: List<String> = if (dirExists && dirCanRead) {
                                val files = try {
                                    smbDir.listFiles()
                                } catch (ex: Exception) {
                                    Log.e("SMB_DEBUG", "  listFiles() HATA: ${ex.javaClass.simpleName}: ${ex.message}")
                                    null
                                }
                                val filtered = files
                                    ?.filter { !it.isDirectory }
                                    ?.map { it.name }
                                    ?: emptyList()
                                Log.d("SMB_DEBUG", "  Bulunan dosya sayisi: ${filtered.size}")
                                filtered.forEach { Log.d("SMB_DEBUG", "    -> $it") }
                                filtered
                            } else {
                                if (!dirExists) Log.w("SMB_DEBUG", "  UYARI: Klasor bulunamadi: $smbUrl")
                                emptyList()
                            }

                            Log.d("SMB_DEBUG", "=== listServerFiles BITTI: ${fileNames.size} dosya ===")
                            withContext(Dispatchers.Main) { result.success(fileNames) }
                        } catch (e: Exception) {
                            Log.e("SMB_DEBUG", "=== listServerFiles GENEL HATA: ${e.javaClass.simpleName}: ${e.message}")
                            e.printStackTrace()
                            withContext(Dispatchers.Main) { result.success(emptyList<String>()) }
                        }
                    }
                }

                "downloadSmbFile" -> {
                    val fileName = call.argument<String>("fileName")

                    if (fileName.isNullOrEmpty()) {
                        result.error("EKSIK_PARAMETRE", "fileName zorunludur", null)
                        return@setMethodCallHandler
                    }

                    val serverIp = call.argument<String>("serverIp") ?: DEFAULT_SERVER_IP
                    val shareName = call.argument<String>("shareName") ?: DEFAULT_SHARE_NAME
                    val username = call.argument<String>("username") ?: DEFAULT_USERNAME
                    val password = call.argument<String>("password") ?: DEFAULT_PASSWORD

                    val deviceIp = getDeviceIpAddress()
                    if (deviceIp == "0.0.0.0") {
                        result.error("NETWORK_HATA", "Tabletin IP adresi alınamadı", null)
                        return@setMethodCallHandler
                    }

                    // Ağ işlemleri ana UI'ı dondurmasın diye arka planda başlatıyoruz
                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val auth = NtlmPasswordAuthenticator("", username, password)
                            val context = SingletonContext.getInstance().withCredentials(auth)

                            // Örn: smb://172.16.111.67/tablet_dosyalar/172.16.111.71/rapor.pdf
                            val smbUrl = "smb://$serverIp/$shareName/$deviceIp/$fileName"
                            val smbFile = SmbFile(smbUrl, context)

                            // Genel Download klasörüne kaydet
                            val localDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                            if (!localDir.exists()) localDir.mkdirs()
                            val localFile = File(localDir, fileName)

                            smbFile.inputStream.use { inStream ->
                                FileOutputStream(localFile).use { outStream ->
                                    inStream.copyTo(outStream)
                                }
                            }

                            // İndirme başarılı – sunucuya durum bildir (_status.json)
                            try {
                                val statusUrl = "smb://$serverIp/$shareName/$deviceIp/_status.json"
                                val statusSmbFile = SmbFile(statusUrl, context)

                                // Mevcut içeriği oku (varsa)
                                val existingJson = if (statusSmbFile.exists()) {
                                    statusSmbFile.inputStream.use { it.bufferedReader().readText() }
                                } else {
                                    "{}"
                                }

                                val root = try { JSONObject(existingJson) } catch (_: Exception) { JSONObject() }

                                // Yeni girişi ekle / güncelle
                                val entry = JSONObject()
                                entry.put("indirildi", true)
                                entry.put("indirilmeZamani",
                                    ZonedDateTime.now().format(DateTimeFormatter.ISO_OFFSET_DATE_TIME))
                                root.put(fileName, entry)

                                // Güncellenmiş JSON'u sunucuya yaz
                                statusSmbFile.outputStream.use { out ->
                                    out.write(root.toString(2).toByteArray(Charsets.UTF_8))
                                }

                                Log.i("SMB_STATUS", "_status.json güncellendi: $fileName")
                            } catch (statusEx: Exception) {
                                // Durum bildirimi başarısız olsa bile indirme başarılı sayılır
                                Log.w("SMB_STATUS", "_status.json güncellenemedi: ${statusEx.message}")
                            }

                            withContext(Dispatchers.Main) {
                                result.success(localFile.absolutePath)
                            }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) {
                                result.error("SMB_HATA", e.message, null)
                            }
                        }
                    }
                }

                "checkCommands" -> {
                    val serverIp = call.argument<String>("serverIp") ?: DEFAULT_SERVER_IP
                    val shareName = call.argument<String>("shareName") ?: DEFAULT_SHARE_NAME
                    val username = call.argument<String>("username") ?: DEFAULT_USERNAME
                    val password = call.argument<String>("password") ?: DEFAULT_PASSWORD

                    val deviceIp = getDeviceIpAddress()
                    if (deviceIp == "0.0.0.0") {
                        result.success(emptyList<String>())
                        return@setMethodCallHandler
                    }

                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            val auth = NtlmPasswordAuthenticator("", username, password)
                            val context = SingletonContext.getInstance().withCredentials(auth)

                            val commandsUrl = "smb://$serverIp/$shareName/$deviceIp/_commands.json"
                            val commandsSmbFile = SmbFile(commandsUrl, context)

                            // _commands.json yoksa boş liste dön
                            if (!commandsSmbFile.exists()) {
                                withContext(Dispatchers.Main) {
                                    result.success(emptyList<String>())
                                }
                                return@launch
                            }

                            // Komut dosyasını oku
                            val commandsJson = commandsSmbFile.inputStream.use {
                                it.bufferedReader().readText()
                            }
                            val commandsRoot = try { JSONObject(commandsJson) } catch (_: Exception) { JSONObject() }
                            val silArray = if (commandsRoot.has("sil")) commandsRoot.getJSONArray("sil") else JSONArray()

                            if (silArray.length() == 0) {
                                withContext(Dispatchers.Main) {
                                    result.success(emptyList<String>())
                                }
                                return@launch
                            }

                            val deletedFiles = mutableListOf<String>()
                            val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)

                            // _status.json'u oku (güncelleme için)
                            val statusUrl = "smb://$serverIp/$shareName/$deviceIp/_status.json"
                            val statusSmbFile = SmbFile(statusUrl, context)
                            val statusRoot = try {
                                if (statusSmbFile.exists()) {
                                    val txt = statusSmbFile.inputStream.use { it.bufferedReader().readText() }
                                    JSONObject(txt)
                                } else {
                                    JSONObject()
                                }
                            } catch (_: Exception) { JSONObject() }

                            val nowIso = ZonedDateTime.now().format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)

                            // Silme işlemlerini yap
                            for (i in 0 until silArray.length()) {
                                val fileToDelete = silArray.optString(i, "") ?: continue
                                if (fileToDelete.isEmpty()) continue

                                val localFile = File(downloadDir, fileToDelete)
                                if (localFile.exists()) {
                                    localFile.delete()
                                    Log.i("SMB_CMD", "Dosya silindi: $fileToDelete")
                                } else {
                                    Log.i("SMB_CMD", "Dosya zaten yok, atlanıyor: $fileToDelete")
                                }
                                deletedFiles.add(fileToDelete)

                                // _status.json güncelle
                                val entry = if (statusRoot.has(fileToDelete)) {
                                    statusRoot.getJSONObject(fileToDelete)
                                } else {
                                    JSONObject()
                                }
                                entry.put("indirildi", false)
                                entry.put("silinmeZamani", nowIso)
                                statusRoot.put(fileToDelete, entry)
                            }

                            // _status.json'u sunucuya yaz
                            try {
                                statusSmbFile.outputStream.use { out ->
                                    out.write(statusRoot.toString(2).toByteArray(Charsets.UTF_8))
                                }
                                Log.i("SMB_CMD", "_status.json güncellendi (silme sonrası)")
                            } catch (statusEx: Exception) {
                                Log.w("SMB_CMD", "_status.json güncellenemedi: ${statusEx.message}")
                            }

                            // _commands.json içindeki "sil" listesini temizle
                            try {
                                commandsRoot.put("sil", JSONArray())
                                // Yeni bir SmbFile nesnesi oluştur (önceki stream kapandı)
                                val commandsSmbFileWrite = SmbFile(commandsUrl, context)
                                commandsSmbFileWrite.outputStream.use { out ->
                                    out.write(commandsRoot.toString(2).toByteArray(Charsets.UTF_8))
                                }
                                Log.i("SMB_CMD", "_commands.json temizlendi")
                            } catch (cmdEx: Exception) {
                                Log.w("SMB_CMD", "_commands.json temizlenemedi: ${cmdEx.message}")
                            }

                            withContext(Dispatchers.Main) {
                                result.success(deletedFiles)
                            }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) {
                                // Arka plan kontrolü – hata olursa boş liste dön
                                result.success(emptyList<String>())
                            }
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }
}
