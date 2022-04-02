package dev.yanshouwang.camerax

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.util.Size
import android.view.Surface
import androidx.annotation.IntDef
import androidx.annotation.NonNull
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry
import java.io.File
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.Executor

enum class ResolutionPreset(val value: Int) {
    LOW(0), MEDIUM(1), HIGH(2), VERY_HIGH(3), ULTRA_HIGH(4), MAX(5);

    companion object {
        fun fromInt(value: Int) = values().first { it.value == value }
    }
}

enum class PhotoRotation(val value: Int) {
    ROTATION_0(0),
    ROTATION_90(1),
    ROTATION_180(2),
    ROTATION_270(3),
    ROTATION_UNSET(4);

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

        private const val CAMERA_INDEX = "camera_index"
        private const val CAMERA_TYPE = "camera_type"
        private const val CAMERA_RESOLUTION = "camera_resolution"
        private const val CAMERA_ROTATION = "camera_photo_rotation"
        private const val CAMERA_CAPTURE_MODE = "camera_capture_mode"
        private const val CAMERA_FLASH_MODE = "camera_flash_mode"
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
    private var targetRotation = PhotoRotation.ROTATION_UNSET

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
            val facingIndex: Int = call.argument<Int>(CAMERA_INDEX)!!
            val cameraTypeIndex: Int = call.argument<Int>(CAMERA_TYPE)!!
            val captureMode: Int? = call.argument<Int>(CAMERA_CAPTURE_MODE)
            val flashMode: Int? = call.argument<Int>(CAMERA_FLASH_MODE)
            val resolutionPreset: Int? = call.argument<Int>(CAMERA_RESOLUTION)
            val targetRotation: Int? = call.argument<Int>(CAMERA_ROTATION)
            flashMode?.let { this.flashMode = it }
            captureMode?.let { this.captureMode = it }
            resolutionPreset?.let {
                this.targetResolution = targetResolution(ResolutionPreset.fromInt(it))
            }
            targetRotation?.let { this.targetRotation = PhotoRotation.fromInt(it) }
            val selector = CameraSelector.Builder().requireLensFacing(facingIndex).build()
            when (val cameraType: CameraType = CameraType.values()[cameraTypeIndex]) {
                CameraType.PICTURE -> prepareCapture(result, selector)
                else -> result.error(
                        "Unsupported camera type $cameraType",
                        "CameraType must be one of CameraType options",
                        "Check CameraX plugin repository and use appropriate branch"
                )
            }
        } catch (e: NullPointerException) {
            result.error(
                    "Unsupported setup",
                    "Missing or unsupported values for CameraType or CameraLensFacing index",
                    e.message
            )
        } catch (e: ClassCastException) {
            result.error(
                    "Unsupported types",
                    "Values must be sent in a correct format or type",
                    e.message
            )
        }
    }

    private fun prepareCapture(result: MethodChannel.Result, camSelector: CameraSelector) {
        execute(result, camSelector) { cameraProvider, selector, executor ->
            imageCapture = ImageCapture.Builder()
                    .setCaptureMode(captureMode)
                    .setFlashMode(flashMode)
                    .setTargetResolution(targetResolution)
                    .build()

            if (targetRotation != PhotoRotation.ROTATION_UNSET) {
                imageCapture.targetRotation = targetRotation.value
            }
            initCamera(cameraProvider, executor, selector, imageCapture)
        }
    }

    private fun execute(
            result: MethodChannel.Result,
            selector: CameraSelector,
            prepare: (cameraProvider: ProcessCameraProvider, selector: CameraSelector, executor: Executor) -> Preview
    ) {
        val future = ProcessCameraProvider.getInstance(activity)
        val executor = ContextCompat.getMainExecutor(activity)
        future.addListener({
            val preview = prepare(future.get(), selector, executor)
            result.success(answers(preview))
        }, executor)
    }

    private fun initCamera(
            cameraProvider: ProcessCameraProvider,
            executor: Executor,
            selector: CameraSelector,
            useCase: UseCase
    ): Preview {
        this.cameraProvider = cameraProvider
        textureEntry = textureRegistry.createSurfaceTexture()

        val surfaceProvider = Preview.SurfaceProvider { request ->
            val resolution = request.resolution
            val texture = textureEntry!!.surfaceTexture()
            texture.setDefaultBufferSize(resolution.width, resolution.height)
            val surface = Surface(texture)
            request.provideSurface(surface, executor) { }
        }

        val preview = Preview.Builder().build().apply { setSurfaceProvider(surfaceProvider) }
        camera = cameraProvider.bindToLifecycle(
                activity as LifecycleOwner,
                selector,
                preview,
                useCase
        )
        return preview
    }

    private fun captureNative(result: MethodChannel.Result) {
        val outputFile = createFile()
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
                            "Capture Error code ${exception.imageCaptureError}",
                            exception.message,
                            null
                    )
                }
            }

    private fun answers(
            preview: Preview,
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
        return mapOf(
                "textureId" to textureEntry?.id()!!,
                "size" to size,
                "torchable" to camera!!.torchable
        )
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
        flashMode = when (call.arguments as Int) {
            0 -> ImageCapture.FLASH_MODE_OFF
            1 -> ImageCapture.FLASH_MODE_ON
            else -> ImageCapture.FLASH_MODE_AUTO
        }
        result.success(null)
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

    /**
     * Returns a Size for selected resolution preset.
     * Any unknown preset defaults to MAX.
     */
    private fun targetResolution(raw: ResolutionPreset): Size {
        return when (raw) {
            ResolutionPreset.VERY_HIGH -> Size(1080, 1920)
            ResolutionPreset.HIGH -> Size(720, 1280)
            ResolutionPreset.MEDIUM -> Size(480, 640)
            ResolutionPreset.LOW -> Size(288, 352)
            else -> Size(2160, 3840)
        }
    }

    private fun createFile(): File {
        val baseFolder = getOutputDirectory(activity)
        return File(
                baseFolder, SimpleDateFormat(IMAGE_FILE_NAME_DATE_FORMAT, Locale.US)
                .format(System.currentTimeMillis()) + IMAGE_FILE_EXTENSION
        )
    }

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