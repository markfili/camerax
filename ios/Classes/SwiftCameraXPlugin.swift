import AVFoundation
import Flutter
import MLKitVision
import MLKitBarcodeScanning
import UIKit

enum ResolutionPreset {
    case veryLow
    case low
    case medium
    case high
    case veryHigh
    case ultraHigh
    case max
}

public class SwiftCameraXPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    private let IMAGE_FILE_EXTENSION = ".jpg"
    private let IMAGE_FILE_NAME_DATE_FORMAT = "yyyy-MM-dd-HH-mm-ss-SSS"
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SwiftCameraXPlugin(registrar.textures())
        
        let method = FlutterMethodChannel(name: "yanshouwang.dev/camerax/method", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: method)
        
        let event = FlutterEventChannel(name: "yanshouwang.dev/camerax/event", binaryMessenger: registrar.messenger())
        event.setStreamHandler(instance)
    }
    
    let registry: FlutterTextureRegistry
    var sink: FlutterEventSink!
    var textureId: Int64!
    var captureSession: AVCaptureSession!
    var previewSize: CGSize!
    var captureDevice: AVCaptureDevice!
    var photoOutput: AVCapturePhotoOutput!
    var latestBuffer: CVImageBuffer!
    var analyzeMode: Int
    var analyzing: Bool
    var flashMode: AVCaptureDevice.FlashMode
    var resolutionPreset: AVCaptureSession.Preset!
    
    init(_ registry: FlutterTextureRegistry) {
        self.registry = registry
        analyzeMode = 0
        analyzing = false
        flashMode = AVCaptureDevice.FlashMode.auto
        super.init()
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "state":
            stateNative(call, result)
        case "request":
            requestNative(call, result)
        case "start":
            startNative(call, result)
        case "torch":
            torchNative(call, result)
        case "analyze":
            analyzeNative(call, result)
        case "stop":
            stopNative(result)
        case "flash":
            flashModeNative(call, result)
        case "capture":
            captureNative(result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
    
    public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        if latestBuffer == nil {
            return nil
        }
        return Unmanaged<CVPixelBuffer>.passRetained(latestBuffer)
    }
    
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        latestBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        registry.textureFrameAvailable(textureId)
        
        switch analyzeMode {
        case 1: // barcode
            if analyzing {
                break
            }
            analyzing = true
            let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            let image = VisionImage(image: buffer!.image)
            let scanner = BarcodeScanner.barcodeScanner()
            scanner.process(image) { [self] barcodes, error in
                if error == nil && barcodes != nil {
                    for barcode in barcodes! {
                        let event: [String: Any?] = ["name": "barcode", "data": barcode.data]
                        sink?(event)
                    }
                }
                analyzing = false
            }
        default: // none
            break
        }
    }
    
    func stateNative(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .notDetermined:
            result(0)
        case .authorized:
            result(1)
        default:
            result(2)
        }
    }
    
    func requestNative(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        AVCaptureDevice.requestAccess(for: .video, completionHandler: { result($0) })
    }
    
    func startNative(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        if let args = call.arguments as? Dictionary<String, Any>,
           let cameraType = args["camera_type"] as? Int,
           let cameraFacing = args["camera_index"] as? Int {
            if let flashMode = args["camera_flash_mode"] as? Int {
                self.flashMode = flashModeRawToAVCaptureFlashMode(flashMode)
            }
            if let resolutionPresetRaw = args["camera_resolution"] as? Int {
                let resolutionPresetEnum = resolutionPresetRawToResolutionPreset(resolutionPresetRaw)
                self.resolutionPreset = resolutionPresetToAVCaptureSessionPreset(resolutionPresetEnum)
            }
            let position = cameraFacing == 0 ? AVCaptureDevice.Position.front : .back
            let type = cameraType == 0 ? "picture" : "barcode"
            
            if (type == "barcode") {
                setupBarcodeCapturing(position, result)
            } else if (type == "picture") {
                setupPictureCapturing(position, result)
            }
            textureId = registry.register(self)
            registry.textureFrameAvailable(textureId)
            
            let dimensions = CMVideoFormatDescriptionGetDimensions(captureDevice.activeFormat.formatDescription)
            let width = Double(dimensions.height)
            let height = Double(dimensions.width)
            let size = ["width": width, "height": height]
            let answer: [String : Any?] = ["textureId": textureId, "size": size, "torchable": captureDevice.hasTorch]
            result(answer)
        } else {
            result(FlutterError.init(code: "Missing init values", message: "Need to set camera_type and camera_facing values", details: nil))
        }
    }
    
    private func setupBarcodeCapturing(_ position: AVCaptureDevice.Position, _ result: @escaping FlutterResult) {
        
        setupDevice(position)
        captureDevice.addObserver(self, forKeyPath: #keyPath(AVCaptureDevice.torchMode), options: .new, context: nil)
        
        captureSession = AVCaptureSession()
        captureSession.beginConfiguration()
        
        if (resolutionPreset != nil && captureSession.canSetSessionPreset(resolutionPreset)) {
            if (resolutionPreset == .high && captureSession.canSetSessionPreset(.hd4K3840x2160)) {
                resolutionPreset = .hd4K3840x2160
            }
            captureSession.sessionPreset = resolutionPreset
        }
        
        // Add device input.
        do {
            let input = try AVCaptureDeviceInput(device: captureDevice)
            captureSession.addInput(input)
        } catch {
            error.throwNative(result)
        }
        
        // Add video output.
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue.main)
        captureSession.addOutput(videoOutput)
        for connection in videoOutput.connections {
            connection.videoOrientation = .portrait
            if position == .front && connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }
        captureSession.commitConfiguration()
        captureSession.startRunning()
    }
    
    private func setupPictureCapturing(_ position: AVCaptureDevice.Position, _ result: @escaping FlutterResult) {
        setupDevice(position)
        if (captureDevice != nil) {
            do {
                let input = try AVCaptureDeviceInput(device: captureDevice)
                
                let videoOutput = AVCaptureVideoDataOutput()
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue.main)
                
                
                captureSession = AVCaptureSession()
                captureSession.beginConfiguration()
                captureSession.addInputWithNoConnections(input)
                captureSession.addOutputWithNoConnections(videoOutput)
                
                let connection = AVCaptureConnection(inputPorts: input.ports, output: videoOutput)
                connection.videoOrientation = .portrait
                captureSession.addConnection(connection)
                
                photoOutput = AVCapturePhotoOutput()
                if #available(iOS 10.0, *) {
                    if (captureSession.canAddOutput(photoOutput)) {
                        captureSession.addOutput(photoOutput)
                    }
                }
                captureSession.commitConfiguration()
                captureSession.startRunning()
            } catch {
                error.throwNative(result)
            }
        } else {
            print("No device found for position: \(position.rawValue)")
        }
    }
    
    private func setupDevice(_ position: AVCaptureDevice.Position) {
        if #available(iOS 10.0, *) {
            captureDevice = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: position).devices.first
        } else {
            captureDevice = AVCaptureDevice.devices(for: .video).filter({$0.position == position}).first
        }
    }
    
    func torchNative(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        do {
            try captureDevice.lockForConfiguration()
            captureDevice.torchMode = call.arguments as! Int == 1 ? .on : .off
            captureDevice.unlockForConfiguration()
            result(nil)
        } catch {
            error.throwNative(result)
        }
    }
    
    func analyzeNative(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        analyzeMode = call.arguments as! Int
        result(nil)
    }
    
    func stopNative(_ result: FlutterResult) {
        captureSession.stopRunning()
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }
        captureDevice.removeObserver(self, forKeyPath: #keyPath(AVCaptureDevice.torchMode))
        registry.unregisterTexture(textureId)
        
        analyzeMode = 0
        latestBuffer = nil
        captureSession = nil
        captureDevice = nil
        textureId = nil
        
        result(nil)
    }
    
    private func flashModeNative(_ call: FlutterMethodCall, _ result: FlutterResult) {
        let rawFlashMode = call.arguments as! Int
        flashMode = flashModeRawToAVCaptureFlashMode(rawFlashMode)
        result(nil)
    }
    
    private func flashModeRawToAVCaptureFlashMode(_ rawMode: Int) -> AVCaptureDevice.FlashMode {
        switch (rawMode) {
            case 0: return .off
            case 1: return .on
            default: return .auto
        }
    }
    
    private func resolutionPresetRawToResolutionPreset(_ raw: Int) -> ResolutionPreset {
        switch (raw) {
            case 0:
              return .low
            case 1:
              return .medium
            case 2:
              return .high
            case 3:
              return .veryHigh
            case 4:
              return .ultraHigh
            default:
              return .max
        }
    }
    
    private func resolutionPresetToAVCaptureSessionPreset(_ resolutionPreset: ResolutionPreset) -> AVCaptureSession.Preset {
        var preset: AVCaptureSession.Preset = AVCaptureSession.Preset.low
        switch (resolutionPreset) {
            case .max:
               fallthrough
            case .ultraHigh:
                 preset = AVCaptureSession.Preset.high;
            case .veryHigh:
                 preset = AVCaptureSession.Preset.hd1920x1080;
            case .high:
                 preset = AVCaptureSession.Preset.hd1280x720;
            case .medium:
                 preset = AVCaptureSession.Preset.vga640x480;
            case .low:
                 preset = AVCaptureSession.Preset.cif352x288;
            default:
                preset = AVCaptureSession.Preset.low
            }
            return preset
    }

    
    private func captureNative(_ result: @escaping FlutterResult) {
        let settings = AVCapturePhotoSettings()
        
        if (captureDevice.isFlashAvailable) {
            settings.flashMode = flashMode
        }
        
        let path = createPhotoPath()
        
        let delegate = PhotoCaptureDelegate().initWithPath(
            onCaptureFinished:  {() -> Void in
                result(["path": path])
            }, onCaptureFailed: {(error) -> Void in
                error.throwNative(result)
            }, path)
        
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }
    
    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        switch keyPath {
        case "torchMode":
            // off = 0; on = 1; auto = 2;
            let state = change?[.newKey] as? Int
            let event: [String: Any?] = ["name": "torchState", "data": state]
            sink?(event)
        default:
            break
        }
    }
    
    private func createPhotoPath() -> String {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(),
                                isDirectory: true)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = IMAGE_FILE_NAME_DATE_FORMAT
        let fileName = dateFormatter.string(from: Date())
        let path = "\(tempDirectory.path)/\(fileName)\(IMAGE_FILE_EXTENSION)"
        print(path)
        return path
    }
}

public class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private(set) var path: String = ""
    private(set) var onCaptureFinished: () -> Void = {}
    private(set) var onCaptureFailed: (Error) -> Void = {error in print(error)}
    
    private var selfReference: AVCapturePhotoCaptureDelegate?
    
    func initWithPath(
        onCaptureFinished: @escaping () -> Void,
        onCaptureFailed: @escaping (Error) -> Void,
        _ path: String) -> PhotoCaptureDelegate {
            self.onCaptureFinished = onCaptureFinished
            self.onCaptureFailed = onCaptureFailed
            self.path = path
            self.selfReference = self
            return self
        }
    
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        selfReference = nil
        if error != nil {
            self.onCaptureFailed(error!)
            return
        }
        do {
            let photoData = photo.fileDataRepresentation()
            try photoData?.write(to: URL.init(fileURLWithPath: path))
            self.onCaptureFinished()
        } catch {
            self.onCaptureFailed(error)
        }
    }
}
