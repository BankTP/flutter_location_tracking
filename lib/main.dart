import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MyApp());
}

Future<void> foregroundServiceStartCallback() async {
  FlutterForegroundTask.setTaskHandler(LocationTaskHandler());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
          textTheme: const TextTheme(
        bodyText1: TextStyle(fontSize: 40),
        bodyText2: TextStyle(fontSize: 40),
        button: TextStyle(fontSize: 20.0),
      )),
      home: const MyHomePage(title: 'Car tracking v1.0'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  bool started = false;
  bool starting = false;
  bool isLocationUpdated = false;
  String lastLocationUpdate = "";
  String lastApiSend = "";
  bool isError = false;
  String lastCheckpointAt = '';

  ReceivePort? _receivePort;

  final driverInputController = TextEditingController();

  SharedPreferences? sp;

  T? _ambiguate<T>(T? value) => value;

  @override
  void initState() {
    super.initState();
    loadData();
    _initForegroundTask();
    _ambiguate(WidgetsBinding.instance)?.addPostFrameCallback((_) async {
      if (await FlutterForegroundTask.isRunningService) {
        final newReceivePort = await FlutterForegroundTask.receivePort;
        _registerReceivePort(newReceivePort);
      }
    });
  }

  @override
  void dispose() {
    driverInputController.dispose();
    _closeReceivePort();
    super.dispose();
  }

  Future<void> loadData() async {
    sp = await SharedPreferences.getInstance();
    driverInputController.text = sp?.getString("driver") ?? "";
    bool isRunning = await FlutterForegroundTask.isRunningService;
    setState(() {
      started = isRunning;
    });
  }

  Future<void> start() async {
    if (starting) {
      return;
    }
    if (!started) {
      // check permission first
      String? err;
      try {
        await checkLocationPermission();
      } catch (e) {
        err = e as String?;
      }
      if (err != null) {
        showDialog(
            context: context,
            builder: (BuildContext context) => AlertDialog(
                  title: const Text("ERROR"),
                  content: Text(err!),
                ));
        return;
      }
      sp?.setString("driver", driverInputController.text);
      setState(() {
        starting = true;
      });
    } else {
      debugPrint("started = $started");
      if (started != true) {
        return;
      }
    }

    if (starting) {
      FlutterForegroundTask.saveData(
          key: "driver", value: driverInputController.text);
      ReceivePort? receivePort;
      if (await FlutterForegroundTask.isRunningService) {
        debugPrint("restart");
        receivePort = await FlutterForegroundTask.restartService();
      } else {
        debugPrint("start");
        receivePort = await FlutterForegroundTask.startService(
            notificationTitle: 'Bus track',
            notificationText: 'Tracking location...',
            callback: foregroundServiceStartCallback);
      }
      _registerReceivePort(receivePort);
    } else {
      debugPrint("stop");

      setState(() {
        started = false;
      });
      FlutterForegroundTask.stopService();
    }
  }

  void _closeReceivePort() {
    _receivePort?.close();
    _receivePort = null;
  }

  void _registerReceivePort(ReceivePort? receivePort) {
    _closeReceivePort();
    if (receivePort != null) {
      _receivePort = receivePort;
      _receivePort?.listen((message) {
        if (message is String) {
          if (message == 'started') {
            debugPrint("started");
            setState(() {
              started = true;
              starting = false;
              isLocationUpdated = false;
              lastLocationUpdate = '-';
              lastApiSend = '-';
              isError = false;
              lastCheckpointAt = '';
            });
          } else if (message == 'location_update') {
            setState(() {
              isLocationUpdated = true;
              lastLocationUpdate = DateTime.now()
                  .toIso8601String()
                  .substring(0, 19)
                  .replaceFirst(RegExp(r'T'), ' ');
            });
          } else if (message == 'api_sent') {
            setState(() {
              isError = false;
              lastApiSend = DateTime.now()
                  .toIso8601String()
                  .substring(0, 19)
                  .replaceFirst(RegExp(r'T'), ' ');
            });
          } else if (message == 'api_error') {
            setState(() {
              isError = true;
            });
          } else if (message == 'checkpoint') {
            setState(() {
              lastCheckpointAt = DateTime.now()
                  .toIso8601String()
                  .substring(0, 19)
                  .replaceFirst(RegExp(r'T'), ' ');
            });
          }
        }
      });
    }
  }

  Future<void> _initForegroundTask() async {
    await FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'car_track',
        channelName: 'Car Track Location',
        channelDescription:
            'This notification appear when location tracking is started',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 2000,
        autoRunOnBoot: false,
        allowWifiLock: false,
      ),
      printDevLog: true,
    );
  }

  Future<bool> checkLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return Future.error('Location services are disabled.');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return Future.error('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      // Permissions are denied forever, handle appropriately.
      return Future.error(
          'Location permissions are permanently denied, we cannot request permissions.');
    }

    return Future.value(true);
  }

  Future<void> doCheckpoint() async {
    if (started) {
      sp?.setBool('checkpoint', true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
        child: Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: <Widget>[
                  const SizedBox(
                      width: 180,
                      child: Text(
                        "รหัสคนขับ",
                        style: TextStyle(fontSize: 30),
                      )),
                  Expanded(
                    child: TextField(
                      controller: driverInputController,
                      enabled: !started,
                      style: const TextStyle(fontSize: 30),
                      decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          hintText: 'รหัสคนขับ',
                          isDense: true,
                          contentPadding: EdgeInsets.all(10)),
                    ),
                  )
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.only(
                top: 20,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ElevatedButton(
                      style: ButtonStyle(
                          backgroundColor: MaterialStateProperty.all(starting
                              ? Colors.black12
                              : (started ? Colors.red : Colors.blue))),
                      onPressed: start,
                      child: Padding(
                          padding: const EdgeInsets.only(top: 10, bottom: 10),
                          child: Text(
                            starting
                                ? "STARTING"
                                : (started ? "STOP" : "START"),
                            style: const TextStyle(fontSize: 40),
                          )))
                ],
              ),
            ),
            Visibility(
                visible: started,
                child: Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.only(
                        top: 40,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ElevatedButton(
                            style: ButtonStyle(
                                backgroundColor:
                                    MaterialStateProperty.all(Colors.green)),
                            onPressed: doCheckpoint,
                            child: const Padding(
                              padding: EdgeInsets.only(top: 10, bottom: 10),
                              child: Text(
                                "CHECKPOINT",
                                style: TextStyle(fontSize: 40),
                              ),
                            ),
                          )
                        ],
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.only(top: 40),
                      child: isLocationUpdated
                          ? Column(children: [
                              Center(
                                  child: Text(
                                "ตำแหน่งอัปเดทล่าสุด $lastLocationUpdate",
                                style: const TextStyle(fontSize: 14),
                              )),
                              Center(
                                  child: Text(
                                "ส่งข้อมูลล่าสุด $lastApiSend",
                                style: const TextStyle(fontSize: 14),
                              )),
                              Visibility(
                                  visible: isError,
                                  child: const Center(
                                      child: Text("ส่งข้อมูลไม่สำเร็จ",
                                          style: TextStyle(fontSize: 14)))),
                              Visibility(
                                visible: lastCheckpointAt != '',
                                child: Center(
                                    child: Text(
                                        "Checkpoint ล่าสุดเมื่อ $lastCheckpointAt",
                                        style: const TextStyle(fontSize: 14))),
                              )
                            ])
                          : const Center(
                              child: Text("กำลังรอข้อมูลตำแหน่ง...",
                                  style: TextStyle(fontSize: 16)),
                            ),
                    )
                  ],
                )),
            const Spacer(),
          ],
        ),
      ),
    ));
  }
}

