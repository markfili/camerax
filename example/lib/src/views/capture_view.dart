import 'package:camerax/camerax.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class CaptureView extends StatefulWidget {
  const CaptureView({Key? key}) : super(key: key);

  @override
  State<CaptureView> createState() => _CaptureViewState();
}

class _CaptureViewState extends State<CaptureView> {
  late final CameraController cameraController;
  final List<FlashModeIcon> flashModeIcons = [
    FlashModeIcon(FlashMode.off, Icons.flash_off_rounded),
    FlashModeIcon(FlashMode.on, Icons.flash_on_rounded),
    FlashModeIcon(FlashMode.auto, Icons.flash_auto_rounded),
  ];

  late int flashModeIndex;

  @override
  void initState() {
    super.initState();
    cameraController = CameraController(
      cameraType: CameraType.picture,
      captureMode: CaptureMode.maxQuality,
    );
    start();
  }

  void start() async {
    flashModeIndex = _currentFlashModeIndex();
    await cameraController.startAsync();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(color: Colors.blue),
          CameraView(cameraController),
          Align(
            alignment: Alignment.bottomCenter,
            child: Card(
              margin: const EdgeInsets.only(bottom: 32.0),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ElevatedButton.icon(
                      icon: Icon(Icons.camera),
                      onPressed: () => _takePicture(context),
                      label: Text('Capture'),
                    ),
                    SizedBox(height: 16.0),
                    TextButton.icon(
                      label: Text('Flash ${describeEnum(cameraController.flashMode)}'),
                      onPressed: () => _switchFlashMode(),
                      icon: Icon(
                        flashModeIcons[flashModeIndex].iconData,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _takePicture(BuildContext context) async {
    if (!(await cameraController.isTakingPicture())) {
      print('Taking picture!');
      try {
        var result = await cameraController.takePicture();
        print('CAMERA RESULT $result');
        await Navigator.pushNamed(context, 'preview', arguments: result);
      } on CameraException catch (e) {
        print('Camera Error, reason: $e');
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Image capture error'),
            content: Text('${e.toString()}'),
          ),
        );
      }
    } else {
      print('Not taking picture!');
    }
  }

  @override
  void dispose() {
    cameraController.dispose();
    super.dispose();
  }

  Future<void> _switchFlashMode() async {
    var nextModeIndex = _currentFlashModeIndex() + 1;
    flashModeIndex = (nextModeIndex) >= flashModeIcons.length ? 0 : nextModeIndex;
    await cameraController.setFlashMode(flashModeIcons[flashModeIndex].flashMode);
    setState(() {
      print('new flash index: $flashModeIndex');
    });
  }

  int _currentFlashModeIndex() {
    var currentMode = cameraController.flashMode;
    var index =  flashModeIcons.indexWhere((e) => e.flashMode == currentMode);
    print('$currentMode is on $index');
    return index;
  }
}

class FlashModeIcon {
  final FlashMode flashMode;
  final IconData iconData;

  const FlashModeIcon(this.flashMode, this.iconData);
}
