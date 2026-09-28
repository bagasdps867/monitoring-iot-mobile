import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart' as pw;
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MonitoringTambakApp());
}

// ==========================================
// WARNA & TEMA APLIKASI
// ==========================================
class AppColors {
  static const primary = Color(0xFF0B5FA5);
  static const primaryDark = Color(0xFF073D6B);
  static const background = Color(0xFFF2F5F8);
  static const cardShadow = Color(0x0D000000);
  static const safe = Color(0xFF1E9E6C);
  static const warning = Color(0xFFE07A1F);
  static const danger = Color(0xFFD64545);
  static const textMuted = Color(0xFF7C8A99);
  static const textDark = Color(0xFF1F2A37);

  static const ph = Color(0xFF0284C7);
  static const suhu = Color(0xFF16A34A);
  static const tds = Color(0xFF00ACC1);
  static const kekeruhan = Color(0xFF9333EA);

  static const phBg = Color(0xFFE0F2FE);
  static const suhuBg = Color(0xFFDCFCE7);
  static const tdsBg = Color(0xFFE0F7FA);
  static const kekeruhanBg = Color(0xFFF3E8FF);
}

// ==========================================
// MODEL SENSOR & STATUS LEVEL
// ==========================================
enum SensorLevel { unknown, safe, warning }

class SensorDef {
  final String key;
  final String label;
  final String unit;
  final String unitNote;
  final IconData icon;
  final Color color;
  final Color iconBg;
  final double physicalMin;
  final double physicalMax;
  final int decimals;

  const SensorDef({
    required this.key,
    required this.label,
    required this.unit,
    required this.unitNote,
    required this.icon,
    required this.color,
    required this.iconBg,
    required this.physicalMin,
    required this.physicalMax,
    this.decimals = 0,
  });
}

class RecordItem {
  final DateTime time;
  final double ph;
  final double suhu;
  final double tds;
  final double kekeruhan;
  final String kualitas;
  final String status;

  RecordItem({
    required this.time,
    required this.ph,
    required this.suhu,
    required this.tds,
    required this.kekeruhan,
    required this.kualitas,
    required this.status,
  });
}

const List<SensorDef> kSensorDefs = [
  SensorDef(
    key: 'ph',
    label: 'pH',
    unit: 'pH',
    unitNote: 'Tingkat keasaman air',
    icon: Icons.water_drop_rounded,
    color: AppColors.ph,
    iconBg: AppColors.phBg,
    physicalMin: 0,
    physicalMax: 14,
    decimals: 1,
  ),
  SensorDef(
    key: 'suhu',
    label: 'Suhu',
    unit: '°C',
    unitNote: 'Temperatur air tambak',
    icon: Icons.thermostat_rounded,
    color: AppColors.suhu,
    iconBg: AppColors.suhuBg,
    physicalMin: 0,
    physicalMax: 50,
    decimals: 1,
  ),
  SensorDef(
    key: 'tds',
    label: 'TDS',
    unit: 'ppm',
    unitNote: 'Total padatan terlarut',
    icon: Icons.adjust_rounded,
    color: AppColors.tds,
    iconBg: AppColors.tdsBg,
    physicalMin: 0,
    physicalMax: 5000,
    decimals: 0,
  ),
  SensorDef(
    key: 'kekeruhan',
    label: 'Kekeruhan',
    unit: 'NTU',
    unitNote: 'Tingkat kekeruhan air',
    icon: Icons.waves_rounded,
    color: AppColors.kekeruhan,
    iconBg: AppColors.kekeruhanBg,
    physicalMin: 0,
    physicalMax: 3000,
    decimals: 1,
  ),
];

SensorDef sensorDefFor(String key) =>
    kSensorDefs.firstWhere((s) => s.key == key);

// ==========================================
// NOTIFIKASI LOKAL
// ==========================================
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static final Map<String, DateTime> _lastNotified = {};
  static const _cooldown = Duration(minutes: 5);

  static const _channel = AndroidNotificationChannel(
    'tambak_warning_channel_v2S',
    'Peringatan Sensor Tambak',
    description: 'Notifikasi saat kualitas air keluar dari ambang batas',
    importance: Importance.max,
    playSound: true,
  );

  static Future<void> init() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(initSettings);

    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(_channel);
    if (Platform.isAndroid) {
      await androidImpl?.requestNotificationsPermission();
    }
  }

  static Future<void> notifyIfDue({
    required String sensorKey,
    required String sensorLabel,
    required String value,
    required String unit,
    required bool tooLow,
  }) async {
    final now = DateTime.now();
    final last = _lastNotified[sensorKey];
    if (last != null && now.difference(last) < _cooldown) return;
    _lastNotified[sensorKey] = now;

    try {
      final player = AudioPlayer();
      await player.play(AssetSource('alarm_tet.wav'));
    } catch (e) {
      debugPrint('Error playing audio: $e');
    }

    final arah = tooLow ? 'terlalu rendah' : 'terlalu tinggi';
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channel.id,
        _channel.name,
        channelDescription: _channel.description,
        importance: Importance.max,
        priority: Priority.high,
        playSound: false,
      ),
    );
    await _plugin.show(
      sensorKey.hashCode,
      '⚠️ $sensorLabel $arah',
      '$sensorLabel saat ini $value $unit, di luar ambang batas normal.',
      details,
    );
  }
}

// ==========================================
// MODEL AMBANG BATAS
// ==========================================
class Thresholds {
  final double suhuMin, suhuMax;
  final double kekeruhanMin, kekeruhanMax;
  final double tdsMin, tdsMax;
  final double phMin, phMax;

  const Thresholds({
    this.suhuMin = 26,
    this.suhuMax = 32,
    this.kekeruhanMin = 0,
    this.kekeruhanMax = 50,
    this.tdsMin = 0,
    this.tdsMax = 3000,
    this.phMin = 6.5,
    this.phMax = 8.5,
  });

  double minFor(String key) => switch (key) {
        'suhu' => suhuMin,
        'kekeruhan' => kekeruhanMin,
        'tds' => tdsMin,
        'ph' => phMin,
        _ => 0,
      };

  double maxFor(String key) => switch (key) {
        'suhu' => suhuMax,
        'kekeruhan' => kekeruhanMax,
        'tds' => tdsMax,
        'ph' => phMax,
        _ => 0,
      };

  Map<String, dynamic> toJson() => {
        'suhu': {'min': suhuMin, 'max': suhuMax},
        'kekeruhan': {'min': kekeruhanMin, 'max': kekeruhanMax},
        'tds': {'min': tdsMin, 'max': tdsMax},
        'ph': {'min': phMin, 'max': phMax},
      };

  static Thresholds fromJson(
    Map<String, dynamic> json, {
    required Thresholds fallback,
  }) {
    double pick(String group, String key, double fallbackVal) {
      final g = json[group];
      if (g is Map && g[key] is num) return (g[key] as num).toDouble();
      return fallbackVal;
    }

    return Thresholds(
      suhuMin: pick('suhu', 'min', fallback.suhuMin),
      suhuMax: pick('suhu', 'max', fallback.suhuMax),
      kekeruhanMin: pick('kekeruhan', 'min', fallback.kekeruhanMin),
      kekeruhanMax: pick('kekeruhan', 'max', fallback.kekeruhanMax),
      tdsMin: pick('tds', 'min', fallback.tdsMin),
      tdsMax: pick('tds', 'max', fallback.tdsMax),
      phMin: pick('ph', 'min', fallback.phMin),
      phMax: pick('ph', 'max', fallback.phMax),
    );
  }
}

class MonitoringTambakApp extends StatelessWidget {
  const MonitoringTambakApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AQUATOR Mobile',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.black87),
        ),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: AppColors.primary,
          selectedItemColor: Colors.white,
          unselectedItemColor: Colors.white60,
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.white),
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