class LocationTaskHandler extends TaskHandler {
  SendPort? _sendPort;
  StreamSubscription<Position>? serviceStatusStream;
  var apiUrl = Uri.parse('http://146.190.6.211:1880/location_update');
  String driver = "";
  Position? currentPosition;
  SharedPreferences? sp;

  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    debugPrint('start task handler');
    _sendPort = sendPort;
    _sendPort?.send("started");
    sp = await SharedPreferences.getInstance();

    driver = (await FlutterForegroundTask.getData<String>(key: 'driver'))!;

    debugPrint("driver $driver");

    var c = await FlutterForegroundTask.getData<String>(key: 'checkpoint');
    debugPrint("checkpoint $c");

    serviceStatusStream =
        Geolocator.getPositionStream().listen((Position position) async {
      currentPosition = position;
      debugPrint("location update ${position.latitude}, ${position.longitude}");
      _sendPort?.send("location_update");
    });
  }

  @override
  Future<void> onEvent(DateTime timestamp, SendPort? sendPort) async {
    // Send data to the main isolate.
    debugPrint("event");
    if (currentPosition != null) {
      sp?.reload();
      final checkpoint = sp?.getBool('checkpoint') == true ? 1 : 0;
      sp?.setBool("checkpoint", false);
      try {
        http
            .post(apiUrl,
                headers: {"Content-Type": "application/json"},
                body: jsonEncode({
                  'name': driver,
                  'lat': currentPosition!.latitude,
                  'lon': currentPosition!.longitude,
                  'acc': currentPosition!.accuracy,
                  'spd': currentPosition!.speed,
                  'spd_acc': currentPosition!.speedAccuracy,
                  'checkpoint': checkpoint,
                }))
            .then((value) {
          // debugPrint("result ${value.statusCode}");
          _sendPort?.send('api_sent');
          debugPrint("api sent");
          if (checkpoint == 1) _sendPort?.send("checkpoint");
        }).onError((error, stackTrace) {
          _sendPort?.send('api_error');
          debugPrint("api errro");
        });
      } catch (e) {
        debugPrint("API ERROR");
      }
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    // You can use the clearAllData function to clear all the stored data.
    // await FlutterForegroundTask.clearAllData();
    serviceStatusStream?.cancel();
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
    _sendPort?.send('onNotificationPressed');
  }
}
