package dev.yanshouwang.camerax

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import android.util.Size
import android.view.Surface
import androidx.annotation.IntDef
import androidx.annotation.NonNull
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.common.InputImage
import io.flutter.plugin.common.*
import io.flutter.view.TextureRegistry
import java.io.File
import java.text.SimpleDateFormat
import java.util.*

enum class ResolutionPreset(val value: Int) {
    LOW(0), MEDIUM(1), HIGH(2), VERY_HIGH(3), ULTRA_HIGH(4), MAX(5);

    companion object {
        fun fromInt(value: Int) = values().first { it.value == value }
    }
}

class CameraXHandler(private val activity: Activity, private val textureRegistry: TextureRegistry) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener {

    companion object {
        private const val REQUEST_CODE = 19930430
        private const val IMAGE_FILE_EXTENSION = ".jpg"
        private const val IMAGE_FILE_NAME_DATE_FORMAT = "yyyy-MM-dd-HH-mm-ss-SSS"
        private const val IMAGES_DIRECTORY_NAME = "camera"
    }

    private lateinit var imageCapture: ImageCapture
    private var sink: EventChannel.EventSink? = null
    private var listener: PluginRegistry.RequestPermissionsResultListener? = null

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null

    @AnalyzeMode
    private var analyzeMode: Int = AnalyzeMode.NONE

    private var captureMode = ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY
    private var flashMode = ImageCapture.FLASH_MODE_AUTO
    private var targetResolution = Size(720, 1280)