// ==========================================
// 1. SPLASH SCREEN
// ==========================================
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);

    NotificationService.init();

    Timer(const Duration(seconds: 2, milliseconds: 400), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const DashboardScreen()),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.primaryDark, AppColors.primary],
          ),
        ),
        child: Center(
          child: FadeTransition(
            opacity: _fade,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.water_drop_rounded,
                    size: 64,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'AQUATOR',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 3,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Monitoring Kualitas Air Tambak Presisi',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.75),
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 40),
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 2. DASHBOARD SCREEN
// ==========================================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

enum MqttUiStatus { connecting, connected, failed, disconnected }

class _DashboardScreenState extends State<DashboardScreen> {
  int _currentIndex = 0;
  bool isDarkMode = false;
  bool _isLoadingRecords = false;

  List<RecordItem> _records = [];

  Future<void> _fetchRecordsFromDatabase() async {
    setState(() => _isLoadingRecords = true);
    try {
      final url = Uri.parse('http://172.14.5.252:8000/api/laporan');
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final decodedData = jsonDecode(response.body);
        final List<dynamic> jsonList =
            (decodedData is Map && decodedData.containsKey('data'))
                ? decodedData['data']
                : decodedData;

        setState(() {
          _records = jsonList.map((item) {
            return RecordItem(
              time: DateTime.tryParse(item['waktu']?.toString() ?? '') ??
                  DateTime.now(),
              ph: double.tryParse(item['ph']?.toString() ?? '0') ?? 0.0,
              suhu: double.tryParse(item['suhu']?.toString() ?? '0') ?? 0.0,
              tds: double.tryParse(item['tds']?.toString() ?? '0') ?? 0.0,
              kekeruhan:
                  double.tryParse(item['kekeruhan']?.toString() ?? '0') ?? 0.0,
              kualitas: item['kualitas']?.toString() ?? 'Baik',
              status: item['status']?.toString() ?? 'Normal',
            );
          }).toList();
        });
      }
    } catch (e) {
      // Jika masih ada yang gagal, error-nya akan muncul di Debug Console
      print('GAGAL MEMBACA DATA JSON: $e');
    } finally {
      if (mounted) setState(() => _isLoadingRecords = false);
    }
  }

  Future<void> _fetchThresholds() async {
    try {
      // Pastikan URL dan port sesuai dengan server Laravel Anda
      final url = Uri.parse('http://172.14.5.252:8000/api/get-ambang-batas');
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (mounted) {
          setState(() {
            // Menimpa variabel lokal dengan data dari database web
            thresholds = Thresholds(
              phMin: double.tryParse(data['ph_min'].toString()) ?? 6.5,
              phMax: double.tryParse(data['ph_max'].toString()) ?? 8.5,
              suhuMin: double.tryParse(data['suhu_min'].toString()) ?? 26.0,
              suhuMax: double.tryParse(data['suhu_max'].toString()) ?? 32.0,
              tdsMin: double.tryParse(data['tds_min'].toString()) ?? 0.0,
              tdsMax: double.tryParse(data['tds_max'].toString()) ?? 3000.0,
              kekeruhanMin:
                  double.tryParse(data['kekeruhan_min'].toString()) ?? 0.0,
              kekeruhanMax:
                  double.tryParse(data['kekeruhan_max'].toString()) ?? 50.0,
            );
          });
        }
      }
    } catch (e) {
      print('Gagal sinkronisasi ambang batas dari web: $e');
    }
  }

  void _changeTab(int index) {
    if (index == 1) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }

    setState(() {
      _currentIndex = index;
    });
  }

  final Map<String, String> _values = {
    'ph': '7.4',
    'suhu': '29.2',
    'tds': '271',
    'kekeruhan': '18.0',
  };

  String _tempFilterStatus = 'Semua';
  DateTime? _tempFilterStartDate;
  DateTime? _tempFilterEndDate;

  String _filterStatus = 'Semua';
  DateTime? _filterStartDate;
  DateTime? _filterEndDate;

  Timer? _thirtyMinTimer;

  Thresholds thresholds = const Thresholds();
  String _chartSensor = 'ph';
  String _chartRange = '1 Hari';

  MqttUiStatus status = MqttUiStatus.connecting;
  DateTime? lastUpdate;
  MqttServerClient? client;

  static const String _server =
      '06728a35d0df40e19b687ec782f7a625.s1.eu.hivemq.cloud';
  static const int _port = 8883;
  static const String _mqttUser = 'kalisogo_iot';
  static const String _mqttPass = 'Kalisogo123!';
  static const String _topicConfig = 'tambak/kalisogo/config';

  bool _isAiLoading = false;
  String? _aiRecommendation;

  @override
  void initState() {
    super.initState();
    _connect();
    _fetchRecordsFromDatabase();
    _fetchThresholds();
    _thirtyMinTimer = Timer.periodic(const Duration(minutes: 30), (timer) {
      _recordRealtimeData();
    });
  }

  // ==========================================
  // FUNGSI EKSPOR EXCEL
  // ==========================================
  Future<void> _exportToExcel(List<RecordItem> dataToExport) async {
    try {
      var status = await Permission.storage.request();
      if (!status.isGranted) {
        await Permission.manageExternalStorage.request();
      }

      var excel = Excel.createExcel();
      Sheet sheetObject = excel['Laporan Tambak'];

      sheetObject.appendRow([
        TextCellValue('Tanggal & Waktu'),
        TextCellValue('pH'),
        TextCellValue('Suhu (°C)'),
        TextCellValue('TDS (ppm)'),
        TextCellValue('Kekeruhan (NTU)'),
        TextCellValue('Kualitas Air'),
        TextCellValue('Status'),
      ]);

      for (var r in dataToExport) {
        sheetObject.appendRow([
          TextCellValue(
            '${r.time.day}/${r.time.month}/${r.time.year} ${r.time.hour.toString().padLeft(2, '0')}:${r.time.minute.toString().padLeft(2, '0')}',
          ),
          TextCellValue(r.ph.toStringAsFixed(1)),
          TextCellValue(r.suhu.toStringAsFixed(1)),
          TextCellValue(r.tds.toStringAsFixed(0)),
          TextCellValue(r.kekeruhan.toStringAsFixed(1)),
          TextCellValue(r.kualitas),
          TextCellValue(r.status),
        ]);
      }

      var fileBytes = excel.save();

      final now = DateTime.now();
      final dateStr =
          '${now.day.toString().padLeft(2, '0')}-${now.month.toString().padLeft(2, '0')}-${now.year}';

      Directory? directory = Directory('/storage/emulated/0/Download');
      if (!await directory.exists()) {
        directory = await getExternalStorageDirectory();
      }

      final filePath =
          '${directory!.path}/Laporan Tambak Aquator $dateStr.xlsx';
      final file = File(filePath);
      await file.create(recursive: true);
      await file.writeAsBytes(fileBytes!);

      await Share.shareXFiles([XFile(filePath)],
          text: 'Laporan Kualitas Air Tambak (Excel)');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Excel disimpan & dibagikan: Laporan Tambak Aquator $dateStr.xlsx')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal export Excel: $e')),
        );
      }
    }
  }

  // ==========================================
  // FUNGSI EKSPOR PDF
  // ==========================================
  Future<void> _exportToPdf(List<RecordItem> dataToExport) async {
    try {
      final pdf = pw.Document();

      final now = DateTime.now();
      final dateStr =
          '${now.day}/${now.month}/${now.year}, ${now.hour.toString().padLeft(2, '0')}.${now.minute.toString().padLeft(2, '0')}.${now.second.toString().padLeft(2, '0')}';
      final fileDateStr =
          '${now.day.toString().padLeft(2, '0')}-${now.month.toString().padLeft(2, '0')}-${now.year}';

      pdf.addPage(
        pw.MultiPage(
          pageFormat: pw.PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (pw.Context context) => [
            pw.Text(
              'AQUATOR - Laporan Kualitas Air',
              style: pw.TextStyle(
                fontSize: 18,
                fontWeight: pw.FontWeight.bold,
                color: const pw.PdfColor.fromInt(0xFF0B5FA5),
              ),
            ),
            pw.SizedBox(height: 6),
            pw.Text(
              'Dicetak: $dateStr | Menampilkan total ${dataToExport.length} data monitoring',
              style: const pw.TextStyle(
                fontSize: 10,
                color: pw.PdfColor.fromInt(0xFF7C8A99),
              ),
            ),
            pw.SizedBox(height: 14),
            pw.Table.fromTextArray(
              headers: [
                'Tanggal & Waktu',
                'pH',
                'Suhu (°C)',
                'TDS (ppm)',
                'Kekeruhan (NTU)',
                'Kualitas Air',
                'Status'
              ],
              data: dataToExport.map((r) {
                return [
                  '${r.time.day}/${r.time.month}/${r.time.year} ${r.time.hour.toString().padLeft(2, '0')}:${r.time.minute.toString().padLeft(2, '0')}',
                  r.ph.toStringAsFixed(1),
                  '${r.suhu.toStringAsFixed(1)}°C',
                  r.tds.toStringAsFixed(0),
                  r.kekeruhan.toStringAsFixed(1),
                  r.kualitas,
                  r.status,
                ];
              }).toList(),
              columnWidths: {
                0: const pw.FlexColumnWidth(2.2),
                1: const pw.FlexColumnWidth(0.9),
                2: const pw.FlexColumnWidth(1.2),
                3: const pw.FlexColumnWidth(1.2),
                4: const pw.FlexColumnWidth(1.5),
                5: const pw.FlexColumnWidth(1.2),
                6: const pw.FlexColumnWidth(1.1),
              },
              headerStyle: pw.TextStyle(
                fontSize: 10.5,
                fontWeight: pw.FontWeight.bold,
                color: const pw.PdfColor.fromInt(0xFF0F172A),
              ),
              headerDecoration: const pw.BoxDecoration(
                color: pw.PdfColor.fromInt(0xFFCCECE6),
              ),
              border: pw.TableBorder.all(
                color: pw.PdfColor.fromInt(0xFFE2E8F0),
                width: 0.6,
              ),
              cellStyle: const pw.TextStyle(
                fontSize: 10,
                color: pw.PdfColor.fromInt(0xFF1E293B),
              ),
              cellAlignment: pw.Alignment.centerLeft,
              cellPadding:
                  const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
          ],
        ),
      );

      Directory? directory = Directory('/storage/emulated/0/Download');
      if (!await directory.exists()) {
        directory = await getExternalStorageDirectory();
      }

      final filePath =
          '${directory!.path}/Laporan Tambak Aquator $fileDateStr.pdf';
      final file = File(filePath);
      await file.writeAsBytes(await pdf.save());

      await Share.shareXFiles([XFile(filePath)],
          text: 'Laporan Kualitas Air Tambak (PDF)');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'PDF berhasil disimpan ke Download: Laporan Tambak Aquator $fileDateStr.pdf')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal export PDF: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _thirtyMinTimer?.cancel();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    client?.disconnect();
    super.dispose();
  }

  void _recordRealtimeData() {
    final phVal = double.tryParse(_values['ph'] ?? '7.0') ?? 7.0;
    final suhuVal = double.tryParse(_values['suhu'] ?? '28.0') ?? 28.0;
    final tdsVal = double.tryParse(_values['tds'] ?? '250') ?? 250.0;
    final kekVal = double.tryParse(_values['kekeruhan'] ?? '15.0') ?? 15.0;

    setState(() {
      _records.insert(
        0,
        RecordItem(
          time: DateTime.now(),
          ph: phVal,
          suhu: suhuVal,
          tds: tdsVal,
          kekeruhan: kekVal,
          kualitas: 'Cukup',
          status: 'Warning',
        ),
      );
    });
  }

  Future<void> _connect() async {
    setState(() => status = MqttUiStatus.connecting);

    final String clientId =
        'flutter_client_${DateTime.now().millisecondsSinceEpoch}';

    final c = MqttServerClient.withPort(_server, clientId, _port);
    c.secure = true;
    c.useWebSocket = false;
    c.keepAlivePeriod = 20;
    c.autoReconnect = true;
    c.onDisconnected = _onDisconnected;
    c.logging(on: false);
    c.setProtocolV311();

    c.securityContext = SecurityContext.defaultContext;
    c.onBadCertificate = (dynamic cert) => true;

    c.connectionMessage = MqttConnectMessage()
        .authenticateAs(_mqttUser, _mqttPass)
        .withClientIdentifier(clientId)
        .startClean();

    client = c;

    try {
      await c.connect();
    } catch (e) {
      c.disconnect();
    }

    if (!mounted) return;

    if (c.connectionStatus?.state == MqttConnectionState.connected) {
      setState(() => status = MqttUiStatus.connected);

      c.subscribe('tambak/kalisogo/suhu', MqttQos.atMostOnce);
      c.subscribe('tambak/kalisogo/kekeruhan', MqttQos.atMostOnce);
      c.subscribe('tambak/kalisogo/tds', MqttQos.atMostOnce);
      c.subscribe('tambak/kalisogo/ph', MqttQos.atMostOnce);
      c.subscribe(_topicConfig, MqttQos.atLeastOnce);

      c.updates!.listen(_onMessage);
    } else {
      setState(() => status = MqttUiStatus.failed);
    }
  }

  void _onDisconnected() {
    if (!mounted) return;
    setState(() => status = MqttUiStatus.disconnected);
  }

  void _onMessage(List<MqttReceivedMessage<MqttMessage>> event) {
    final MqttPublishMessage recMess = event[0].payload as MqttPublishMessage;
    final String payload = MqttPublishPayload.bytesToStringAsString(
      recMess.payload.message,
    );
    final String topic = event[0].topic;

    if (topic == _topicConfig) {
      try {
        final decoded = jsonDecode(payload) as Map<String, dynamic>;
        if (!mounted) return;
        setState(() {
          thresholds = Thresholds.fromJson(decoded, fallback: thresholds);
        });
      } catch (e) {
        debugPrint('Gagal parse config: $e');
      }
      return;
    }

    final key = topic.split('/').last;
    if (!_values.containsKey(key)) return;

    if (!mounted) return;
    setState(() {
      lastUpdate = DateTime.now();
      _values[key] = payload;
    });

    _checkAndNotify(key, payload);
  }

  Future<void> _publishThresholds(Thresholds t) async {
    final c = client;
    if (c == null ||
        c.connectionStatus?.state != MqttConnectionState.connected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Tidak terhubung ke broker — pengaturan belum bisa dikirim',
            ),
            backgroundColor: AppColors.danger,
          ),
        );
      }
      return;
    }

    final payload = jsonEncode(t.toJson());
    final builder = MqttClientPayloadBuilder();
    builder.addString(payload);

    c.publishMessage(
      _topicConfig,
      MqttQos.atLeastOnce,
      builder.payload!,
      retain: true,
    );

    if (mounted) setState(() => thresholds = t);
  }

  void _sendRcCommand(String command) {
    final c = client;
    if (c == null ||
        c.connectionStatus?.state != MqttConnectionState.connected) {
      return;
    }

    final builder = MqttClientPayloadBuilder();
    builder.addString(command);
    c.publishMessage(
      'tambak/kalisogo/rc',
      MqttQos.atMostOnce,
      builder.payload!,
    );
  }

  void _checkAndNotify(String key, String rawValue) {
    final n = double.tryParse(rawValue);
    if (n == null) return;

    final min = thresholds.minFor(key);
    final max = thresholds.maxFor(key);
    if (n < min || n > max) {
      final def = sensorDefFor(key);
      NotificationService.notifyIfDue(
        sensorKey: key,
        sensorLabel: def.label,
        value: rawValue,
        unit: def.unit,
        tooLow: n < min,
      );
    }
  }

  SensorLevel _levelFor(String key) {
    final n = double.tryParse(_values[key] ?? '');
    if (n == null) return SensorLevel.unknown;
    final min = thresholds.minFor(key);
    final max = thresholds.maxFor(key);
    return (n < min || n > max) ? SensorLevel.warning : SensorLevel.safe;
  }

  Map<String, dynamic> _calculateWaterQuality() {
    double score = 100;
    int abnormalCount = 0;

    for (final def in kSensorDefs) {
      final lvl = _levelFor(def.key);
      if (lvl == SensorLevel.warning) {
        score -= 22.5;
        abnormalCount++;
      }
    }

    score = score.clamp(15.0, 100.0);

    String status = 'Normal';
    String conditionText = 'BAIK';
    Color color = AppColors.safe;
    String summary = 'Semua parameter berada dalam kondisi aman.';

    if (score < 55 || abnormalCount >= 2) {
      status = 'Critical';
      conditionText = 'BURUK';
      color = AppColors.danger;
      summary =
          '$abnormalCount parameter membutuhkan tindakan penanganan segera!';
    } else if (score < 80 || abnormalCount == 1) {
      status = 'Warning';
      conditionText = 'CUKUP';
      color = AppColors.warning;
      summary =
          'Kualitas air cukup stabil, pantau parameter yang mengalami deviasi.';
    }

    return {
      'score': score,
      'status': status,
      'conditionText': conditionText,
      'color': color,
      'summary': summary,
    };
  }

  Future<void> _fetchAiRecommendation() async {
    if (_values['ph'] == '--' || _values['suhu'] == '--') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Menunggu data sensor masuk sebelum meminta analisis ML.'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    setState(() => _isAiLoading = true);

    try {
      final url = Uri.parse('http://172.14.5.252:8000/api/ai-rekomendasi');

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'ph': _values['ph'],
          'suhu': _values['suhu'],
          'tds': _values['tds'],
          'kekeruhan': _values['kekeruhan'],
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        print('ISI DATA API AI: ${response.body}');
        final Map<String, dynamic> data = jsonDecode(response.body);

        // Ambil langsung teks rekomendasinya
        final hasilAsli = data['rekomendasi'] ??
            data['data'] ??
            data['hasil'] ??
            response.body;

        setState(() {
          _aiRecommendation = hasilAsli.toString();
        });
      }
    } catch (e) {
      setState(() {
        _aiRecommendation =
            'Gagal menghubungi server web backend. Pastikan Laragon menyala.';
      });
    } finally {
      if (mounted) setState(() => _isAiLoading = false);
    }
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          initial: thresholds,
          onSave: _publishThresholds,
          isDarkMode: isDarkMode,
        ),
      ),
    );
  }

  Widget _buildAiResponseContent(String rawText) {
    if (rawText.startsWith('Peringatan') || rawText.startsWith('Gagal')) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.danger.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.danger.withOpacity(0.3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 20,
              color: AppColors.danger,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                rawText,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.danger,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final clean = rawText.replaceAll('**', '').replaceAll('*', '').trim();
    final lines = clean
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    String summary = '';
    final List<String> steps = [];

    for (final line in lines) {
      if (RegExp(r'^(1\.|2\.|3\.|4\.|5\.|6\.|-|\u2022)').hasMatch(line)) {
        steps.add(line.replaceFirst(
            RegExp(r'^(1\.|2\.|3\.|4\.|5\.|6\.|-|\u2022)\s*'), ''));
      } else if (line.toUpperCase().startsWith('EVALUASI:')) {
        summary = line.substring(9).trim();
      } else if (!line.toLowerCase().contains('langkah aksi') &&
          !line.toLowerCase().contains('langkah penanganan') &&
          !line.toLowerCase().contains('aksi cepat')) {
        summary = summary.isEmpty ? line : '$summary $line';
      }
    }

    if (summary.isEmpty && steps.isNotEmpty) {
      summary = 'Hasil diagnosis & analisis kualitas air tambak:';
    } else if (summary.isEmpty && steps.isEmpty) {
      summary = clean;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.check_circle_outline_rounded,
                size: 20,
                color: Color(0xFF059669),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  summary,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFF334155),
                    height: 1.45,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (steps.isNotEmpty) ...[
          const SizedBox(height: 16),
          ...List.generate(steps.length, (index) {
            final item = steps[index];
            final splitIdx = item.indexOf(':');
            final title = 'Langkah Tindakan ${index + 1}';
            final desc =
                splitIdx != -1 ? item.substring(splitIdx + 1).trim() : item;

            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE2E8F0)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x08000000),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 5,
                      decoration: const BoxDecoration(
                        color: Color(0xFF3B82F6),
                        borderRadius:
                            BorderRadius.horizontal(left: Radius.circular(10)),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(14.0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFEFF6FF),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(
                                    Icons.assignment_turned_in_rounded,
                                    color: Color(0xFF3B82F6),
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '#${index + 1}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFEFF6FF),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          'SOP ACTION',
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w800,
                                            color: Color(0xFF3B82F6),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF0F172A),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    desc,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF475569),
                                      height: 1.45,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final quality = _calculateWaterQuality();

    final dashboardWidget = Scaffold(
      backgroundColor:
          isDarkMode ? const Color(0xFF0F172A) : AppColors.background,
      body: CustomScrollView(
        slivers: [
          _buildAppBar(context),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildStatusBanner(),
                const SizedBox(height: 16),
                _buildWaterQualityCard(quality),
                const SizedBox(height: 22),
                _sectionTitle('Parameter Air'),
                const SizedBox(height: 2),
                Text(
                  lastUpdate == null
                      ? 'Menunggu data pertama dari sensor...'
                      : 'Update terakhir: ${_formatTime(lastUpdate!)}',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 14),
                Column(
                  children: kSensorDefs
                      .map(
                        (def) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _buildSensorCard(def),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 10),
                _buildAiRecommendationCard(),
                const SizedBox(height: 24),
                _sectionTitle('Tren Analitik'),
                const SizedBox(height: 2),
                const Text(
                  'Pergerakan parameter air (Realtime tercatat otomatis tiap 30 menit)',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
                ),
                const SizedBox(height: 12),
                _buildTrendCard(),
                const SizedBox(height: 16),
              ]),
            ),
          ),
        ],
      ),
    );

    final rcWidget = Scaffold(
      backgroundColor:
          isDarkMode ? const Color(0xFF0B132B) : const Color(0xFF1E293B),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => _changeTab(0),
        ),
        title: const Row(
          children: [
            Icon(Icons.sports_esports_rounded, color: Colors.white, size: 22),
            SizedBox(width: 10),
            Text(
              'Remote Analog PS - Perahu Tambak',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
                fontSize: 16,
              ),
            ),
          ],
        ),
        backgroundColor: AppColors.primary,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'ANALOG KIRI (GAS)',
                    style: TextStyle(
                      color: Colors.white60,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: 175,
                    height: 175,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withOpacity(0.3),
                      border: Border.all(color: Colors.white24, width: 3),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned(
                          top: 12,
                          child: GestureDetector(
                            onTap: () => _sendRcCommand('MAJU'),
                            child: Container(
                              width: 55,
                              height: 55,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.primary,
                              ),
                              child: const Icon(
                                Icons.arrow_upward_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 12,
                          child: GestureDetector(
                            onTap: () => _sendRcCommand('MUNDUR'),
                            child: Container(
                              width: 55,
                              height: 55,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.primary,
                              ),
                              child: const Icon(
                                Icons.arrow_downward_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: () => _sendRcCommand('STOP'),
                    style: ElevatedButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(26),
                      backgroundColor: AppColors.danger,
                      foregroundColor: Colors.white,
                      elevation: 8,
                    ),
                    child: const Text(
                      'STOP',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'ANALOG KANAN (BELOK)',
                    style: TextStyle(
                      color: Colors.white60,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: 175,
                    height: 175,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withOpacity(0.3),
                      border: Border.all(color: Colors.white24, width: 3),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned(
                          left: 12,
                          child: GestureDetector(
                            onTap: () => _sendRcCommand('KIRI'),
                            child: Container(
                              width: 55,
                              height: 55,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.primary,
                              ),
                              child: const Icon(
                                Icons.arrow_back_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 12,
                          child: GestureDetector(
                            onTap: () => _sendRcCommand('KANAN'),
                            child: Container(
                              width: 55,
                              height: 55,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.primary,
                              ),
                              child: const Icon(
                                Icons.arrow_forward_rounded,
                                size: 28,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    List<RecordItem> filteredRecords = _records.where((item) {
      if (_filterStatus != 'Semua' && item.status != _filterStatus) {
        return false;
      }
      if (_filterStartDate != null) {
        final start = DateTime(
          _filterStartDate!.year,
          _filterStartDate!.month,
          _filterStartDate!.day,
        );
        final itemDate = DateTime(
          item.time.year,
          item.time.month,
          item.time.day,
        );
        if (itemDate.isBefore(start)) return false;
      }
      if (_filterEndDate != null) {
        final end = DateTime(
          _filterEndDate!.year,
          _filterEndDate!.month,
          _filterEndDate!.day,
        );
        final itemDate = DateTime(
          item.time.year,
          item.time.month,
          item.time.day,
        );
        if (itemDate.isAfter(end)) return false;
      }
      return true;
    }).toList();

    filteredRecords.sort((a, b) => b.time.compareTo(a.time));

    final laporanWidget = Scaffold(
      backgroundColor:
          isDarkMode ? const Color(0xFF0F172A) : AppColors.background,
      appBar: AppBar(
        title: const Text(
          'Laporan Kualitas Air',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: AppColors.primary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Pantau dan analisis data kualitas air yang direkam otomatis setiap 30 menit.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 2,
              ),
              onPressed: () {
                showModalBottomSheet(
                  context: context,
                  backgroundColor:
                      isDarkMode ? const Color(0xFF1E293B) : Colors.white,
                  shape: const RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  builder: (context) {
                    return Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Pilih Format Ekspor Laporan',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: isDarkMode ? Colors.white : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 15),
                          ListTile(
                            leading: const Icon(Icons.table_chart_rounded,
                                color: Colors.green),
                            title: Text(
                              'Ekspor sebagai Excel (.xlsx)',
                              style: TextStyle(
                                  color: isDarkMode
                                      ? Colors.white70
                                      : Colors.black87),
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              _exportToExcel(filteredRecords);
                            },
                          ),
                          ListTile(
                            leading: const Icon(Icons.picture_as_pdf_rounded,
                                color: Colors.red),
                            title: Text(
                              'Ekspor sebagai PDF (.pdf)',
                              style: TextStyle(
                                  color: isDarkMode
                                      ? Colors.white70
                                      : Colors.black87),
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              _exportToPdf(filteredRecords);
                            },
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
              icon: const Icon(Icons.download_rounded),
              label: const Text(
                'Export Laporan (Excel / PDF)',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 16),
          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.45,
            children: [
              _buildReportCard(
                'TOTAL DATA',
                _records.length.toString(),
                'Tercatat otomatis',
                Icons.analytics_rounded,
                AppColors.primary,
              ),
              _buildReportCard(
                'RATA-RATA pH',
                _records.isEmpty
                    ? '0'
                    : (_records.map((e) => e.ph).reduce((a, b) => a + b) /
                            _records.length)
                        .toStringAsFixed(1),
                'Rata-rata keseluruhan',
                Icons.science_rounded,
                AppColors.ph,
              ),
              _buildReportCard(
                'RATA-RATA SUHU',
                _records.isEmpty
                    ? '0'
                    : '${(_records.map((e) => e.suhu).reduce((a, b) => a + b) / _records.length).toStringAsFixed(1)}°C',
                'Rata-rata keseluruhan',
                Icons.thermostat_rounded,
                AppColors.suhu,
              ),
              _buildReportCard(
                'RATA-RATA TDS',
                _records.isEmpty
                    ? '0'
                    : '${(_records.map((e) => e.tds).reduce((a, b) => a + b) / _records.length).toStringAsFixed(0)} ppm',
                'Rata-rata keseluruhan',
                Icons.adjust_rounded,
                AppColors.tds,
              ),
              _buildReportCard(
                'RATA-RATA KEKERUHAN',
                _records.isEmpty
                    ? '0'
                    : '${(_records.map((e) => e.kekeruhan).reduce((a, b) => a + b) / _records.length).toStringAsFixed(1)} NTU',
                'Rata-rata keseluruhan',
                Icons.waves_rounded,
                AppColors.kekeruhan,
              ),
              _buildReportCard(
                'STATUS SISTEM',
                'Aktif',
                'Realtime tiap 30 menit',
                Icons.check_circle_rounded,
                AppColors.safe,
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDarkMode ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [
                BoxShadow(color: Colors.black12, blurRadius: 4),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'FILTER DATA',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now(),
                            firstDate: DateTime(2025),
                            lastDate: DateTime(2030),
                          );
                          if (picked != null) {
                            setState(() => _tempFilterStartDate = picked);
                          }
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Dari Tanggal',
                            border: const OutlineInputBorder(),
                            labelStyle: TextStyle(
                              color:
                                  isDarkMode ? Colors.white70 : Colors.black87,
                            ),
                          ),
                          child: Text(
                            _tempFilterStartDate == null
                                ? 'dd/mm/yyyy'
                                : '${_tempFilterStartDate!.day}/${_tempFilterStartDate!.month}/${_tempFilterStartDate!.year}',
                            style: TextStyle(
                              color: isDarkMode ? Colors.white : Colors.black87,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now(),
                            firstDate: DateTime(2025),
                            lastDate: DateTime(2030),
                          );
                          if (picked != null) {
                            setState(() => _tempFilterEndDate = picked);
                          }
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Sampai Tanggal',
                            border: const OutlineInputBorder(),
                            labelStyle: TextStyle(
                              color:
                                  isDarkMode ? Colors.white70 : Colors.black87,
                            ),
                          ),
                          child: Text(
                            _tempFilterEndDate == null
                                ? 'dd/mm/yyyy'
                                : '${_tempFilterEndDate!.day}/${_tempFilterEndDate!.month}/${_tempFilterEndDate!.year}',
                            style: TextStyle(
                              color: isDarkMode ? Colors.white : Colors.black87,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _tempFilterStatus,
                        dropdownColor:
                            isDarkMode ? const Color(0xFF1E293B) : Colors.white,
                        style: TextStyle(
                          color: isDarkMode ? Colors.white : Colors.black87,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Status',
                          border: const OutlineInputBorder(),
                          labelStyle: TextStyle(
                            color: isDarkMode ? Colors.white70 : Colors.black87,
                          ),
                        ),
                        items: ['Semua', 'Normal', 'Warning', 'Critical']
                            .map(
                              (s) => DropdownMenuItem(value: s, child: Text(s)),
                            )
                            .toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _tempFilterStatus = val);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: () {
                        setState(() {
                          _tempFilterStartDate = null;
                          _tempFilterEndDate = null;
                          _tempFilterStatus = 'Semua';
                          _filterStartDate = null;
                          _filterEndDate = null;
                          _filterStatus = 'Semua';
                        });
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                      ),
                      child: const Text('Reset'),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _filterStartDate = _tempFilterStartDate;
                          _filterEndDate = _tempFilterEndDate;
                          _filterStatus = _tempFilterStatus;
                        });
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                      ),
                      child: const Text(
                        'Terapkan',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Data Monitoring (${filteredRecords.length} hasil)',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: isDarkMode ? Colors.white : Colors.black87,
            ),
          ),
          const SizedBox(height: 10),
          _isLoadingRecords
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(40.0),
                    child: CircularProgressIndicator(),
                  ),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: isDarkMode ? const Color(0xFF1E293B) : Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const [
                      BoxShadow(color: Colors.black12, blurRadius: 4),
                    ],
                  ),
                  child: Theme(
                    data: Theme.of(context).copyWith(
                      cardColor:
                          isDarkMode ? const Color(0xFF1E293B) : Colors.white,
                      dividerColor:
                          isDarkMode ? Colors.white24 : Colors.black12,
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: MediaQuery.of(context).size.width * 1.6,
                        child: PaginatedDataTable(
                          rowsPerPage: filteredRecords.isEmpty
                              ? 1
                              : (filteredRecords.length < 10
                                  ? filteredRecords.length
                                  : 10),
                          columnSpacing: 15,
                          horizontalMargin: 15,
                          columns: [
                            DataColumn(
                                label: Text('No',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: isDarkMode
                                            ? Colors.white70
                                            : Colors.black87))),
                            DataColumn(
                                label: Text('Tanggal & Waktu',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: isDarkMode
                                            ? Colors.white70
                                            : Colors.black87))),
                            DataColumn(
                                label: Text('pH',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: isDarkMode
                                            ? Colors.white70
                                            : Colors.black87))),
                            DataColumn(
                                label: Text('Suhu (°C)',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: isDarkMode
                                            ? Colors.white70
                                            : Colors.black87))),
                            DataColumn(
                                label: Text('TDS (ppm)',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: isDarkMode
                                            ? Colors.white70
                                            : Colors.black87))),
                            DataColumn(
                                label: Text('NTU',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: isDarkMode
                                            ? Colors.white70
                                            : Colors.black87))),
                            DataColumn(
                                label: Text('Kualitas Air',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: isDarkMode
                                            ? Colors.white70
                                            : Colors.black87))),
                            DataColumn(
                                label: Text('Status',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: isDarkMode
                                            ? Colors.white70
                                            : Colors.black87))),
                          ],
                          source:
                              _RecordDataSource(filteredRecords, isDarkMode),
                        ),
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );

    final List<Widget> pages = [dashboardWidget, rcWidget, laporanWidget];

    return PopScope(
      canPop: _currentIndex == 0,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (didPop) return;
        if (_currentIndex != 0) {
          _changeTab(0);
        }
      },
      child: Scaffold(
        body: pages[_currentIndex],
        bottomNavigationBar: _currentIndex == 1
            ? null
            : Container(
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 8,
                      offset: Offset(0, -2),
                    ),
                  ],
                ),
                child: BottomNavigationBar(
                  currentIndex: _currentIndex,
                  onTap: _changeTab,
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  type: BottomNavigationBarType.fixed,
                  selectedItemColor: Colors.white,
                  unselectedItemColor: Colors.white60,
                  selectedFontSize: 12,
                  unselectedFontSize: 11,
                  items: const [
                    BottomNavigationBarItem(
                      icon: Icon(Icons.dashboard_rounded),
                      label: 'Dashboard',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.sports_esports_rounded),
                      label: 'Remote RC',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.assessment_rounded),
                      label: 'Laporan',
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  String _monthName(int m) {
    const months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agu',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    return months[m];
  }

  Widget _buildReportCard(
    String title,
    String value,
    String subtitle,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDarkMode ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textMuted,
                ),
              ),
              Icon(icon, size: 16, color: color),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 9.5, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Text(
        text,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: AppColors.primaryDark,
        ),
      );

  SliverAppBar _buildAppBar(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      toolbarHeight: 56,
      expandedHeight: 70,
      backgroundColor: AppColors.primary,
      elevation: 0,
      titleSpacing: 0,
      title: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/logo.png',
                width: 32,
                height: 32,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Dashboard Tambak',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16.5,
                  color: Colors.white,
                ),
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
      actions: [
        SizedBox(
          width: 38,
          height: 38,
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 20,
            icon: Icon(
              isDarkMode ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
              color: Colors.white,
            ),
            tooltip: 'Ubah Tema',
            onPressed: () {
              setState(() {
                isDarkMode = !isDarkMode;
              });
            },
          ),
        ),
        SizedBox(
          width: 38,
          height: 38,
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 20,
            icon: const Icon(Icons.tune_rounded, color: Colors.white),
            tooltip: 'Atur Ambang Batas',
            onPressed: _openSettings,
          ),
        ),
        const SizedBox(width: 6),
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.primaryDark, AppColors.primary],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBanner() {
    late final Color bg;
    late final Color fg;
    late final IconData icon;
    late final String label;
    bool showRetry = false;

    switch (status) {
      case MqttUiStatus.connecting:
        bg = Colors.blueGrey.withOpacity(0.08);
        fg = AppColors.textMuted;
        icon = Icons.sync_rounded;
        label = 'Menghubungkan ke broker...';
        break;
      case MqttUiStatus.connected:
        bg = AppColors.safe.withOpacity(0.10);
        fg = AppColors.safe;
        icon = Icons.wifi_rounded;
        label = 'Terhubung ke broker';
        break;
      case MqttUiStatus.disconnected:
        bg = AppColors.warning.withOpacity(0.10);
        fg = AppColors.warning;
        icon = Icons.wifi_off_rounded;
        label = 'Terputus. Menyambung ulang...';
        break;
      case MqttUiStatus.failed:
        bg = AppColors.danger.withOpacity(0.10);
        fg = AppColors.danger;
        icon = Icons.error_outline_rounded;
        label = 'Koneksi gagal';
        showRetry = true;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 19),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
              ),
            ),
          ),
          if (showRetry)
            TextButton(
              onPressed: _connect,
              style: TextButton.styleFrom(foregroundColor: fg),
              child: const Text('Coba Lagi'),
            ),
        ],
      ),
    );
  }

  Widget _buildWaterQualityCard(Map<String, dynamic> quality) {
    final double score = (quality['score'] as num).toDouble();
    final String status = quality['status'] as String;
    final String conditionText = quality['conditionText'] as String;
    final Color accentColor = quality['color'] as Color;
    final String summary = quality['summary'] as String;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDarkMode ? const Color(0xFF1E293B) : const Color(0xFFEEF8FA),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFCCECE6), width: 1.3),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'KUALITAS AIR',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                      color: Color(0xFF52708F),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3.5,
                    ),
                    decoration: BoxDecoration(
                      color:
                          isDarkMode ? const Color(0xFF0F172A) : Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFA7F3D0)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 6, color: accentColor),
                        const SizedBox(width: 5),
                        Text(
                          status,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.bold,
                            color: accentColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1E40AF), Color(0xFF06B6D4)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const Icon(
                  Icons.water_drop,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: 140,
            height: 140,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 130,
                  height: 130,
                  child: CircularProgressIndicator(
                    value: (score / 100).clamp(0.0, 1.0),
                    strokeWidth: 9.5,
                    backgroundColor: const Color(0xFFE2E8F0),
                    valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                    strokeCap: StrokeCap.round,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      score.toInt().toString(),
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        color:
                            isDarkMode ? Colors.white : const Color(0xFF0F172A),
                        height: 1.0,
                      ),
                    ),
                    const Text(
                      '/ 100',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      conditionText,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.6,
                        color: accentColor,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            summary,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12.5,
              color: Color(0xFF64748B),
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildMiniParam(
                  label: 'pH',
                  value: _values['ph'] ?? '--',
                  valueColor: const Color(0xFF1E3A8A),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildMiniParam(
                  label: 'Suhu',
                  value:
                      _values['suhu'] != '--' ? '${_values['suhu']}°C' : '--',
                  valueColor: const Color(0xFF10B981),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildMiniParam(
                  label: 'TDS',
                  value:
                      _values['tds'] != '--' ? '${_values['tds']} ppm' : '--',
                  valueColor: const Color(0xFF06B6D4),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildMiniParam(
                  label: 'NTU',
                  value: _values['kekeruhan'] ?? '--',
                  valueColor: const Color(0xFF8B5CF6),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniParam({
    required String label,
    required String value,
    required Color valueColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
      decoration: BoxDecoration(
        color: isDarkMode ? const Color(0xFF0F172A) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFCCECE6)),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF64748B),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: valueColor,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildSensorCard(SensorDef def) {
    final level = _levelFor(def.key);
    final value = _values[def.key] ?? '--';

    final (badgeBg, badgeFg, badgeText) = switch (level) {
      SensorLevel.safe => (
          const Color(0xFFDCFCE7),
          const Color(0xFF15803D),
          'Normal',
        ),
      SensorLevel.warning => (
          const Color(0xFFFEF3C7),
          const Color(0xFFB45309),
          'Warning',
        ),
      SensorLevel.unknown => (
          const Color(0xFFF1F5F9),
          const Color(0xFF64748B),
          'Normal',
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: isDarkMode ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0), width: 1.0),
        boxShadow: const [
          BoxShadow(
            color: AppColors.cardShadow,
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: def.iconBg,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(def.icon, color: def.color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  def.label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: isDarkMode ? Colors.white : AppColors.textDark,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      def.unit,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  def.unitNote,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: badgeBg,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: badgeFg,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  badgeText,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: badgeFg,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAiRecommendationCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDarkMode ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: AppColors.cardShadow,
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFF0284C7),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.smart_toy_rounded,
                  color: Colors.white,
                  size: 26,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI Smart\nRecommendation',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: isDarkMode ? Colors.white : AppColors.textDark,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Saran tindakan cerdas saat kondisi air kolam bermasalah',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton(
              onPressed: _isAiLoading ? null : _fetchAiRecommendation,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0066FF),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
              child: _isAiLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.2,
                      ),
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.auto_awesome, size: 18, color: Colors.white),
                        SizedBox(width: 8),
                        Text(
                          'Cek Tindakan AI',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 14),
          _aiRecommendation == null
              ? Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isDarkMode
                        ? const Color(0xFF0F172A)
                        : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_rounded,
                        color: Color(0xFF0066FF),
                        size: 20,
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Klik tombol "Cek Tindakan AI" di atas jika Anda ingin mengevaluasi tindakan penanganan parameter air.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF64748B),
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : _buildAiResponseContent(_aiRecommendation!),
        ],
      ),
    );
  }

  Widget _buildTrendCard() {
    final def = sensorDefFor(_chartSensor);

    List<double> displayData = _records
        .map((r) {
          switch (_chartSensor) {
            case 'suhu':
              return r.suhu;
            case 'tds':
              return r.tds;
            case 'kekeruhan':
              return r.kekeruhan;
            case 'ph':
            default:
              return r.ph;
          }
        })
        .toList()
        .reversed
        .toList();

    if (displayData.isEmpty) {
      final currentNum = double.tryParse(_values[_chartSensor] ?? '') ?? 0.0;
      displayData = [currentNum, currentNum];
    }

    double? minVal, maxVal, avgVal;
    if (displayData.isNotEmpty) {
      minVal = displayData.reduce((a, b) => a < b ? a : b);
      maxVal = displayData.reduce((a, b) => a > b ? a : b);
      avgVal = displayData.reduce((a, b) => a + b) / displayData.length;
    }

    final subtitle = switch (_chartSensor) {
      'ph' => 'Perubahan tingkat pH air kolam (Realtime 30 menit)',
      'suhu' => 'Perubahan temperatur air tambak (Realtime 30 menit)',
      'tds' => 'Kandungan total padatan terlarut (Realtime 30 menit)',
      'kekeruhan' => 'Tingkat kekeruhan air kolam (Realtime 30 menit)',
      _ => 'Pemantauan fluktuasi parameter air',
    };

    String formatStat(double? val) {
      if (val == null) return '--';
      return '${val.toStringAsFixed(def.decimals)} ${def.unit}';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDarkMode ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: AppColors.cardShadow,
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: kSensorDefs.map((s) {
                final isSelected = s.key == _chartSensor;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: InkWell(
                    onTap: () => setState(() => _chartSensor = s.key),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected ? s.color : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          if (isSelected) ...[
                            const Icon(
                              Icons.check,
                              size: 14,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Text(
                            s.label,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: isSelected
                                  ? Colors.white
                                  : const Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: ['1 Hari', '7 Hari', '30 Hari'].map((range) {
              final isSelected = _chartRange == range;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  onTap: () => setState(() => _chartRange = range),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF0F172A)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF0F172A)
                            : const Color(0xFFCBD5E1),
                      ),
                    ),
                    child: Text(
                      range,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color:
                            isSelected ? Colors.white : const Color(0xFF64748B),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const Divider(height: 24, thickness: 0.8, color: Color(0xFFF1F5F9)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Grafik ${def.label}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: isDarkMode ? Colors.white : AppColors.textDark,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  _buildStatItem('AVG', formatStat(avgVal), def.color),
                  const SizedBox(width: 10),
                  _buildStatItem('MIN', formatStat(minVal), def.color),
                  const SizedBox(width: 10),
                  _buildStatItem('MAX', formatStat(maxVal), def.color),
                ],
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 180,
            child: displayData.length < 2
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.query_stats_rounded,
                          size: 34,
                          color: def.color.withOpacity(0.35),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Menunggu data masuk untuk membuat grafik ${def.label}...',
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                : LineChart(_buildChartData(def, displayData)),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: Color(0xFF94A3B8),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      ],
    );
  }

  LineChartData _buildChartData(SensorDef def, List<double> data) {
    final min = thresholds.minFor(def.key);
    final max = thresholds.maxFor(def.key);

    final spots = List.generate(
      data.length,
      (i) => FlSpot(i.toDouble(), data[i]),
    );

    final allValues = [...data, min, max];
    final chartMin = allValues.reduce((a, b) => a < b ? a : b);
    final chartMax = allValues.reduce((a, b) => a > b ? a : b);
    final pad = (chartMax - chartMin) * 0.15 + 0.2;

    return LineChartData(
      minY: (chartMin - pad).clamp(0.0, double.infinity),
      maxY: chartMax + pad,
      gridData: const FlGridData(
        show: true,
        drawVerticalLine: false,
        horizontalInterval: 1,
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        bottomTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 42,
            interval: (chartMax - chartMin + pad * 2) / 3,
            getTitlesWidget: (value, meta) => Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                value.toStringAsFixed(def.decimals),
                style: const TextStyle(
                  fontSize: 10,
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ),
        ),
      ),
      borderData: FlBorderData(show: false),
      extraLinesData: ExtraLinesData(
        horizontalLines: [
          HorizontalLine(
            y: min,
            color: AppColors.danger.withOpacity(0.55),
            strokeWidth: 1.2,
            dashArray: [5, 4],
          ),
          HorizontalLine(
            y: max,
            color: AppColors.danger.withOpacity(0.55),
            strokeWidth: 1.2,
            dashArray: [5, 4],
          ),
        ],
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          curveSmoothness: 0.35,
          color: def.color,
          barWidth: 2.8,
          isStrokeCapRound: true,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [def.color.withOpacity(0.20), def.color.withOpacity(0.0)],
            ),
          ),
        ),
      ],
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipItems: (spots) => spots
              .map(
                (s) => LineTooltipItem(
                  '${s.y.toStringAsFixed(def.decimals)} ${def.unit}',
                  const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  String _formatTime(DateTime t) {
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }
}

// ==========================================
// 3. SETTINGS SCREEN
// ==========================================
class SettingsScreen extends StatefulWidget {
  final Thresholds initial;
  final Future<void> Function(Thresholds) onSave;
  final bool isDarkMode;

  const SettingsScreen({
    super.key,
    required this.initial,
    required this.onSave,
    required this.isDarkMode,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _saving = false;
  late final Map<String, RangeValues> _ranges;

  @override
  void initState() {
    super.initState();
    _ranges = {
      'ph': RangeValues(widget.initial.phMin, widget.initial.phMax),
      'suhu': RangeValues(widget.initial.suhuMin, widget.initial.suhuMax),
      'tds': RangeValues(widget.initial.tdsMin, widget.initial.tdsMax),
      'kekeruhan': RangeValues(
        widget.initial.kekeruhanMin,
        widget.initial.kekeruhanMax,
      ),
    };
  }

  // FUNGSI GANDA (Simpan MQTT dan Simpan HTTP Web)
  Future<void> _save() async {
    final t = Thresholds(
      phMin: _ranges['ph']!.start,
      phMax: _ranges['ph']!.end,
      suhuMin: _ranges['suhu']!.start,
      suhuMax: _ranges['suhu']!.end,
      tdsMin: _ranges['tds']!.start,
      tdsMax: _ranges['tds']!.end,
      kekeruhanMin: _ranges['kekeruhan']!.start,
      kekeruhanMax: _ranges['kekeruhan']!.end,
    );

    setState(() => _saving = true);

    // 1. Tembak ke Alat ESP32 (Menggunakan fungsi onSave / MQTT)
    await widget.onSave(t);

    // 2. Setor Data ke Web Laravel (Menggunakan HTTP POST)
    try {
      final url = Uri.parse('http://172.14.5.252/api/set-ambang-batas');
      await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'ph_max': t.phMax,
          'suhu_max': t.suhuMax,
          'tds_max': t.tdsMax,
          'kekeruhan_max': t.kekeruhanMax,
          'ph_min': t.phMin,
          'suhu_min': t.suhuMin,
          'tds_min': t.tdsMin,
          'kekeruhan_min': t.kekeruhanMin,
        }),
      );
    } catch (e) {
      debugPrint('Gagal mengirim batas ke Laravel API: $e');
    }

    if (!mounted) return;
    setState(() => _saving = false);

    // Memunculkan Notifikasi Berhasil
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Ambang batas tersimpan di ESP32 & Web Laravel!'),
        backgroundColor: AppColors.safe,
      ),
    );
    Navigator.of(context).pop();
  }

  String _fmt(SensorDef def, double v) => def.decimals == 0
      ? v.round().toString()
      : v.toStringAsFixed(def.decimals);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          widget.isDarkMode ? const Color(0xFF0F172A) : AppColors.background,
      appBar: AppBar(
        title: const Text('Atur Ambang Batas'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: widget.isDarkMode
                  ? const Color(0xFF1E293B)
                  : AppColors.primary.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Geser slider sesuai jangkauan asli tiap sensor. Perubahan langsung dikirim ke ESP32 dan tersimpan permanen di perangkat.',
              style: TextStyle(
                color:
                    widget.isDarkMode ? Colors.white70 : AppColors.primaryDark,
                fontSize: 12.5,
              ),
            ),
          ),
          const SizedBox(height: 20),
          ...kSensorDefs.map((def) => _buildSliderField(def)),
          const SizedBox(height: 8),

          // TOMBOL PEMICU FUNGSI GANDA
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text('Simpan & Kirim ke ESP32'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSliderField(SensorDef def) {
    final range = _ranges[def.key]!;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      decoration: BoxDecoration(
        color: widget.isDarkMode ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: def.color.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(def.icon, color: def.color, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    def.label,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: widget.isDarkMode ? Colors.white : Colors.black87,
                    ),
                  ),
                ],
              ),
              Text(
                '${_fmt(def, range.start)} – ${_fmt(def, range.end)} ${def.unit}',
                style: TextStyle(
                  color: def.color,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          RangeSlider(
            min: def.physicalMin,
            max: def.physicalMax,
            values: range,
            activeColor: def.color,
            inactiveColor: def.color.withOpacity(0.15),
            labels: RangeLabels(_fmt(def, range.start), _fmt(def, range.end)),
            onChanged: (v) => setState(() => _ranges[def.key] = v),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Jangkauan sensor: ${_fmt(def, def.physicalMin)} – ${_fmt(def, def.physicalMax)} ${def.unit}',
              style: TextStyle(
                fontSize: 10.5,
                color: widget.isDarkMode ? Colors.white60 : AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// KELAS PENGATUR HALAMAN TABEL (PAGINATION)
// ==========================================
class _RecordDataSource extends DataTableSource {
  final List<RecordItem> data;
  final bool isDarkMode;

  _RecordDataSource(this.data, this.isDarkMode);

  String _monthName(int m) {
    const months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agu',
      'Sep',
      'Okt',
      'Nov',
      'Des'
    ];
    return months[m];
  }

  @override
  DataRow? getRow(int index) {
    if (index >= data.length) return null;
    final item = data[index];

    return DataRow(
      cells: [
        DataCell(Text('${index + 1}',
            style: TextStyle(
                color: isDarkMode ? Colors.white70 : Colors.black87))),
        DataCell(Text(
            '${item.time.day} ${_monthName(item.time.month)} ${item.time.year}\n${item.time.hour.toString().padLeft(2, '0')}:${item.time.minute.toString().padLeft(2, '0')}:${item.time.second.toString().padLeft(2, '0')}',
            style: TextStyle(
                fontSize: 11,
                color: isDarkMode ? Colors.white70 : Colors.black87))),
        DataCell(Text(item.ph.toStringAsFixed(1),
            style: const TextStyle(
                color: AppColors.ph, fontWeight: FontWeight.bold))),
        DataCell(Text('${item.suhu.toStringAsFixed(1)}°C',
            style: const TextStyle(
                color: AppColors.suhu, fontWeight: FontWeight.bold))),
        DataCell(Text(item.tds.toStringAsFixed(0),
            style: const TextStyle(
                color: AppColors.tds, fontWeight: FontWeight.bold))),
        DataCell(Text(item.kekeruhan.toStringAsFixed(1),
            style: const TextStyle(
                color: AppColors.kekeruhan, fontWeight: FontWeight.bold))),
        DataCell(Text(item.kualitas,
            style: const TextStyle(
                fontWeight: FontWeight.bold, color: AppColors.warning))),
        DataCell(Text(item.status,
            style: TextStyle(
                fontWeight: FontWeight.bold,
                color: item.status == 'Normal'
                    ? AppColors.safe
                    : (item.status == 'Warning'
                        ? AppColors.warning
                        : AppColors.danger)))),
      ],
    );
  }

  @override
  bool get isRowCountApproximate => false;
  @override
  int get rowCount => data.length;
  @override
  int get selectedRowCount => 0;
}
