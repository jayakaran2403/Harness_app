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

  /// Simple root detection (without platform channel)
  Future<bool> isDeviceRooted() async {
    // Simple check that always returns false for now
    // You can implement actual root detection later
    return false;
  }

  /// Get device location
  Future<Position?> getLocation() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever ||
          permission == LocationPermission.denied) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium);
    } catch (e) {
      debugPrint("Location error: $e");
      return null;
    }
  }

  /// Fetch public IP address
  Future<String> fetchPublicIp() async {
    try {
      final resp = await http
          .get(Uri.parse('https://api.ipify.org?format=json'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body);
        return j['ip'] ?? "unknown";
      }
    } catch (e) {
      debugPrint("IP fetch error: $e");
    }
    return "unavailable";
  }

  /// Initialize front camera
  Future<void> initCamera() async {
    try {
      cameras ??= await availableCameras();
      final front = cameras!.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras!.first,
      );
      _cameraController =
          CameraController(front, ResolutionPreset.medium, enableAudio: true);
      await _cameraController!.initialize();
      setState(() {
        _isCameraInitialized = true;
      });
    } catch (e) {
      debugPrint("Camera init error: $e");
    }
  }

  /// Record a 2.5 second video
  Future<File?> recordShortVideo() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      await initCamera();
    }

    try {
      await _cameraController!.startVideoRecording();
      setState(() => _status = "Recording... (2.5s)");
      
      await Future.delayed(const Duration(milliseconds: 2500));
      
      final XFile recorded = await _cameraController!.stopVideoRecording();
      final File videoFile = File(recorded.path);
      
      // Verify video was created
      if (await videoFile.exists()) {
        final videoLength = await videoFile.length();
        debugPrint("Video recorded: ${videoFile.path}, size: $videoLength bytes");
        return videoFile;
      } else {
        debugPrint("Video file not created");
        return null;
      }
    } catch (e) {
      debugPrint("Video recording error: $e");
      return null;
    }
  }

  /// Get device ID (simplified)
  Future<String> getDeviceId() async {
    return "android_device_${DateTime.now().millisecondsSinceEpoch}";
  }

  /// Collect and send data + video to server
  Future<void> collectAndSend() async {
    try {
      setState(() => _status = "Collecting device info...");
      await Future.delayed(const Duration(milliseconds: 500));
      
      final rooted = await isDeviceRooted();
      final deviceId = await getDeviceId();

      setState(() => _status = "Getting location...");
      await Future.delayed(const Duration(milliseconds: 500));
      final pos = await getLocation();

      setState(() => _status = "Fetching public IP...");
      await Future.delayed(const Duration(milliseconds: 500));
      final ip = await fetchPublicIp();

      setState(() => _status = "Recording video (2.5s)...");
      final File? videoFile = await recordShortVideo();
      
      if (videoFile == null) {
        setState(() => _status = "❌ Video capture failed");
        return;
      }

      // Prepare JSON payload
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

      setState(() => _status = "Uploading to server...");
      
      // FIXED: Added http:// protocol
      final uri = Uri.parse("http://192.168.0.102:5000/verify");
      final request = http.MultipartRequest('POST', uri);
      
      // Add JSON data
      request.fields['data'] = jsonEncode(payload);

      // Add video file
      request.files.add(
        await http.MultipartFile.fromPath(
          'liveness_video',
          videoFile.path,
          contentType: MediaType('video', 'mp4'),
        ),
      );

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      
      if (response.statusCode == 200) {
        setState(() => _status = "✅ Upload Successful!\nServer: ${jsonDecode(responseBody)['message']}");
      } else {
        setState(() => _status = "❌ Upload Failed: ${response.statusCode}\n$responseBody");
      }
    } catch (e) {
      setState(() => _status = "❌ Error: $e\nCheck server IP and connection");
      debugPrint("Collect and send error: $e");
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
            // Status Display
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    const Text(
                      "Status:",
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: _status.contains('✅') ? Colors.green : 
                               _status.contains('❌') ? Colors.red : Colors.black,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 20),
            
            // Camera Preview (if initialized)
            if (_isCameraInitialized)
              Expanded(
                flex: 2,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: CameraPreview(_cameraController!),
                ),
              ),
            
            if (!_isCameraInitialized)
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
            
            // Action Button
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
            
            // Server Info
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  children: [
                    const Text(
                      "Make sure:",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      "• Python server is running\n• Correct IP address is set\n• Phone and computer on same WiFi",
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      "Server: http://192.168.0.102:5000", // FIXED: Added http://
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue[700],
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