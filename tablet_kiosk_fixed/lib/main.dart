import 'dart:async';
import 'dart:io';
import 'admin_panel.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';


 void main() {
  if (Platform.isWindows) {
    runApp(const AdminPanelApp());
  } else {
    runApp(const MyApp());
  }
}


class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tablet Kiosk - SMB',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: const ServerFilesPage(),
    );
  }
}

class ServerFilesPage extends StatefulWidget {
  const ServerFilesPage({super.key});

  @override
  State<ServerFilesPage> createState() => _ServerFilesPageState();
}

class _ServerFilesPageState extends State<ServerFilesPage> {
  static const _channel = MethodChannel('com.mg_tablet/smb');

  List<String> _serverFiles = [];
  Set<String> _downloadedFiles = {};
  String? _downloadingFileName;
  String? _statusMessage;
  bool _isError = false;
  bool _loading = true;
  Timer? _commandCheckTimer;

  // Cihazın kendi IP adresi – admin panelinde hangi klasör açılacağını gösterir
  String _deviceIp = '...';
  String _smbDebugInfo = ''; // Ekranda gösterilecek debug bilgisi

  @override
  void initState() {
    super.initState();
    _requestStoragePermissionThenLoad();
  }

  /// Uygulama açılışında MANAGE_EXTERNAL_STORAGE iznini ister.
  /// Reddedilirse ayarlara yönlendiren bir dialog gösterir.
  Future<void> _requestStoragePermissionThenLoad() async {
    if (Platform.isAndroid) {
      var status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) {
        status = await Permission.manageExternalStorage.request();
      }

      if (!status.isGranted) {
        // İzin reddedildi – kullanıcıya ayarlara yönlendirme dialogu göster
        if (mounted) {
          await _showPermissionDeniedDialog();
        }
        return;
      }
    }
    // İzin verildi veya Android değil – dosyaları yükle ve timer başlat
    await _loadServerFiles();
    _startCommandCheckTimer();
  }

  /// 5 saniyede bir sunucudan dosya listesini ve komutları kontrol eder.
  /// Admin panelinden gönderilen/silinen dosyalar 5sn içinde tablette görünür.
  void _startCommandCheckTimer() {
    _commandCheckTimer?.cancel();
    _commandCheckTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _syncWithServer(),
    );
  }

  /// Hem dosya listesini sessizce yeniler hem komutları kontrol eder.
  /// Loading göstergesi GÖSTERMEZ — arka plan senkronizasyonu.
  bool _syncing = false;
  Future<void> _syncWithServer() async {
    if (_syncing) return; // Önceki sync bitmeden yenisini başlatma
    _syncing = true;
    try {
      // IP'yi sessizce güncelle
      try {
        final ipResult = await _channel.invokeMethod<String>('getDeviceIp');
        if (ipResult != null && ipResult.isNotEmpty && mounted) {
          setState(() => _deviceIp = ipResult);
        }
      } catch (_) {}

      // Dosya listesini sessizce çek
      final result = await _channel.invokeMethod<List<Object?>>('listServerFiles');
      final files = result?.map((e) => e.toString()).toList() ?? [];
      final serverSet = files.toSet();

      if (mounted) {
        // === 1) OTOMATİK YEREL SİLME (İptal edilen dosyalar) ===
        // _checkDownloadedFiles'dan ÖNCE yapılmalı yoksa _downloadedFiles sıfırlanır
        // Önceki _downloadedFiles'da olup sunucuda artık olmayanları sil
        final removedFiles = _downloadedFiles.where((f) => !serverSet.contains(f)).toList();
        for (final fileName in removedFiles) {
          try {
            final localFile = File('/storage/emulated/0/Download/$fileName');
            if (await localFile.exists()) await localFile.delete();
          } catch (_) {}
        }
        // UI'dan hemen kaldır
        if (removedFiles.isNotEmpty && mounted) {
          setState(() => _downloadedFiles.removeAll(removedFiles));
        }

        // === 2) Sunucu dosya listesini güncelle ===
        final serverIp = '172.16.111.67';
        setState(() {
          _serverFiles = files;
          _smbDebugInfo = [
            'Tablet IP   : $_deviceIp',
            'SMB URL     : smb://$serverIp/tablet_dosyalar/$_deviceIp/',
            'Dosya sayısı: ${files.length}',
          ].join('\n');
        });

        // === 3) İndirilen dosyaları yeniden kontrol et ===
        await _checkDownloadedFiles();

        // === 4) OTOMATİK İNDİRME ===
        // Sunucuda olup tablette henüz indirilmemiş dosyaları otomatik indir
        final newFiles = files.where((f) => !_downloadedFiles.contains(f)).toList();
        for (final fileName in newFiles) {
          if (_downloadingFileName != null) break; // Başka indirme varsa bekle
          try {
            setState(() => _downloadingFileName = fileName);
            await _channel.invokeMethod<String>('downloadSmbFile', {
              'fileName': fileName,
            });
            if (mounted) {
              setState(() {
                _downloadedFiles.add(fileName);
                _downloadingFileName = null;
              });
            }
          } catch (_) {
            if (mounted) setState(() => _downloadingFileName = null);
          }
        }
      }
    } catch (_) {
      // Arka plan senkronizasyonu — hata olursa sessizce devam et
    } finally {
      _syncing = false;
    }

    // Silme komutlarını kontrol et
    await _checkCommands();
  }

  /// Sunucudaki _commands.json dosyasını kontrol eder.
  /// Silme komutu varsa dosyaları siler, listeyi yeniler ve bilgi gösterir.
  Future<void> _checkCommands() async {
    try {
      final result = await _channel.invokeMethod<List<Object?>>('checkCommands');
      final deletedFiles = result?.map((e) => e.toString()).toList() ?? [];

      if (deletedFiles.isNotEmpty && mounted) {
        // Dosya listesini yenile (silinen dosyaların ✅ işareti kalksın)
        await _loadServerFiles();
        setState(() {
          _statusMessage = '${deletedFiles.length} dosya sunucudan silindi';
          _isError = false;
        });
      }
    } catch (_) {
      // Arka plan işlemi – hata olursa sessizce yut
    }
  }

  /// İzin reddedildiğinde gösterilen dialog.
  /// "Ayarlara Git" → uygulama ayarlar ekranını açar.
  /// "İptal" → dialog kapanır ve boş sayfa görünür.
  Future<void> _showPermissionDeniedDialog() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Depolama İzni Gerekli'),
        content: const Text(
          'Dosyaların Download klasörüne kaydedilebilmesi için '
          '"Tüm dosyalara erişim" iznini vermeniz gerekiyor.\n\n'
          'Lütfen ayarlardan bu izni etkinleştirin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ayarlara Git'),
          ),
        ],
      ),
    );

    if (result == true) {
      await openAppSettings();
    }

    // Kullanıcı ayarlardan dönünce tekrar kontrol et
    if (mounted) {
      final status = await Permission.manageExternalStorage.status;
      if (status.isGranted) {
        _loadServerFiles();
      } else {
        setState(() {
          _loading = false;
          _statusMessage = 'Depolama izni verilmedi. Dosyalar indirilemez.';
          _isError = true;
        });
      }
    }
  }

  /// İndirilen dosyaların yerel varlığını kontrol eder
  Future<void> _checkDownloadedFiles() async {
    // Genel Download klasörü
    final downloadDir = '/storage/emulated/0/Download';
    final dir = Directory(downloadDir);
    if (await dir.exists()) {
      final entries = await dir.list().toList();
      final localNames = entries
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toSet();
      // Sadece sunucu dosya listesinde olanları filtrele
      setState(() => _downloadedFiles = localNames.intersection(_serverFiles.toSet()));
    }
  }

  /// Sunucudaki dosya listesini çeker
  Future<void> _loadServerFiles() async {
    setState(() {
      _loading = true;
      _statusMessage = null;
      _smbDebugInfo = '';
    });

    try {
      // Önce cihaz IP'sini al
      try {
        final ipResult = await _channel.invokeMethod<String>('getDeviceIp');
        if (ipResult != null && ipResult.isNotEmpty) {
          setState(() => _deviceIp = ipResult);
        }
      } catch (ipErr) {
        setState(() => _smbDebugInfo += 'getDeviceIp HATA: $ipErr\n');
      }

      final result = await _channel.invokeMethod<List<Object?>>('listServerFiles');
      final files = result?.map((e) => e.toString()).toList() ?? [];

      final serverIp = '172.16.111.67'; // DEFAULT_SERVER_IP ile aynı
      setState(() {
        _serverFiles = files;
        _loading = false;
        _smbDebugInfo = [
          'Tablet IP   : $_deviceIp',
          'SMB URL     : smb://$serverIp/tablet_dosyalar/$_deviceIp/',
          'Dosya sayısı: ${files.length}',
        ].join('\n');
      });
      await _checkDownloadedFiles();
    } on PlatformException catch (e) {
      setState(() {
        _statusMessage = 'Dosya listesi alınamadı: ${e.message}';
        _smbDebugInfo = 'PlatformException kodu: ${e.code}\nDetay: ${e.message}';
        _isError = true;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Beklenmedik hata: $e';
        _smbDebugInfo = 'Hata türü: ${e.runtimeType}\nDetay: $e';
        _isError = true;
        _loading = false;
      });
    }
  }

  /// Belirtilen dosyayı sunucudan indirir
  Future<void> _downloadFile(String fileName) async {
    setState(() {
      _downloadingFileName = fileName;
      _statusMessage = null;
    });

    try {
      final localPath = await _channel.invokeMethod<String>('downloadSmbFile', {
        'fileName': fileName,
      });
      setState(() {
        _statusMessage = '"$fileName" indirildi: $localPath';
        _isError = false;
        _downloadedFiles.add(fileName);
      });
    } on PlatformException catch (e) {
      setState(() {
        _statusMessage = '"$fileName" indirilemedi: ${e.message}';
        _isError = true;
      });
    } finally {
      setState(() => _downloadingFileName = null);
    }
  }


  @override
  void dispose() {
    _commandCheckTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sunucu Dosyaları'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Container(
            width: double.infinity,
            color: Colors.deepPurple.shade700,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Tablet IP: $_deviceIp',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline, color: Colors.white70),
            tooltip: 'SMB Bilgisi',
            onPressed: _smbDebugInfo.isEmpty ? null : () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('SMB Bağlantı Bilgisi'),
                  content: SingleChildScrollView(
                    child: SelectableText(
                      _smbDebugInfo,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Kapat'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadServerFiles,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        if (_statusMessage != null)
          Container(
            width: double.infinity,
            color: _isError
                ? Colors.red.withValues(alpha: 0.08)
                : Colors.green.withValues(alpha: 0.08),
            padding: const EdgeInsets.all(12),
            child: Text(
              _statusMessage!,
              style: TextStyle(
                color: _isError ? Colors.red.shade700 : Colors.green.shade700,
              ),
            ),
          ),
        Expanded(
          child: _serverFiles.isEmpty
              ? ListView(
                  // ListView olmalı ki RefreshIndicator çalışsın
                  children: [
                    const SizedBox(height: 160),
                    Center(
                      child: Column(
                        children: [
                          Icon(Icons.folder_open, size: 56, color: Colors.grey.shade400),
                          const SizedBox(height: 12),
                          const Text(
                            'Sunucuda bu tablete ait dosya bulunamadı.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 15, color: Colors.grey),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade50,
                              border: Border.all(color: Colors.orange.shade200),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              children: [
                                const Text(
                                  'Admin panelinde şu klasörü oluşturun:',
                                  style: TextStyle(fontSize: 13, color: Colors.black54),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'tablet_dosyalar\\$_deviceIp',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'monospace',
                                    color: Colors.orange.shade800,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              : ListView.builder(
                  itemCount: _serverFiles.length,
                  itemBuilder: (context, index) {
                    final fileName = _serverFiles[index];
                    final isDownloading = _downloadingFileName == fileName;
                    final isDownloaded = _downloadedFiles.contains(fileName);

                    return ListTile(
                      leading: Icon(
                        isDownloaded
                            ? Icons.check_circle
                            : Icons.insert_drive_file_outlined,
                        color: isDownloaded ? Colors.green : null,
                      ),
                      title: Text(fileName),
                      subtitle: isDownloaded
                          ? const Text('İndirildi',
                              style: TextStyle(color: Colors.green, fontSize: 12))
                          : null,
                      trailing: isDownloading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : IconButton(
                              icon: Icon(
                                isDownloaded ? Icons.refresh : Icons.download,
                              ),
                              tooltip: isDownloaded ? 'Tekrar İndir' : 'İndir',
                              onPressed: () => _downloadFile(fileName),
                            ),
                      onTap: isDownloading ? null : () => _downloadFile(fileName),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
