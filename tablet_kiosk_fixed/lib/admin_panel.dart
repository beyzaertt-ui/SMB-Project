import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

class AdminPanelApp extends StatelessWidget {
  const AdminPanelApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tablet Kiosk - Admin Paneli',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const AdminHomePage(),
    );
  }
}

class AdminHomePage extends StatefulWidget {
  const AdminHomePage({super.key});
  @override
  State<AdminHomePage> createState() => _AdminHomePageState();
}

class _AdminHomePageState extends State<AdminHomePage> {
  final String _basePath = r'C:\Users\beyza.erturk\Desktop\tablet_dosyalar';
  String get _poolPath => _basePath + r'\_havuz';
  List<String> _tabletFolders = [];
  String? _selectedTablet;
  bool _loading = false;
  String? _message;
  Timer? _autoRefreshTimer;
  Timer? _pingTimer;
  List<FileSystemEntity> _tabletFiles = [];
  Map<String, dynamic> _statusMap = {};
  Set<String> _pendingDeleteFiles = {};
  Map<String, bool> _onlineStatus = {};
  List<FileSystemEntity> _poolFiles = [];
  Set<String> _selectedPoolFiles = {};
  Set<String> _selectedTargetTablets = {};
  bool _sendingFiles = false;
  bool _isCancelling = false;
  // Az once iptal edilenler - 10sn grace period, SMB gecikmesinde dosya geri gelmiyor
  Set<String> _recentlyCancelledFiles = {};

