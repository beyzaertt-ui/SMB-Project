import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Kiosk SMB Gönderim',
      theme: ThemeData(primarySwatch: Colors.blueGrey),
      home: const DosyaListesiEkrani(),
    );
  }
}

class DosyaListesiEkrani extends StatefulWidget {
  const DosyaListesiEkrani({super.key});

  @override
  State<DosyaListesiEkrani> createState() => _DosyaListesiEkraniState();
}

class _DosyaListesiEkraniState extends State<DosyaListesiEkrani> {
  // Android tarafındaki (Kotlin) kodumuzla aynı kanal adı
  static const platform = MethodChannel('com.mg_tablet/smb');
  
  List<FileSystemEntity> _dosyalar = [];
  bool _yukleniyor = true;

  @override
  void initState() {
    super.initState();
    _izinIsteVeDosyalariGetir();
  }

  Future<void> _izinIsteVeDosyalariGetir() async {
    if (await Permission.manageExternalStorage.request().isGranted ||
        await Permission.storage.request().isGranted) {
      
      final klasor = Directory('/storage/emulated/0/Download');
      
      if (klasor.existsSync()) {
        setState(() {
          _dosyalar = klasor.listSync().whereType<File>().toList();
          _yukleniyor = false;
        });
      } else {
        setState(() => _yukleniyor = false);
      }
    } else {
      setState(() => _yukleniyor = false);
    }
  }

  Future<void> _dosyayiSmbGonder(File dosya) async {
    String dosyaAdi = dosya.path.split('/').last;

    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$dosyaAdi gönderiliyor...')),
      );

      // Kotlin dosyasında yazdığımız "sendSmbFile" metodunu çağırıyoruz
      await platform.invokeMethod('sendSmbFile', {
        'filePath': dosya.path,
        'fileName': dosyaAdi,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Dosya başarıyla sunucuya aktarıldı!'),
          backgroundColor: Colors.green,
        ),
      );
    } on PlatformException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Gönderim Hatası: ${e.message}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('İndirilenler Klasörü (Kiosk)'),
        backgroundColor: Colors.black87,
      ),
      body: _yukleniyor
          ? const Center(child: CircularProgressIndicator())
          : _dosyalar.isEmpty
              ? const Center(child: Text('Klasörde dosya bulunamadı.'))
              : ListView.builder(
                  itemCount: _dosyalar.length,
                  itemBuilder: (context, index) {
                    final dosya = _dosyalar[index] as File;
                    final dosyaAdi = dosya.path.split('/').last;

                    return Card(
                      margin: const EdgeInsets.all(8.0),
                      child: ListTile(
                        leading: const Icon(Icons.file_copy, size: 40),
                        title: Text(dosyaAdi),
                        trailing: ElevatedButton.icon(
                          icon: const Icon(Icons.cloud_upload),
                          label: const Text('SMB Sunucuya Gönder'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blueGrey,
                          ),
                          onPressed: () => _dosyayiSmbGonder(dosya),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}