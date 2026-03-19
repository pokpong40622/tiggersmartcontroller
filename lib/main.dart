import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: TiggerControllerApp()
  ));
}

class TiggerControllerApp extends StatefulWidget {
  const TiggerControllerApp({super.key});

  @override
  State<TiggerControllerApp> createState() => _TiggerControllerAppState();
}

class _TiggerControllerAppState extends State<TiggerControllerApp> {
  late final WebViewController _webController;
  
  // UI State: Floating Menu Open/Close
  bool _isMenuOpen = false;

  // UART Buffer: Reconstructs chopped messages from Arduino
  String _incomingBuffer = "";

  // DEFAULT FALLBACK URL
  final String _defaultUrl = 'https://pokpong40622.github.io/tiggerwebsitedemo/';

  // BLE Variables
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeChar; 
  StreamSubscription? _notifySubscription;
  StreamSubscription? _connectionStateSubscription;
  StreamSubscription? _scanSubscription;

  // CONFIGURATION
  final String UUID_SERVICE = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  final String UUID_WRITE   = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"; 
  final String UUID_NOTIFY  = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";

  @override
  void initState() {
    super.initState();
    
    // Initialize Web Controller
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
            // Sync Connection State on Refresh
            if (_connectedDevice != null) {
              _sendToWeb('STATUS', 'CONNECTED');
            }
          },
        ),
      );

    // Load Saved URL
    _loadAndStartUrl();
  }

  Future<void> _loadAndStartUrl() async {
    final prefs = await SharedPreferences.getInstance();
    String? savedUrl = prefs.getString('saved_app_url');
    
    String targetUrl = savedUrl ?? _defaultUrl;
    
    if (mounted) {
      _webController.loadRequest(Uri.parse(targetUrl));
    }
  }

  @override
  void dispose() {
    _notifySubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _scanSubscription?.cancel();
    super.dispose();
  }

  // === 1. Handle Messages FROM Web ===
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
      } 
      else if (action == 'DISCONNECT') {
        await _disconnectDevice();
      } 
      else if (action == 'WRITE') {
        final cmd = data['payload']['data'];
        await _writeToDevice(cmd);
      }
    } catch (e) {
      debugPrint("JSON Error: $e");
    }
  }

  // ✅ FIX: 100% Safe JSON Encoding to prevent Red JavaScript Errors
  void _sendToWeb(String type, dynamic content) {
    final Map<String, dynamic> dataObj = {'type': type, 'content': content};
    final String jsonStr = jsonEncode(dataObj);
    
    // By re-encoding the string, Flutter escapes all quotes and control characters safely
    final String safeJsString = jsonEncode(jsonStr);
    _webController.runJavaScript("receiveDataFromApp($safeJsString)");
  }

  // === 2. SMART CONNECT LOGIC ===
  Future<void> _smartScanAndConnect() async {
    await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.location].request();
    _sendToWeb('STATUS', 'SCANNING');
    bool deviceFound = false;

    try {
      await FlutterBluePlus.startScan(withNames: ["TiggerSmart"], timeout: const Duration(seconds: 4));
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
        if (results.isNotEmpty && !deviceFound) {
          ScanResult r = results.first;
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
                if (!snapshot.hasData || snapshot.data!.isEmpty) return const Center(child: Text("Scanning..."));
                final devices = snapshot.data!.where((r) => r.device.platformName.isNotEmpty).toList();
                if (devices.isEmpty) return const Center(child: Text("No named devices found."));
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
      
      // Clear buffer on new connection
      _incomingBuffer = "";

      _connectionStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
           _sendToWeb('STATUS', 'DISCONNECTED');
           _connectedDevice = null;
        }
      });
      await Future.delayed(const Duration(milliseconds: 1000));
      List<BluetoothService> services = await device.discoverServices();
      BluetoothService targetService = services.firstWhere((s) => s.uuid.toString().toLowerCase() == UUID_SERVICE.toLowerCase(), orElse: () => throw Exception("Service Not Found"));
      var chars = targetService.characteristics;
      try {
        _writeChar = chars.firstWhere((c) => c.uuid.toString().toLowerCase() == UUID_WRITE.toLowerCase());
      } catch (e) { throw Exception("Write Char Not Found"); }
      BluetoothCharacteristic notifyChar;
      try {
        notifyChar = chars.firstWhere((c) => c.uuid.toString().toLowerCase() == UUID_NOTIFY.toLowerCase());
      } catch (e) { throw Exception("Notify Char Not Found"); }
      await notifyChar.setNotifyValue(true);
      
      // ✅ FIX: Buffer system to prevent "Format: UNKNOWN" chopped data
      _notifySubscription = notifyChar.lastValueStream.listen((value) {
        String newData = utf8.decode(value, allowMalformed: true);
        _incomingBuffer += newData; // Add new data to the holding buffer
        
        // Loop through the buffer and extract complete lines only
        while (_incomingBuffer.contains('\n')) {
          int index = _incomingBuffer.indexOf('\n');
          String completeLine = _incomingBuffer.substring(0, index);
          
          // Remove the processed line from the buffer
          _incomingBuffer = _incomingBuffer.substring(index + 1);
          
          // Clean invisible characters
          completeLine = completeLine.trim().replaceAll('\r', '');
          
          // Send complete sentence to Web
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

  // ✅ CHUNKING FIX: Keeps your long commands working
  Future<void> _writeToDevice(String cmd) async {
    if (_connectedDevice == null || _writeChar == null) {
      _sendToWeb('ERROR', 'Not Connected');
      return;
    }
    
    List<int> bytes = utf8.encode(cmd);
    int chunkSize = 20; 
    
    try {
      for (int i = 0; i < bytes.length; i += chunkSize) {
        int end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
        List<int> chunk = bytes.sublist(i, end);
        
        await _writeChar!.write(chunk, withoutResponse: true);
        await Future.delayed(const Duration(milliseconds: 20)); 
      }
    } catch (e) {
      _sendToWeb('ERROR', 'Write Failed: $e');
    }
  }

  // === 3. SETTINGS DIALOG LOGIC ===
  void _showSettingsDialog() async {
    final prefs = await SharedPreferences.getInstance();
    String current = prefs.getString('saved_app_url') ?? _defaultUrl;
    TextEditingController txtCtrl = TextEditingController(text: current);

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Set Default Website"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Enter the URL to load when the app starts:"),
              const SizedBox(height: 10),
              TextField(
                controller: txtCtrl,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: "Website URL",
                  hintText: "https://your-site.github.io/...",
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("URL Saved!")),
                    );
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

  // === 4. UI Build with Glass Floating Menu ===
  @override
  Widget build(BuildContext context) {
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
                      height: 40, width: 40,
                      child: FloatingActionButton(
                        heroTag: "settingsBtn",
                        elevation: 0, 
                        backgroundColor: Colors.black.withOpacity(0.5), 
                        onPressed: _showSettingsDialog,
                        child: const Icon(Icons.settings, color: Colors.white, size: 20),
                      ),
                    ),
                    const SizedBox(height: 12),
                    
                    SizedBox(
                      height: 40, width: 40,
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
                        child: const Icon(Icons.refresh, color: Colors.white, size: 20),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  
                  SizedBox(
                    height: 45, width: 45,
                    child: FloatingActionButton(
                      heroTag: "menuBtn",
                      elevation: 0,
                      backgroundColor: Colors.black.withOpacity(0.5),
                      onPressed: () {
                        setState(() {
                          _isMenuOpen = !_isMenuOpen;
                        });
                      },
                      child: Icon(
                        _isMenuOpen ? Icons.close : Icons.menu, 
                        color: Colors.white, 
                        size: 22
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