  @override
  void initState() {
    super.initState();
    _scanTablets(); _loadPoolFiles();
    _startAutoRefreshTimer(); _checkAllPings(); _startPingTimer();
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel(); _pingTimer?.cancel();
    super.dispose();
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkAllPings());
  }

  Future<bool> _pingIp(String ip) async {
    try {
      final result = await Process.run('ping', ['-n', '1', '-w', '1000', ip]);
      return result.exitCode == 0;
    } catch (_) { return false; }
  }

  Future<void> _checkAllPings() async {
    if (_tabletFolders.isEmpty) return;
    try {
      final results = await Future.wait(
        _tabletFolders.map((ip) async { final ok = await _pingIp(ip); return MapEntry(ip, ok); }),
      );
      if (mounted) setState(() => _onlineStatus = Map.fromEntries(results));
    } catch (_) {}
  }

  void _startAutoRefreshTimer() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _silentRefresh());
  }

  Future<void> _silentRefresh() async {
    try {
      final baseDir = Directory(_basePath);
      if (!await baseDir.exists()) return;
      final entities = await baseDir.list().toList();
      final dirs = entities
          .whereType<Directory>()
          .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .where((name) => name != '_havuz').toList()..sort();
      if (mounted) {
        setState(() {
          _tabletFolders = dirs;
          if (_selectedTablet != null && !dirs.contains(_selectedTablet)) _selectedTablet = null;
          else if (_selectedTablet == null && dirs.isNotEmpty) _selectedTablet = dirs.first;
          _selectedTargetTablets.removeWhere((t) => !dirs.contains(t));
        });
      }
      if (_selectedTablet != null && !_isCancelling) {
        await _silentLoadTabletDetails(_selectedTablet!);
      }
      await _loadPoolFiles();
    } catch (_) {}
  }

  Future<void> _scanTablets() async {
    setState(() { _loading = true; _message = null; });
    try {
      final baseDir = Directory(_basePath);
      if (!await baseDir.exists()) await baseDir.create(recursive: true);
      final entities = await baseDir.list().toList();
      final dirs = entities
          .whereType<Directory>()
          .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .where((name) => name != '_havuz').toList()..sort();
      setState(() {
        _tabletFolders = dirs; _loading = false;
        if (_selectedTablet != null && !dirs.contains(_selectedTablet)) _selectedTablet = null;
        else if (_selectedTablet == null && dirs.isNotEmpty) _selectedTablet = dirs.first;
      });
      if (_selectedTablet != null) await _loadTabletDetails(_selectedTablet!);
      _checkAllPings();
    } catch (e) {
      setState(() { _loading = false; _message = 'Tarama hatasi: ' + e.toString(); });
    }
  }

  Future<void> _loadTabletDetails(String tabletIp) async {
    final tabletDir = Directory(_basePath + r'\' + tabletIp);
    if (!await tabletDir.exists()) return;
    try {
      final entities = await tabletDir.list().toList();
      Map<String, dynamic> statusData = {};
      final sf = File(_basePath + r'\' + tabletIp + r'\_status.json');
      if (await sf.exists()) {
        try { statusData = jsonDecode(await sf.readAsString()) as Map<String, dynamic>; } catch (_) {}
      }
      Set<String> pd = {};
      final cf = File(_basePath + r'\' + tabletIp + r'\_commands.json');
      if (await cf.exists()) {
        try {
          final d = jsonDecode(await cf.readAsString()) as Map<String, dynamic>;
          if (d.containsKey('sil') && d['sil'] is List) pd = Set<String>.from(d['sil']);
        } catch (_) {}
      }
      final files = entities.where((e) {
        final n = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        return n != '_status.json' && n != '_commands.json'
            && e is File && !_recentlyCancelledFiles.contains(n);
      }).toList()..sort((a, b) => a.path.compareTo(b.path));
      setState(() { _tabletFiles = files; _statusMap = statusData; _pendingDeleteFiles = pd; });
    } catch (e) { setState(() => _message = 'Detay hatasi: ' + e.toString()); }
  }

  Future<void> _silentLoadTabletDetails(String tabletIp) async {
    if (_isCancelling) return;
    final tabletDir = Directory(_basePath + r'\' + tabletIp);
    if (!await tabletDir.exists()) return;
    try {
      final entities = await tabletDir.list().toList();
      Map<String, dynamic> statusData = {};
      final sf = File(_basePath + r'\' + tabletIp + r'\_status.json');
      if (await sf.exists()) {
        try { statusData = jsonDecode(await sf.readAsString()) as Map<String, dynamic>; } catch (_) {}
      }
      Set<String> pd = {};
      final cf = File(_basePath + r'\' + tabletIp + r'\_commands.json');
      if (await cf.exists()) {
        try {
          final d = jsonDecode(await cf.readAsString()) as Map<String, dynamic>;
          if (d.containsKey('sil') && d['sil'] is List) pd = Set<String>.from(d['sil']);
        } catch (_) {}
      }
      final files = entities.where((e) {
        final n = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        return n != '_status.json' && n != '_commands.json'
            && e is File && !_recentlyCancelledFiles.contains(n);
      }).toList()..sort((a, b) => a.path.compareTo(b.path));
      if (!_isCancelling && mounted) {
        setState(() { _tabletFiles = files; _statusMap = statusData; _pendingDeleteFiles = pd; });
      }
    } catch (_) {}
  }

  // === DOSYA HAVUZU ===

  Future<void> _loadPoolFiles() async {
    try {
      final poolDir = Directory(_poolPath);
      if (!await poolDir.exists()) await poolDir.create(recursive: true);
      final entities = await poolDir.list().toList();
      final files = entities.whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      if (mounted) {
        setState(() {
          _poolFiles = files;
          final names = files.map((f) => f.uri.pathSegments.where((s) => s.isNotEmpty).last).toSet();
          _selectedPoolFiles.removeWhere((n) => !names.contains(n));
        });
      }
    } catch (_) {}
  }

  Future<void> _addFilesToPool() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;
    final poolDir = Directory(_poolPath);
    if (!await poolDir.exists()) await poolDir.create(recursive: true);
    int count = 0;
    for (var pf in result.files) {
      if (pf.path != null) { await File(pf.path!).copy(_poolPath + r'\' + pf.name); count++; }
    }
    await _loadPoolFiles();
    if (mounted && count > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(count.toString() + ' dosya havuza eklendi.'),
        backgroundColor: Colors.green,
      ));
    }
  }

  Future<void> _removeFromPool(String fileName) async {
    final f = File(_poolPath + r'\' + fileName);
    if (await f.exists()) await f.delete();
    setState(() => _selectedPoolFiles.remove(fileName));
    await _loadPoolFiles();
  }

  Future<void> _sendPoolFilesToTablets() async {
    if (_selectedPoolFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lutfen dosya secin.'), backgroundColor: Colors.orange));
      return;
    }
    if (_selectedTargetTablets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lutfen tablet secin.'), backgroundColor: Colors.orange));
      return;
    }
    setState(() => _sendingFiles = true);
    _recentlyCancelledFiles.removeAll(_selectedPoolFiles);
    int totalCopied = 0;
    final errors = <String>[];
    for (final tabletIp in _selectedTargetTablets) {
      final td = Directory(_basePath + r'\' + tabletIp);
      if (!await td.exists()) await td.create(recursive: true);
      for (final fileName in _selectedPoolFiles) {
        try {
          final sf = File(_poolPath + r'\' + fileName);
          if (await sf.exists()) {
            await sf.copy(_basePath + r'\' + tabletIp + r'\' + fileName);
            totalCopied++;
          }
        } catch (e) { errors.add(tabletIp + '/' + fileName); }
      }
    }
    setState(() => _sendingFiles = false);
    if (_selectedTablet != null) await _loadTabletDetails(_selectedTablet!);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(errors.isEmpty
            ? totalCopied.toString() + ' dosya ' + _selectedTargetTablets.length.toString() + ' tablete gonderildi'
            : totalCopied.toString() + ' dosya gonderildi. ' + errors.length.toString() + ' hata.'),
        backgroundColor: errors.isEmpty ? Colors.green : Colors.orange,
        duration: const Duration(seconds: 4),
      ));
    }
  }

  Future<void> _sendDeleteCommand(String fileName) async {
    if (_selectedTablet == null) return;
    final cf = File(_basePath + r'\' + _selectedTablet! + r'\_commands.json');
    Map<String, dynamic> data = {};
    if (await cf.exists()) {
      try { data = jsonDecode(await cf.readAsString()) as Map<String, dynamic>; } catch (_) {}
    }
    List<dynamic> silList = [];
    if (data.containsKey('sil') && data['sil'] is List) silList = List<dynamic>.from(data['sil']);
    if (!silList.contains(fileName)) silList.add(fileName);
    data['sil'] = silList;
    await cf.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    await _silentLoadTabletDetails(_selectedTablet!);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('"' + fileName + '" icin silme komutu gonderildi.'),
        backgroundColor: Colors.orange.shade800,
        duration: const Duration(seconds: 3),
      ));
    }
  }

  /// Bekliyor durumundaki dosyayi aninda siler.
  /// Optimistic UI + 10sn grace period: SMB gecikmesi olsa bile dosya geri gelmiyor.
  Future<void> _cancelPendingFile(String fileName) async {
    if (_selectedTablet == null) return;

    // 1) Aninda listeden cikar + grace period basla
    setState(() {
      _isCancelling = true;
      _recentlyCancelledFiles.add(fileName);
      _tabletFiles.removeWhere(
        (f) => f.uri.pathSegments.where((s) => s.isNotEmpty).last == fileName,
      );
    });

    // 2) 10 saniye sonra grace period'u kaldir
    Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _recentlyCancelledFiles.remove(fileName));
    });

    try {
      // 3) Diski sil
      final targetFile = File(_basePath + r'\' + _selectedTablet! + r'\' + fileName);
      if (await targetFile.exists()) await targetFile.delete();

      // 4) Flag'i kaldir - _silentLoadTabletDetails CAGIRMA
      setState(() => _isCancelling = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('"' + fileName + '" iptal edildi ve sunucudan silindi.'),
          backgroundColor: Colors.orange.shade700,
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      setState(() => _isCancelling = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Iptal edilemedi: ' + e.toString()),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ));
      }
    }
  }

  // === BUILD ===
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tablet Kiosk - Admin Paneli'),
        backgroundColor: Colors.deepPurple, foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'Yenile',
            onPressed: () { _scanTablets(); _loadPoolFiles(); _checkAllPings(); }),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              if (_message != null)
                Container(width: double.infinity, color: Colors.amber.shade100,
                  padding: const EdgeInsets.all(12),
                  child: Text(_message!, style: const TextStyle(color: Colors.black87))),
              Expanded(child: Row(children: [
                _buildLeftSidebar(),
                const VerticalDivider(width: 1),
                Expanded(child: _buildRightPanel()),
              ])),
            ]),
    );
  }

  // === SOL PANEL ===
  Widget _buildLeftSidebar() {
    final allSel = _tabletFolders.isNotEmpty && _selectedTargetTablets.length == _tabletFolders.length;
    final someSel = _selectedTargetTablets.isNotEmpty && !allSel;
    return Container(
      width: 280, color: Colors.grey.shade100,
      child: Column(children: [
        Container(width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: Colors.deepPurple.shade50,
          child: Text('Bagli Tabletler (' + _tabletFolders.length.toString() + ')',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.deepPurple))),
        if (_tabletFolders.isNotEmpty)
          Container(color: Colors.deepPurple.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(children: [
              Checkbox(tristate: true,
                value: allSel ? true : someSel ? null : false,
                onChanged: (_) => setState(() {
                  if (allSel) _selectedTargetTablets.clear();
                  else _selectedTargetTablets = Set.from(_tabletFolders);
                }), activeColor: Colors.deepPurple),
              Text(allSel ? 'Secimi Temizle'
                : someSel ? 'Tumunu Sec (' + _selectedTargetTablets.length.toString() + ' secili)' : 'Tumunu Sec',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.deepPurple.shade700)),
            ])),
        const Divider(height: 1),
        Expanded(child: _tabletFolders.isEmpty
          ? const Center(child: Padding(padding: EdgeInsets.all(16),
              child: Text('Henuz tablet bulunamadi.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey))))
          : ListView.builder(itemCount: _tabletFolders.length, itemBuilder: (ctx, i) {
              final t = _tabletFolders[i];
              final isSel = t == _selectedTablet;
              final isChk = _selectedTargetTablets.contains(t);
              final isOn = _onlineStatus[t] == true;
              return Material(color: Colors.transparent, child: InkWell(
                onTap: () { setState(() => _selectedTablet = t); _loadTabletDetails(t); },
                child: Container(
                  color: isSel ? Colors.deepPurple.shade100 : Colors.transparent,
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(children: [
                    Checkbox(value: isChk, activeColor: Colors.deepPurple,
                      onChanged: (v) => setState(() {
                        if (v == true) _selectedTargetTablets.add(t); else _selectedTargetTablets.remove(t);
                      })),
                    Icon(Icons.circle, size: 9, color: isOn ? Colors.green : Colors.grey.shade400),
                    const SizedBox(width: 6),
                    Icon(Icons.tablet_mac, size: 20, color: isSel ? Colors.deepPurple : Colors.grey.shade700),
                    const SizedBox(width: 8),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t, style: TextStyle(fontWeight: isSel ? FontWeight.bold : FontWeight.normal, fontSize: 14)),
                      Text(isOn ? 'Cevrimici' : 'Cevrimdisi',
                        style: TextStyle(fontSize: 11, color: isOn ? Colors.green.shade700 : Colors.grey)),
                    ])),
                  ]),
                ),
              ));
            })),
        if (_selectedTargetTablets.isNotEmpty)
          Container(width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.deepPurple.shade700,
            child: Text(_selectedTargetTablets.length.toString() + ' tablet secildi',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
              textAlign: TextAlign.center)),
      ]),
    );
  }

  // === SAG PANEL + HAVUZ ===
  Widget _buildRightPanel() {
    return Column(children: [
      _buildPoolSection(),
      const Divider(height: 1, thickness: 2, color: Colors.deepPurple),
      Expanded(child: _selectedTablet == null
        ? const Center(child: Text('Sol panelden bir tablet secin.', style: TextStyle(color: Colors.grey)))
        : _buildTabletDetailPanel()),
    ]);
  }

  Widget _buildPoolSection() {
    final allPoolSel = _poolFiles.isNotEmpty && _selectedPoolFiles.length == _poolFiles.length;
    final somePoolSel = _selectedPoolFiles.isNotEmpty && !allPoolSel;
    return Container(
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(color: Colors.indigo.shade50),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: Colors.indigo.shade700,
          child: Row(children: [
            const Icon(Icons.inventory_2, color: Colors.white, size: 20), const SizedBox(width: 8),
            const Expanded(child: Text('Dosya Havuzu',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15))),
            if (_poolFiles.isNotEmpty)
              TextButton.icon(
                onPressed: () => setState(() {
                  if (allPoolSel) _selectedPoolFiles.clear();
                  else _selectedPoolFiles = _poolFiles
                      .map((f) => f.uri.pathSegments.where((s) => s.isNotEmpty).last).toSet();
                }),
                icon: Icon(allPoolSel ? Icons.deselect : Icons.select_all, color: Colors.white, size: 18),
                label: Text(allPoolSel ? 'Secimi Temizle'
                  : somePoolSel ? _selectedPoolFiles.length.toString() + ' secili' : 'Tumunu Sec',
                  style: const TextStyle(color: Colors.white))),
            const SizedBox(width: 4),
            ElevatedButton.icon(onPressed: _addFilesToPool,
              icon: const Icon(Icons.add, size: 18), label: const Text('Havuza Ekle'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white,
                foregroundColor: Colors.indigo.shade700,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                textStyle: const TextStyle(fontSize: 13))),
          ])),
        Flexible(child: _poolFiles.isEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(20),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.inbox, size: 40, color: Colors.grey.shade400), const SizedBox(height: 8),
                Text('Havuz bos.', style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
              ])))
          : ListView.builder(shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              itemCount: _poolFiles.length,
              itemBuilder: (ctx, i) {
                final file = _poolFiles[i];
                final fileName = file.uri.pathSegments.where((s) => s.isNotEmpty).last;
                final isChk = _selectedPoolFiles.contains(fileName);
                return Card(margin: const EdgeInsets.symmetric(vertical: 3), elevation: 0,
                  color: isChk ? Colors.indigo.shade100 : Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: isChk ? Colors.indigo.shade300 : Colors.grey.shade200)),
                  child: ListTile(dense: true,
                    leading: Checkbox(value: isChk, activeColor: Colors.indigo,
                      onChanged: (v) => setState(() {
                        if (v == true) _selectedPoolFiles.add(fileName); else _selectedPoolFiles.remove(fileName);
                      })),
                    title: Text(fileName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    subtitle: FutureBuilder<FileStat>(
                      future: file.stat(),
                      builder: (ctx2, snap) {
                        if (!snap.hasData) return const SizedBox();
                        final size = snap.data!.size;
                        final str = size > 1024*1024
                          ? (size/(1024*1024)).toStringAsFixed(1) + ' MB'
                          : (size/1024).toStringAsFixed(0) + ' KB';
                        return Text(str, style: const TextStyle(fontSize: 11));
                      }),
                    trailing: IconButton(icon: const Icon(Icons.delete_outline, size: 20),
                      color: Colors.red.shade400, tooltip: 'Havuzdan sil',
                      onPressed: () => showDialog(context: context,
                        builder: (dlgCtx) => AlertDialog(
                          title: const Text('Havuzdan Sil'),
                          content: Text('"' + fileName + '" dosyasini silmek istediginize emin misiniz?'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(dlgCtx), child: const Text('Iptal')),
                            TextButton(onPressed: () { Navigator.pop(dlgCtx); _removeFromPool(fileName); },
                              child: Text('Sil', style: TextStyle(color: Colors.red.shade700))),
                          ])))));
              })),
        if (_poolFiles.isNotEmpty)
          Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.indigo.shade50,
            child: Row(children: [
              Text(_selectedPoolFiles.isEmpty ? 'Gondermek icin dosya secin'
                : _selectedPoolFiles.length.toString() + ' dosya -> ' +
                  (_selectedTargetTablets.isEmpty ? '(tablet secilmedi)' : _selectedTargetTablets.length.toString() + ' tablet'),
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
              const Spacer(),
              _sendingFiles
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : ElevatedButton.icon(
                    onPressed: _selectedPoolFiles.isNotEmpty && _selectedTargetTablets.isNotEmpty
                      ? _sendPoolFilesToTablets : null,
                    icon: const Icon(Icons.send, size: 18), label: const Text('Tabletlere Gonder'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo.shade600,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10))),
            ])),
      ]),
    );
  }

  // === TABLET DETAY PANELI ===
  Widget _buildTabletDetailPanel() {
    final isOnline = _onlineStatus[_selectedTablet] == true;
    return Column(children: [
      Container(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12), color: Colors.white,
        child: Row(children: [
          Icon(Icons.tablet_mac, size: 26, color: Colors.deepPurple.shade700), const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('Tablet: ' + (_selectedTablet ?? ''),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(width: 10),
              Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: isOnline ? Colors.green.shade100 : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(12)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.circle, size: 8, color: isOnline ? Colors.green.shade700 : Colors.grey.shade600),
                  const SizedBox(width: 4),
                  Text(isOnline ? 'Cevrimici' : 'Cevrimdisi',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
                      color: isOnline ? Colors.green.shade900 : Colors.grey.shade700)),
                ])),
            ]),
            Text(_basePath + r'\' + (_selectedTablet ?? ''),
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ]),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: () { _loadTabletDetails(_selectedTablet!); _checkAllPings(); },
            icon: const Icon(Icons.refresh, size: 18), label: const Text('Yenile')),
        ])),
      const Divider(height: 1),
      Expanded(child: _tabletFiles.isEmpty
        ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.folder_open, size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            const Text('Bu tablette henuz dosya yok.', style: TextStyle(fontSize: 15, color: Colors.grey)),
            const SizedBox(height: 8),
            Text('Yukardaki havuzdan dosya secip tableti isaretleyerek gonderin.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500), textAlign: TextAlign.center),
          ]))
        : ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _tabletFiles.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (ctx, i) {
              final file = _tabletFiles[i];
              final fileName = file.uri.pathSegments.where((s) => s.isNotEmpty).last;
              final statusEntry = _statusMap[fileName] as Map<String, dynamic>?;
              final isDownloaded = statusEntry != null && statusEntry['indirildi'] == true;
              final downloadTime = statusEntry?['indirilmeZamani']?.toString();
              final isPendingDelete = _pendingDeleteFiles.contains(fileName);
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  Icon(isDownloaded ? Icons.check_circle : Icons.hourglass_top,
                    color: isDownloaded ? Colors.green : Colors.orange, size: 26),
                  const SizedBox(width: 16),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(fileName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 4),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      if (isDownloaded) ...[
                        Text('Indirildi', style: TextStyle(color: Colors.green.shade800,
                          fontWeight: FontWeight.bold, fontSize: 12)),
                        if (downloadTime != null)
                          Text('(' + downloadTime + ')', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                      ] else
                        Text('Bekliyor', style: TextStyle(color: Colors.orange.shade800,
                          fontWeight: FontWeight.bold, fontSize: 12)),
                      if (isPendingDelete)
                        Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(color: Colors.amber.shade100, borderRadius: BorderRadius.circular(4)),
                          child: Text('Silme komutu gonderildi',
                            style: TextStyle(color: Colors.amber.shade900, fontSize: 11))),
                    ]),
                  ])),
                  if (isDownloaded)
                    ElevatedButton.icon(
                      onPressed: isPendingDelete ? null : () => _sendDeleteCommand(fileName),
                      icon: const Icon(Icons.delete, size: 16),
                      label: Text(isPendingDelete ? 'Silme Bekleniyor' : 'Sil'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade600,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        textStyle: const TextStyle(fontSize: 12)))
                  else
                    ElevatedButton.icon(
                      onPressed: () => _cancelPendingFile(fileName),
                      icon: const Icon(Icons.cancel_outlined, size: 16),
                      label: const Text('Iptal Et'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        textStyle: const TextStyle(fontSize: 12))),
                ]),
              );
            })),
    ]);
  }
}
