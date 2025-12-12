import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:geolocator/geolocator.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: HomePage());
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = "Idle";
  CameraController? _cameraController;
  List<CameraDescription>? cameras;
  bool _isCameraInitialized = false;

  final String serverBaseUrl = "https://harness-app.onrender.com";

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    await _requestPermissions();
    await initCamera();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.camera,
      Permission.microphone,
      Permission.location,
      Permission.storage,
    ].request();
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  Future<bool> isDeviceRooted() async => false;

  Future<Position?> getLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium);
    } catch (e) {
      debugPrint("Location error: $e");
      return null;
    }
  }

  Future<String> fetchPublicIp() async {
    try {
      final resp = await http
          .get(Uri.parse('https://api.ipify.org?format=json'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body)['ip'] ?? "unknown";
      }
    } catch (e) {
      debugPrint("IP fetch error: $e");
    }
    return "unavailable";
  }

  Future<void> initCamera() async {
    try {
      cameras ??= await availableCameras();
      final CameraDescription front = cameras!.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras!.first,
      );

      _cameraController = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: true,
      );

      await _cameraController!.initialize();

      setState(() => _isCameraInitialized = true);
    } catch (e) {
      debugPrint("Camera init error: $e");
    }
  }

  Future<File?> recordShortVideo() async {
    try {
      if (_cameraController == null ||
          !_cameraController!.value.isInitialized) {
        await initCamera();
      }

      await _cameraController!.startVideoRecording();
      setState(() => _status = "Recording... (2.5s)");

      await Future.delayed(const Duration(milliseconds: 2500));

      final XFile recorded = await _cameraController!.stopVideoRecording();
      final File videoFile = File(recorded.path);

      if (await videoFile.exists()) {
        return videoFile;
      }
      return null;
    } catch (e) {
      debugPrint("Video recording error: $e");
      return null;
    }
  }

  Future<String> getDeviceId() async =>
      "android_device_${DateTime.now().millisecondsSinceEpoch}";

  Future<void> collectAndSend() async {
    try {
      setState(() => _status = "Collecting device info...");

      final rooted = await isDeviceRooted();
      final deviceId = await getDeviceId();

      final pos = await getLocation();
      final ip = await fetchPublicIp();

      setState(() => _status = "Recording video...");
      final File? videoFile = await recordShortVideo();

      if (videoFile == null) {
        setState(() => _status = "❌ Video capture failed");
        return;
      }

      final Map<String, dynamic> payload = {
        "device_id": deviceId,
        "is_compromised": rooted,
        "gps_location": {
          "latitude": pos?.latitude ?? 0.0,
          "longitude": pos?.longitude ?? 0.0
        },
        "ip_address": ip,
        "timestamp": DateTime.now().toIso8601String(),
        "platform": "android"
      };

      setState(() => _status = "Uploading to cloud server...");

      final uri = Uri.parse("$serverBaseUrl/verify");
      final request = http.MultipartRequest('POST', uri);

      request.fields['data'] = jsonEncode(payload);

      request.files.add(
        await http.MultipartFile.fromPath(
          'liveness_video',
          videoFile.path,
          contentType: MediaType("video", "mp4"),
        ),
      );

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        setState(() => _status =
            "✅ Upload Successful!\nServer: ${jsonDecode(responseBody)['message']}");
      } else {
        setState(() =>
            _status = "❌ Upload Failed (${response.statusCode})\n$responseBody");
      }
    } catch (e) {
      setState(() =>
          _status = "❌ Error: $e\n(Cloud server may be waking up — wait 20–40 sec)");
      debugPrint("Upload error: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Liveness + Device Check"),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    const Text(
                      "Status:",
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: _status.contains('✅')
                            ? Colors.green
                            : _status.contains('❌')
                                ? Colors.red
                                : Colors.black,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (_isCameraInitialized)
              Expanded(
                flex: 2,
                child: Container(
                  decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(8)),
                  child: CameraPreview(_cameraController!),
                ),
              )
            else
              const Expanded(
                flex: 2,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text("Initializing camera..."),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: collectAndSend,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: const Text(
                  "Run Security Check & Upload",
                  style: TextStyle(fontSize: 16),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  children: [
                    const Text(
                      "Cloud Server Details:",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      "• Hosted on Render Cloud\n"
                      "• First request takes ~20–40 seconds\n"
                      "• Works on WiFi, mobile data, hotspot — everything",
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      serverBaseUrl,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.blue,
                        fontWeight: FontWeight.bold,
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
  }
}