    @ExperimentalGetImage
    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: MethodChannel.Result) {
        when (call.method) {
            "state" -> stateNative(result)
            "request" -> requestNative(result)
            "start" -> startNative(call, result)
            "torch" -> torchNative(call, result)
            "analyze" -> analyzeNative(call, result)
            "stop" -> stopNative(result)
            "flash" -> flashModeNative(call, result)
            "capture" -> captureNative(result)
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        this.sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>?,
        grantResults: IntArray?
    ): Boolean {
        return listener?.onRequestPermissionsResult(requestCode, permissions, grantResults) ?: false
    }

    private fun stateNative(result: MethodChannel.Result) {
        // Can't get exact denied or not_determined state without request. Just return not_determined when state isn't authorized
        val state =
            if (ContextCompat.checkSelfPermission(
                    activity,
                    Manifest.permission.CAMERA
                ) == PackageManager.PERMISSION_GRANTED
            ) 1
            else 0
        result.success(state)
    }

    private fun requestNative(result: MethodChannel.Result) {
        listener = PluginRegistry.RequestPermissionsResultListener { requestCode, _, grantResults ->
            if (requestCode != REQUEST_CODE) {
                false
            } else {
                val authorized = grantResults[0] == PackageManager.PERMISSION_GRANTED
                result.success(authorized)
                listener = null
                true
            }
        }
        val permissions = arrayOf(Manifest.permission.CAMERA)
        ActivityCompat.requestPermissions(activity, permissions, REQUEST_CODE)
    }

    @ExperimentalGetImage
    private fun startNative(call: MethodCall, result: MethodChannel.Result) {
        try {
            val facingIndex: Int? = call.argument<Int>("camera_index")
            val cameraType: Int? = call.argument<Int>("camera_type")!!
            val captureMode: Int? = call.argument<Int>("camera_capture_mode")
            val flashMode: Int? = call.argument<Int>("camera_flash_mode")
            val resolutionPreset: Int? = call.argument<Int>("camera_resolution")
            flashMode?.let { this.flashMode = it }
            captureMode?.let { this.captureMode = it }
            resolutionPreset?.let {
                this.targetResolution = targetResolution(ResolutionPreset.fromInt(it))
            }
            val selector = CameraSelector.Builder().requireLensFacing(facingIndex!!).build()
            when (CameraType.values()[cameraType!!]) {
                CameraType.PICTURE -> prepareCapture(result, selector)
                CameraType.BARCODE -> prepareBarCode(result, selector)
            }
        } catch (e: IllegalArgumentException) {
            result.error(
                "Unsupported setup",
                "Missing or unsupported values for CameraType or CameraLensFacing index",
                e.message
            )
        }
    }

    private fun prepareCapture(result: MethodChannel.Result, selector: CameraSelector) {
        val future = ProcessCameraProvider.getInstance(activity)
        val executor = ContextCompat.getMainExecutor(activity)
        future.addListener({
            cameraProvider = future.get()
            textureEntry = textureRegistry.createSurfaceTexture()
            val textureId = textureEntry!!.id()
            imageCapture = ImageCapture.Builder()
                .setCaptureMode(captureMode)
                .setFlashMode(flashMode)
                .setTargetResolution(targetResolution)
                .build()

            val surfaceProvider = Preview.SurfaceProvider { request ->
                val resolution = request.resolution
                val texture = textureEntry!!.surfaceTexture()
                texture.setDefaultBufferSize(resolution.width, resolution.height)
                val surface = Surface(texture)
                request.provideSurface(surface, executor, { })
            }
            val preview = Preview.Builder().build().apply { setSurfaceProvider(surfaceProvider) }
            camera = cameraProvider?.bindToLifecycle(
                activity as LifecycleOwner,
                selector,
                imageCapture,
                preview
            )
            result.success(answers(preview, textureId))
        }, executor)
    }

    private fun captureNative(result: MethodChannel.Result) {
        val outputFile = createOutputFile()
        val outputConfig = ImageCapture.OutputFileOptions.Builder(outputFile)
            .build()
        val cameraExecutor = ContextCompat.getMainExecutor(activity)
        imageCapture.flashMode = flashMode
        imageCapture.takePicture(
            outputConfig,
            cameraExecutor,
            onImageSavedCallback(result)
        )
    }

    private fun onImageSavedCallback(result: MethodChannel.Result) =
        object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                result.success(mapOf("path" to outputFileResults.savedUri?.path))
            }

            override fun onError(exception: ImageCaptureException) {
                result.error(
                    "CAPERR ${exception.imageCaptureError}",
                    exception.localizedMessage,
                    exception.message
                )
            }
        }

    @ExperimentalGetImage
    private fun prepareBarCode(
        result: MethodChannel.Result,
        selector: CameraSelector
    ) {
        val future = ProcessCameraProvider.getInstance(activity)
        val executor = ContextCompat.getMainExecutor(activity)
        future.addListener({
            cameraProvider = future.get()
            textureEntry = textureRegistry.createSurfaceTexture()
            val textureId = textureEntry!!.id()
            // Preview
            val surfaceProvider = Preview.SurfaceProvider { request ->
                val resolution = request.resolution
                val texture = textureEntry!!.surfaceTexture()
                texture.setDefaultBufferSize(resolution.width, resolution.height)
                val surface = Surface(texture)
                request.provideSurface(surface, executor, { })
            }
            val preview = Preview.Builder().build().apply { setSurfaceProvider(surfaceProvider) }
            // Analyzer

            val analyzer = barcodeAnalyzer()
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build().apply { setAnalyzer(executor, analyzer) }

            // Bind to lifecycle.
            val owner = activity as LifecycleOwner
            camera = cameraProvider!!.bindToLifecycle(owner, selector, preview, analysis)
            camera!!.cameraInfo.torchState.observe(owner, { state ->
                // TorchState.OFF = 0; TorchState.ON = 1
                val event = mapOf("name" to "torchState", "data" to state)
                sink?.success(event)
            })

            val answer = answers(preview, textureId)
            result.success(answer)
        }, executor)
    }

    private fun answers(
        preview: Preview,
        textureId: Long
    ): Map<String, Any> {
        // TODO: seems there's not a better way to get the final resolution
        @SuppressLint("RestrictedApi")
        val resolution = preview.attachedSurfaceResolution!!
        val portrait = camera!!.cameraInfo.sensorRotationDegrees % 180 == 0
        val width = resolution.width.toDouble()
        val height = resolution.height.toDouble()
        val size = if (portrait) mapOf(
            "width" to width,
            "height" to height
        ) else mapOf("width" to height, "height" to width)
        return mapOf("textureId" to textureId, "size" to size, "torchable" to camera!!.torchable)
    }

    private fun torchNative(call: MethodCall, result: MethodChannel.Result) {
        val state = call.arguments == 1
        camera!!.cameraControl.enableTorch(state)
        result.success(null)
    }

    private fun analyzeNative(call: MethodCall, result: MethodChannel.Result) {
        analyzeMode = call.arguments as Int
        result.success(null)
    }

    private fun flashModeNative(call: MethodCall, result: MethodChannel.Result) {
        flashMode = flashRawValueToMode(call.arguments as Int)
        result.success(null)
    }

    private fun flashRawValueToMode(raw: Int): Int {
        return when (raw) {
            0 -> ImageCapture.FLASH_MODE_OFF
            1 -> ImageCapture.FLASH_MODE_ON
            else -> ImageCapture.FLASH_MODE_AUTO
        }
    }

    private fun stopNative(result: MethodChannel.Result) {
        val owner = activity as LifecycleOwner
        camera!!.cameraInfo.torchState.removeObservers(owner)
        cameraProvider!!.unbindAll()
        textureEntry!!.release()

        analyzeMode = AnalyzeMode.NONE
        camera = null
        textureEntry = null
        cameraProvider = null

        result.success(null)
    }

    @ExperimentalGetImage
    private fun barcodeAnalyzer() = ImageAnalysis.Analyzer { imageProxy -> // YUV_420_888 format
        when (analyzeMode) {
            AnalyzeMode.BARCODE -> {
                val mediaImage = imageProxy.image ?: return@Analyzer
                val inputImage = InputImage.fromMediaImage(
                    mediaImage,
                    imageProxy.imageInfo.rotationDegrees
                )
                val scanner = BarcodeScanning.getClient()
                scanner.process(inputImage)
                    .addOnSuccessListener { barcodes ->
                        for (barcode in barcodes) {
                            val event = mapOf("name" to "barcode", "data" to barcode.data)
                            sink?.success(event)
                        }
                    }
                    .addOnFailureListener { e -> Log.e(TAG, e.message, e) }
                    .addOnCompleteListener { imageProxy.close() }
            }
            else -> imageProxy.close()
        }
    }

    private fun targetResolution(raw: ResolutionPreset): Size {
        return when (raw) {
            ResolutionPreset.MAX,
            ResolutionPreset.ULTRA_HIGH -> Size(2160, 3840)
            ResolutionPreset.VERY_HIGH -> Size(1080, 1920)
            ResolutionPreset.HIGH -> Size(720, 1280)
            ResolutionPreset.MEDIUM -> Size(480, 640)
            else -> Size(288, 352)
        }
    }

    private fun createOutputFile(): File {
        val outputDirectory = getOutputDirectory(activity)
        return createFile(outputDirectory, IMAGE_FILE_NAME_DATE_FORMAT, IMAGE_FILE_EXTENSION)
    }

    private fun createFile(baseFolder: File, format: String, extension: String) =
        File(
            baseFolder, SimpleDateFormat(format, Locale.US)
                .format(System.currentTimeMillis()) + extension
        )

    private fun getOutputDirectory(context: Context): File {
        val appContext = context.applicationContext
        val mediaDir = context.externalCacheDir?.let {
            File(it, IMAGES_DIRECTORY_NAME).apply { mkdirs() }
        }
        return if (mediaDir != null && mediaDir.exists())
            mediaDir else appContext.filesDir
    }
}

@IntDef(AnalyzeMode.NONE, AnalyzeMode.BARCODE)
@Target(AnnotationTarget.FIELD)
@Retention(AnnotationRetention.SOURCE)
annotation class AnalyzeMode {
    companion object {
        const val NONE = 0
        const val BARCODE = 1
    }
}