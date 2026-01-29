import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
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
  
  // BLE Variables
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeChar; 
  StreamSubscription? _notifySubscription;
  StreamSubscription? _connectionStateSubscription;
  StreamSubscription? _scanSubscription;

  // ============================================================
  // CONFIGURATION
  // ============================================================
  final String UUID_SERVICE = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  final String UUID_WRITE   = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"; 
  final String UUID_NOTIFY  = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";
  // ============================================================

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
      // ✅ FIX 1: SYNC STATE ON REFRESH
      // This detects when the website reloads and restores the connection status
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) {
            if (_connectedDevice != null) {
              // We are already connected, so force the website to turn Green immediately
              _sendToWeb('STATUS', 'CONNECTED');
            }
          },
        ),
      )
      // REPLACE WITH YOUR GITHUB URL
      ..loadRequest(Uri.parse('https://pokpong40622.github.io/tiggerwebsitedemo/'));
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
        // ✅ FIX 2: PREVENT DOUBLE CONNECT
        // If already connected, just update UI. Don't scan again.
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

  // === 2. Send Data TO Web ===
  void _sendToWeb(String type, dynamic content) {
    final jsonStr = jsonEncode({'type': type, 'content': content});
    _webController.runJavaScript("receiveDataFromApp('$jsonStr')");
  }

  // === 3. SMART CONNECT LOGIC ===
  Future<void> _smartScanAndConnect() async {
    await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.location].request();

    _sendToWeb('STATUS', 'SCANNING');

    bool deviceFound = false;

    try {
      await FlutterBluePlus.startScan(
        withNames: ["TiggerSmart"], 
        timeout: const Duration(seconds: 4)
      );

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

      if (!deviceFound) {
        if (mounted) _showManualList(); 
      }

    } catch (e) {
      _sendToWeb('ERROR', 'Scan Error: $e');
    }
  }

  // === 4. Manual List ===
  void _showManualList() async {
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Device Not Found Automatically"),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: Text("Select manually:", style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
                Expanded(
                  child: StreamBuilder<List<ScanResult>>(
                    stream: FlutterBluePlus.scanResults,
                    builder: (context, snapshot) {
                      if (!snapshot.hasData || snapshot.data!.isEmpty) {
                        return const Center(child: Text("Scanning..."));
                      }
                      
                      final devices = snapshot.data!
                          .where((r) => r.device.platformName.isNotEmpty)
                          .toList();

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
              ],
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

  // === 5. Connection Logic ===
  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      _sendToWeb('STATUS', 'CONNECTING...');

      await device.connect(license: License.free, autoConnect: false);
      _connectedDevice = device;

      _connectionStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
           _sendToWeb('STATUS', 'DISCONNECTED');
           _connectedDevice = null; // Mark as null so we know to reconnect next time
        }
      });

      await Future.delayed(const Duration(milliseconds: 1000));
      List<BluetoothService> services = await device.discoverServices();
      
      BluetoothService targetService = services.firstWhere(
        (s) => s.uuid.toString().toLowerCase() == UUID_SERVICE.toLowerCase(),
        orElse: () => throw Exception("Service Not Found"),
      );
      
      var chars = targetService.characteristics;
      try {
        _writeChar = chars.firstWhere((c) => c.uuid.toString().toLowerCase() == UUID_WRITE.toLowerCase());
      } catch (e) { throw Exception("Write Char Not Found"); }

      BluetoothCharacteristic notifyChar;
      try {
        notifyChar = chars.firstWhere((c) => c.uuid.toString().toLowerCase() == UUID_NOTIFY.toLowerCase());
      } catch (e) { throw Exception("Notify Char Not Found"); }

      await notifyChar.setNotifyValue(true);
      _notifySubscription = notifyChar.lastValueStream.listen((value) {
        String stringData = utf8.decode(value);
        _sendToWeb('NOTIFICATION', stringData);
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
    _sendToWeb('STATUS', 'DISCONNECTED');
  }

  Future<void> _writeToDevice(String cmd) async {
    if (_connectedDevice == null || _writeChar == null) return;
    try {
      await _writeChar!.write(utf8.encode(cmd));
    } catch (e) {
      _sendToWeb('ERROR', 'Write Failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("TiggerSmart"),
        backgroundColor: const Color(0xFF667eea),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _webController.clearCache();
              _webController.reload();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Refreshing website...")),
              );
            },
          ),
        ],
      ),
      body: WebViewWidget(controller: _webController),
    );
  }
}