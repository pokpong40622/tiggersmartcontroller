import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: TiggerControllerApp(),
    ),
  );
}

class TiggerControllerApp extends StatefulWidget {
  const TiggerControllerApp({super.key});

  @override
  State<TiggerControllerApp> createState() => _TiggerControllerAppState();
}

class _TiggerControllerAppState extends State<TiggerControllerApp> {
  late final WebViewController _webController;

  // UI State
  bool _isMenuOpen = false;
  bool _isLoading = true; // While checking SharedPreferences on startup
  bool _isFirstLaunch = true; // True = show URL setup screen

  // UART Buffer
  String _incomingBuffer = "";

  // BLE Variables
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeChar;
  StreamSubscription? _notifySubscription;
  StreamSubscription? _connectionStateSubscription;
  StreamSubscription? _scanSubscription;

  // UUIDs
  final String UUID_SERVICE = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  final String UUID_WRITE = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
  final String UUID_NOTIFY = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";

  // URL input controller (for setup screen)
  final TextEditingController _urlController = TextEditingController();

  @override
  void initState() {
    super.initState();

    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        'FlutterBridge',
        onMessageReceived: (JavaScriptMessage message) {
          _handleWebMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) {
            if (_connectedDevice != null) {
              _sendToWeb('STATUS', 'CONNECTED');
            }
          },
        ),
      );

    _checkFirstLaunch();
  }

  // ─── STARTUP: Check if URL is already saved ───────────────────────────────

  Future<void> _checkFirstLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    final String? savedUrl = prefs.getString('saved_app_url');

    if (savedUrl != null && savedUrl.isNotEmpty) {
      // URL already saved → load WebView directly
      _webController.loadRequest(Uri.parse(savedUrl));
      setState(() {
        _isFirstLaunch = false;
        _isLoading = false;
      });
    } else {
      // No URL yet → show setup screen
      setState(() {
        _isFirstLaunch = true;
        _isLoading = false;
      });
    }
  }

  // Called when user taps "Launch" on the setup screen
  Future<void> _saveAndLaunch() async {
    String url = _urlController.text.trim();
    if (url.isEmpty) return;

    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_app_url', url);

    _webController.loadRequest(Uri.parse(url));
    setState(() => _isFirstLaunch = false);
  }

  @override
  void dispose() {
    _notifySubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _scanSubscription?.cancel();
    _urlController.dispose();
    super.dispose();
  }

  // ─── WEB → FLUTTER MESSAGES ───────────────────────────────────────────────

  void _handleWebMessage(String jsonStr) async {
    try {
      final data = jsonDecode(jsonStr);
      final action = data['action'];

      if (action == 'CONNECT') {
        if (_connectedDevice != null) {
          _sendToWeb('STATUS', 'CONNECTED');
        } else {
          await _smartScanAndConnect();
        }
      } else if (action == 'DISCONNECT') {
        await _disconnectDevice();
      } else if (action == 'WRITE') {
        final cmd = data['payload']['data'];
        await _writeToDevice(cmd);
      }
    } catch (e) {
      debugPrint("JSON Error: $e");
    }
  }

  void _sendToWeb(String type, dynamic content) {
    final Map<String, dynamic> dataObj = {'type': type, 'content': content};
    final String jsonStr = jsonEncode(dataObj);
    final String safeJsString = jsonEncode(jsonStr);
    _webController.runJavaScript("receiveDataFromApp($safeJsString)");
  }

  // ─── BLE: SMART SCAN & CONNECT ────────────────────────────────────────────

  Future<void> _smartScanAndConnect() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    // ✅ FIX: Wait for Bluetooth adapter to be fully ON before scanning.
    // This prevents the "CBManagerStateUnknown" error on first open.
    try {
      final BluetoothAdapterState adapterState =
          await FlutterBluePlus.adapterState.first;

      if (adapterState != BluetoothAdapterState.on) {
        // Wait up to 8 seconds for BT to turn on
        await FlutterBluePlus.adapterState
            .where((s) => s == BluetoothAdapterState.on)
            .first
            .timeout(const Duration(seconds: 8));
      }
    } catch (e) {
      _sendToWeb(
        'ERROR',
        'Bluetooth is not enabled. Please turn on Bluetooth and try again.',
      );
      return;
    }

    _sendToWeb('STATUS', 'SCANNING');
    bool deviceFound = false;

    try {
      await FlutterBluePlus.startScan(
        withNames: ["TiggerSmart"],
        timeout: const Duration(seconds: 4),
      );

      _scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
        if (results.isNotEmpty && !deviceFound) {
          final ScanResult r = results.first;
          if (r.device.platformName == "TiggerSmart") {
            deviceFound = true;
            await FlutterBluePlus.stopScan();
            _connectToDevice(r.device);
          }
        }
      });

      await Future.delayed(const Duration(seconds: 4));
      await _scanSubscription?.cancel();

      if (!deviceFound && mounted) _showManualList();
    } catch (e) {
      _sendToWeb('ERROR', 'Scan Error: $e');
    }
  }

  void _showManualList() async {
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Select manually"),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: StreamBuilder<List<ScanResult>>(
              stream: FlutterBluePlus.scanResults,
              builder: (context, snapshot) {
                if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  return const Center(child: Text("Scanning..."));
                }
                final devices = snapshot.data!
                    .where((r) => r.device.platformName.isNotEmpty)
                    .toList();
                if (devices.isEmpty) {
                  return const Center(child: Text("No named devices found."));
                }
                return ListView.builder(
                  itemCount: devices.length,
                  itemBuilder: (context, index) {
                    final result = devices[index];
                    return ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(result.device.platformName),
                      subtitle: Text(result.device.remoteId.toString()),
                      onTap: () {
                        FlutterBluePlus.stopScan();
                        Navigator.pop(context);
                        _connectToDevice(result.device);
                      },
                    );
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                FlutterBluePlus.stopScan();
                Navigator.pop(context);
                _sendToWeb('STATUS', 'DISCONNECTED');
              },
              child: const Text("Cancel"),
            ),
          ],
        );
      },
    );
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      _sendToWeb('STATUS', 'CONNECTING...');
      await device.connect(license: License.free, autoConnect: false);
      _connectedDevice = device;
      _incomingBuffer = "";

      _connectionStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _sendToWeb('STATUS', 'DISCONNECTED');
          _connectedDevice = null;
        }
      });

      await Future.delayed(const Duration(milliseconds: 1000));
      final List<BluetoothService> services = await device.discoverServices();

      final BluetoothService targetService = services.firstWhere(
        (s) => s.uuid.toString().toLowerCase() == UUID_SERVICE.toLowerCase(),
        orElse: () => throw Exception("Service Not Found"),
      );

      final chars = targetService.characteristics;

      try {
        _writeChar = chars.firstWhere(
          (c) => c.uuid.toString().toLowerCase() == UUID_WRITE.toLowerCase(),
        );
      } catch (e) {
        throw Exception("Write Char Not Found");
      }

      BluetoothCharacteristic notifyChar;
      try {
        notifyChar = chars.firstWhere(
          (c) => c.uuid.toString().toLowerCase() == UUID_NOTIFY.toLowerCase(),
        );
      } catch (e) {
        throw Exception("Notify Char Not Found");
      }

      await notifyChar.setNotifyValue(true);

      // Buffer system to reassemble chopped BLE packets
      _notifySubscription = notifyChar.lastValueStream.listen((value) {
        String newData = utf8.decode(value, allowMalformed: true);
        _incomingBuffer += newData;

        while (_incomingBuffer.contains('\n')) {
          final int index = _incomingBuffer.indexOf('\n');
          String completeLine = _incomingBuffer.substring(0, index);
          _incomingBuffer = _incomingBuffer.substring(index + 1);
          completeLine = completeLine.trim().replaceAll('\r', '');
          if (completeLine.isNotEmpty) {
            _sendToWeb('NOTIFICATION', completeLine);
          }
        }
      });

      _sendToWeb('STATUS', 'CONNECTED');
    } catch (e) {
      _sendToWeb('ERROR', 'Connection Fail: $e');
      await _disconnectDevice();
    }
  }

  Future<void> _disconnectDevice() async {
    await _notifySubscription?.cancel();
    await _connectedDevice?.disconnect();
    _connectedDevice = null;
    _incomingBuffer = "";
    _sendToWeb('STATUS', 'DISCONNECTED');
  }

  // Chunked write for long commands
  Future<void> _writeToDevice(String cmd) async {
    if (_connectedDevice == null || _writeChar == null) {
      _sendToWeb('ERROR', 'Not Connected');
      return;
    }

    final List<int> bytes = utf8.encode(cmd);
    const int chunkSize = 20;

    try {
      for (int i = 0; i < bytes.length; i += chunkSize) {
        final int end = (i + chunkSize < bytes.length)
            ? i + chunkSize
            : bytes.length;
        final List<int> chunk = bytes.sublist(i, end);
        await _writeChar!.write(chunk, withoutResponse: true);
        await Future.delayed(const Duration(milliseconds: 20));
      }
    } catch (e) {
      _sendToWeb('ERROR', 'Write Failed: $e');
    }
  }

  // ─── SETTINGS DIALOG (change URL after first launch) ──────────────────────

  void _showSettingsDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final String current = prefs.getString('saved_app_url') ?? '';
    final TextEditingController txtCtrl = TextEditingController(text: current);

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Change Website URL"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Enter the URL to load:"),
              const SizedBox(height: 10),
              TextField(
                controller: txtCtrl,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: "Website URL",
                  hintText: "Please enter your link",
                ),
                keyboardType: TextInputType.url,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () async {
                String newUrl = txtCtrl.text.trim();
                if (newUrl.isNotEmpty) {
                  await prefs.setString('saved_app_url', newUrl);
                  _webController.loadRequest(Uri.parse(newUrl));
                  setState(() => _isMenuOpen = false);
                  if (mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text("URL Saved!")));
                  }
                }
              },
              child: const Text("Save"),
            ),
          ],
        );
      },
    );
  }

  // ─── FIRST LAUNCH SETUP SCREEN ────────────────────────────────────────────

  Widget _buildSetupScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Logo / Icon
                

                // Title
                Row(
                  children: [
                    Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF06B6D4), Color(0xFF3B82F6)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        12,
                      ), // ปรับความโค้งมนตรงนี้ (ยิ่งเลขมากยิ่งมน)
                      child: Image.asset(
                        'assets/TGcontrollerIcon.png',
                        width: 66,
                        height:
                            66, // แนะนำให้ใส่ความสูงกำกับไว้ด้วยเพื่อให้สัดส่วนนิ่งครับ
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 12,),
                    const Text(
                      'TGcontroller',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Enter your control panel URL to get started.',
                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
                ),
                const SizedBox(height: 40),

                // URL input
                TextField(
                  controller: _urlController,
                  style: const TextStyle(color: Colors.white),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    hintText: 'Please enter your link',
                    hintStyle: const TextStyle(color: Color(0xFF475569)),
                    filled: true,
                    fillColor: const Color(0xFF1E293B),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF334155)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF334155)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: Color(0xFF06B6D4),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Launch button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _saveAndLaunch,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF06B6D4),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Start',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── MAIN BUILD ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Splash while reading SharedPreferences
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF06B6D4)),
        ),
      );
    }

    // First launch: no URL saved yet
    if (_isFirstLaunch) {
      return _buildSetupScreen();
    }

    // Normal app: WebView + floating menu
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _webController),

            Positioned(
              bottom: 20,
              right: 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (_isMenuOpen) ...[
                    SizedBox(
                      height: 40,
                      width: 40,
                      child: FloatingActionButton(
                        heroTag: "settingsBtn",
                        elevation: 0,
                        backgroundColor: Colors.black.withOpacity(0.5),
                        onPressed: _showSettingsDialog,
                        child: const Icon(
                          Icons.settings,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 40,
                      width: 40,
                      child: FloatingActionButton(
                        heroTag: "refreshBtn",
                        elevation: 0,
                        backgroundColor: Colors.black.withOpacity(0.5),
                        onPressed: () {
                          _webController.reload();
                          setState(() => _isMenuOpen = false);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text("Refreshing..."),
                              duration: Duration(milliseconds: 800),
                            ),
                          );
                        },
                        child: const Icon(
                          Icons.refresh,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  SizedBox(
                    height: 45,
                    width: 45,
                    child: FloatingActionButton(
                      heroTag: "menuBtn",
                      elevation: 0,
                      backgroundColor: Colors.black.withOpacity(0.5),
                      onPressed: () =>
                          setState(() => _isMenuOpen = !_isMenuOpen),
                      child: Icon(
                        _isMenuOpen ? Icons.close : Icons.menu,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
