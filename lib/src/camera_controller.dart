import 'dart:async';

import 'package:camerax/src/capture_mode.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'barcode.dart';
import 'camera_args.dart';
import 'camera_exception.dart';
import 'camera_facing.dart';
import 'camera_type.dart';
import 'flash_mode.dart';
import 'resolution_preset.dart';
import 'rotation.dart';
import 'torch_state.dart';
import 'util.dart';

/// A camera controller.
abstract class CameraController {
  /// Arguments for [CameraView].
  ValueNotifier<CameraArgs?> get args;

  /// Torch state of the camera.
  ValueNotifier<TorchState> get torchState;

  /// A stream of barcodes.
  Stream<Barcode>? get barcodes;

  FlashMode get flashMode;

  /// Create a [CameraController].
  ///
  /// [facing] target facing used to select camera.
  ///
  /// [formats] the barcode formats for image analyzer.
  factory CameraController({
    required CameraType cameraType,
    CameraLensDirection facing = CameraLensDirection.back,
    ResolutionPreset resolutionPreset = ResolutionPreset.max,
    CaptureMode captureMode = CaptureMode.maxQuality,
    FlashMode? flashMode,
  }) =>
      _CameraController(facing, cameraType, resolutionPreset, Rotation.rotationUnset, captureMode, flashMode);

  /// Start the camera asynchronously.
  Future<void> startAsync();

  /// Switch the torch's state.
  void torch();

  /// Release the resources of the camera.
  void dispose();

  Future<bool> isTakingPicture();

  Future<String> takePicture();

  Future<void> setFlashMode(FlashMode mode);
}

class _CameraController implements CameraController {
  static const MethodChannel method = MethodChannel('yanshouwang.dev/camerax/method');
  static const EventChannel event = EventChannel('yanshouwang.dev/camerax/event');

  static const String CAMERA_INDEX = 'camera_index';
  static const String CAMERA_TYPE = 'camera_type';
  static const String CAMERA_RESOLUTION = 'camera_resolution';
  static const String CAMERA_ROTATION = 'camera_rotation';
  static const String CAMERA_CAPTURE_MODE = 'camera_capture_mode';
  static const String CAMERA_FLASH_MODE = 'camera_flash_mode';

  static const undetermined = 0;
  static const authorized = 1;
  static const denied = 2;

  static const analyze_none = 0;
  static const analyze_barcode = 1;

  static int? id;
  static StreamSubscription? subscription;

  final CameraLensDirection cameraLensDirection;
  final CameraType cameraType;
  final CaptureMode captureMode;
  final ResolutionPreset resolutionPreset;
  final Rotation rotation;
  FlashMode? _flashMode;

  @override
  FlashMode get flashMode => _flashMode ?? FlashMode.auto;

  @override
  final ValueNotifier<CameraArgs?> args;
  @override
  final ValueNotifier<TorchState> torchState;

  bool torchable;
  bool _isTakingPicture = false;
  StreamController<Barcode>? barcodesController;

  @override
  Stream<Barcode>? get barcodes => barcodesController?.stream;

  _CameraController(
    this.cameraLensDirection,
    this.cameraType,
    this.resolutionPreset,
    this.rotation,
    this.captureMode,
    this._flashMode,
  )   : args = ValueNotifier(null),
        torchState = ValueNotifier(TorchState.off),
        torchable = false {
    // In case new instance before dispose.
    if (id != null) {
      stop();
    }
    id = hashCode;

    if (cameraType == CameraType.barcode) {
      // Create barcode stream controller.
      initBarcodeStream();
    }
  }

  void initBarcodeStream() {
    // Create barcode stream controller.
    barcodesController = StreamController.broadcast(
      onListen: () => tryAnalyze(analyze_barcode),
      onCancel: () => tryAnalyze(analyze_none),
    );
    // Listen event handler.
    subscription = event.receiveBroadcastStream().listen((data) => handleEvent(data));
  }

  void handleEvent(Map<dynamic, dynamic> event) {
    final name = event['name'];
    final data = event['data'];
    switch (name) {
      case 'torchState':
        final state = TorchState.values[data];
        torchState.value = state;
        break;
      case 'barcode':
        final barcode = Barcode.fromNative(data);
        barcodesController?.add(barcode);
        break;
      default:
        throw UnimplementedError();
    }
  }

  void tryAnalyze(int mode) {
    if (hashCode != id) {
      return;
    }
    method.invokeMethod('analyze', mode);
  }

  @override
  Future<void> startAsync() async {
    ensure('startAsync');
    // Check authorization state.
    var state = await method.invokeMethod('state');
    if (state == undetermined) {
      final result = await method.invokeMethod('request');
      state = result ? authorized : denied;
    }
    if (state != authorized) {
      throw CameraException('Camera access denied', 'Unauthorized access to camera, check app permission settings');
    }
    // Start camera.
    try {
      final answer = await method.invokeMapMethod<String, dynamic>('start', {
        CAMERA_INDEX: cameraLensDirection.index,
        CAMERA_TYPE: cameraType.index,
        CAMERA_RESOLUTION: resolutionPreset.index,
        CAMERA_ROTATION: rotation.index,
        CAMERA_CAPTURE_MODE: captureMode.index,
        CAMERA_FLASH_MODE: flashMode.index,
      });
      final textureId = answer?['textureId'];
      final size = toSize(answer?['size']);
      args.value = CameraArgs(textureId, size);
      torchable = answer?['torchable'];
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  @override
  void torch() {
    ensure('torch');
    if (!torchable) {
      return;
    }
    var state = torchState.value == TorchState.off ? TorchState.on : TorchState.off;
    method.invokeMethod('torch', state.index);
  }

  @override
  void dispose() {
    if (hashCode == id) {
      stop();
      subscription?.cancel();
      subscription = null;
      id = null;
    }
    barcodesController?.close();
  }

  void stop() => method.invokeMethod('stop');

  void ensure(String name) {
    final message = 'CameraController.$name called after CameraController.dispose\n'
        'CameraController methods should not be used after calling dispose.';
    assert(hashCode == id, message);
  }

  @override
  Future<void> setFlashMode(FlashMode mode) async {
    try {
      await method.invokeMethod('flash', mode.index);
      _flashMode = mode;
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  @override
  Future<String> takePicture() async {
    if (_isTakingPicture) {
      throw CameraException(
        'Previous capture has not returned yet.',
        'takePicture was called before the previous capture returned.',
      );
    }
    try {
      _isTakingPicture = true;
      var result = await method.invokeMethod('capture');
      _isTakingPicture = false;
      return result['path'];
    } on PlatformException catch (e) {
      _isTakingPicture = false;
      throw CameraException(e.code, e.message);
    }
  }

  @override
  Future<bool> isTakingPicture() async {
    return _isTakingPicture;
  }
}
