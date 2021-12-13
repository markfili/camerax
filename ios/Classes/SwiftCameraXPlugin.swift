import AVFoundation
import Flutter
import MLKitVision
import MLKitBarcodeScanning
import UIKit

enum ResolutionPreset : Int {
    case low = 0
    case medium = 1
    case high = 2
    case veryHigh = 3
    case ultraHigh = 4
    case max = 5
    
    init(fromRawValue: Int) {
        self = ResolutionPreset(rawValue: fromRawValue) ?? .max
    }
}

enum CameraType : String {
    case picture = "picture"
    case barcode = "barcode"
}

enum CameraRotation : Int {
    case rotation0 = 0
    case rotation90 = 1
    case rotation180 = 2
    case rotation270 = 3
    case rotationUnset = 4
    
    init(fromRawValue: Int) {
        self = CameraRotation(rawValue: fromRawValue) ?? .rotationUnset
    }
}

public class SwiftCameraXPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    private let IMAGE_FILE_EXTENSION = ".jpg"
    private let IMAGE_FILE_NAME_DATE_FORMAT = "yyyy-MM-dd-HH-mm-ss-SSS"
    
    private let CAMERA_INDEX = "camera_index"
    private let CAMERA_TYPE = "camera_type"
    private let CAMERA_RESOLUTION = "camera_resolution"
    private let CAMERA_FLASH_MODE = "camera_flash_mode"
    private let CAMERA_ROTATION = "camera_rotation"
    
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
    var videoOrientation: AVCaptureVideoOrientation
    
    init(_ registry: FlutterTextureRegistry) {
        self.registry = registry
        analyzeMode = 0
        analyzing = false
        flashMode = .auto
        videoOrientation = .portrait
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
           let type = (args[CAMERA_TYPE] as? Int).map({$0 == 0 ? CameraType.picture : .barcode}),
           let position = (args[CAMERA_INDEX] as? Int).map({$0 == 0 ? AVCaptureDevice.Position.front : .back}) {
            if let flashMode = args[CAMERA_FLASH_MODE] as? Int {
                self.flashMode = mapFlashMode(flashMode)
            }
            if let resolutionPreset = args[CAMERA_RESOLUTION] as? Int {
                self.resolutionPreset = mapResolutionPreset(resolutionPreset)
            }
//            Unsupported for now because this rotates the preview not a captured image
//            to apply to photo capture, it should probably be set through but currently no connection is set to photoOutput
//            photoOutput.connection(with: <#T##AVMediaType#>)?.videoOrientation
//            if let photoRotation = args[CAMERA_ROTATION] as? Int {
//                self.photoRotation = mapPhotoOrientation(photoRotation)
//            }
            setupDevice(position, result)
            
            switch (type) {
            case .barcode:
                setupBarcodeCapturing(result)
            case .picture:
                setupPictureCapturing(result)
            }
            
            textureId = registry.register(self)
            registry.textureFrameAvailable(textureId)
            
            respondWithDeviceInfo(result)
        } else {
            result(FlutterError.init(code: "Missing init values", message: "Need to set camera_type and camera_facing values", details: nil))
        }
    }
    
    private func respondWithDeviceInfo(_ result: FlutterResult) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(captureDevice.activeFormat.formatDescription)
        let width = Double(dimensions.height)
        let height = Double(dimensions.width)
        let size = ["width": width, "height": height]
        let answer: [String : Any?] = ["textureId": textureId, "size": size, "torchable": captureDevice.hasTorch]
        result(answer)
    }
    
    private func setupBarcodeCapturing(_ result: @escaping FlutterResult) {
        captureSession = AVCaptureSession()
        captureSession.beginConfiguration()
        
        setupResolution()
        
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
            if captureDevice.position == .front && connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }
        captureSession.commitConfiguration()
        captureSession.startRunning()
    }
    
    private func setupPictureCapturing(_ result: @escaping FlutterResult) {
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
                
                setupResolution()
                
                let connection = AVCaptureConnection(inputPorts: input.ports, output: videoOutput)
                connection.videoOrientation = videoOrientation
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
        }
    }
    
    private func setupResolution() {
        if resolutionPreset != nil &&
            captureDevice != nil &&
            captureSession.canSetSessionPreset(resolutionPreset) {
            if resolutionPreset == .high &&
                captureSession.canSetSessionPreset(.hd4K3840x2160) {
                resolutionPreset = .hd4K3840x2160
            }
            captureSession.sessionPreset = resolutionPreset
        }
    }
    
    private func setupDevice(_ position: AVCaptureDevice.Position, _ result: FlutterResult) {
        if #available(iOS 10.0, *) {
            captureDevice = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: position).devices.first
        } else {
            captureDevice = AVCaptureDevice.devices(for: .video).filter({$0.position == position}).first
        }
        if captureDevice == nil {
            result(FlutterError(code: "Capture device unavailable", message: "Unable to initialize a capture device", details: nil))
        }
        captureDevice.addObserver(self, forKeyPath: #keyPath(AVCaptureDevice.torchMode), options: .new, context: nil)
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
        flashMode = mapFlashMode(rawFlashMode)
        result(nil)
    }
    
    private func mapFlashMode(_ rawMode: Int) -> AVCaptureDevice.FlashMode {
        switch (rawMode) {
        case 0: return .off
        case 1: return .on
        default: return .auto
        }
    }
    
    private func mapResolutionPreset(_ rawMode: Int) -> AVCaptureSession.Preset {
        switch (ResolutionPreset(fromRawValue: rawMode)) {
        case .max:
            fallthrough
        case .ultraHigh:
            return AVCaptureSession.Preset.high
        case .veryHigh:
            return AVCaptureSession.Preset.hd1920x1080
        case .high:
            return AVCaptureSession.Preset.hd1280x720
        case .medium:
            return AVCaptureSession.Preset.vga640x480
        case .low:
            return AVCaptureSession.Preset.cif352x288
        }
    }
    
    private func mapVideoOrientation(_ rawMode: Int) -> AVCaptureVideoOrientation {
        switch (CameraRotation(fromRawValue: rawMode)) {
        case .rotation90:
            return .landscapeRight
        case .rotation180:
            return .portraitUpsideDown
        case .rotation270:
            return .landscapeLeft
        case .rotation0:
            fallthrough
        default:
            return .portrait
        }
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
        return path
    }
}

@available(iOS 11.0, *)
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
