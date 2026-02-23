import AVFoundation
import Foundation
import Metal

public protocol CameraDelegate {
    func didCaptureBuffer(_ sampleBuffer: CMSampleBuffer)
}

public enum PhysicalCameraLocation {
    case backFacing
    case frontFacing

    func imageOrientation() -> ImageOrientation {
        switch self {
        case .backFacing: return .landscapeRight
        #if os(iOS)
            case .frontFacing: return .landscapeLeft
        #else
            case .frontFacing: return .portrait
        #endif
        }
    }

    func captureDevicePosition() -> AVCaptureDevice.Position {
        switch self {
        case .backFacing: return .back
        case .frontFacing: return .front
        }
    }

    func device() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.devices(for: AVMediaType.video)
        for case let device in devices {
            if device.position == self.captureDevicePosition() {
                return device
            }
        }

        return AVCaptureDevice.default(for: AVMediaType.video)
    }
}

public struct CameraError: Error {
}

final class CMSampleBufferStorage {
    enum MediaType {
        case video
        case audio
    }

    private var _capacity:Int
    public var capacity: Int {
        get { _capacity }
        set {
            guard newValue != capacity else { return }
            
            queue.sync {
                videoSamples.removeAll()
                audioSamples.removeAll()
                hasReachedCapacity = false
                
                _capacity = newValue
            }
        }
    }

    private var videoSamples: [CMSampleBuffer] = []
    private var audioSamples: [CMSampleBuffer] = []
    private var hasReachedCapacity = false

    private let queue = DispatchQueue(
        label: "CMSampleBufferStorage.queue",
        qos: .userInitiated
    )

    init(capacity: Int) {
        self._capacity = capacity
    }

    func push(_ buffer: CMSampleBuffer?, type: MediaType) -> CMSampleBuffer? {
        return queue.sync {
            guard capacity > 0 else { return buffer }
            guard let buffer else { return nil }

            switch type {
            case .video:
                videoSamples.append(buffer)

                if !hasReachedCapacity {
                    if videoSamples.count >= capacity {
                        hasReachedCapacity = true
                    } else {
                        return nil
                    }
                }

                return videoSamples.isEmpty ? nil : videoSamples.removeFirst()

            case .audio:
                audioSamples.append(buffer)

                // While video is still buffering, audio buffers too.
                guard hasReachedCapacity else { return nil }

                return audioSamples.isEmpty ? nil : audioSamples.removeFirst()
            }
        }
    }

    func reset() {
        queue.sync {
            videoSamples.removeAll()
            audioSamples.removeAll()
            hasReachedCapacity = false
        }
    }
}

let initialBenchmarkFramesToIgnore = 5

public extension Camera {
    public var verticalFOV:Double {
        #if os(iOS)
        let format = inputCamera.activeFormat
        let fovX = Float(format.videoFieldOfView) * .pi / 180 // radians
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        
        let width = Float(dimensions.width)
        let height = Float(dimensions.height)

        let aspect = height / width
        let fovY = 2 * atan(aspect * tan(fovX / 2))
        
        return Double(orientation == .portrait || orientation == .portraitUpsideDown ? fovX : fovY)
        #else
        return .nan
        #endif
        //return FOV(horizontal: fovX, vertical: fovY)
    }

    public var fps:(min: Double, max: Double) {
        return (min: 1.0 / inputCamera.activeVideoMinFrameDuration.seconds, max: 1.0 / inputCamera.activeVideoMaxFrameDuration.seconds)
    }
}

public class Camera: NSObject, ImageSource, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    public var location: PhysicalCameraLocation {
        didSet {
            // TODO: Swap the camera locations, framebuffers as needed
        }
    }
    public var runBenchmark: Bool = false
    public var logFPS: Bool = false

    public let targets = TargetContainer()
    public var delegate: CameraDelegate?
    public let captureSession: AVCaptureSession
    public var orientation: ImageOrientation?
    public let inputCamera: AVCaptureDevice!
    public let videoInput: AVCaptureDeviceInput!
    public let videoOutput: AVCaptureVideoDataOutput!
    var videoTextureCache: CVMetalTextureCache?
    
    var microphone:AVCaptureDevice?
    var audioInput:AVCaptureDeviceInput?
    var audioOutput:AVCaptureAudioDataOutput?
    
    public var audioEncodingTarget:AudioEncodingTarget? {
        didSet {
            guard let audioEncodingTarget = audioEncodingTarget else {
                self.removeAudioInputsAndOutputs()
                return
            }
            do {
                try self.addAudioInputsAndOutputs()
                audioEncodingTarget.activateAudioTrack()
            } catch {
                fatalError("ERROR: Could not connect audio target with error: \(error)")
            }
        }
    }

    var supportsFullYUVRange: Bool = false
    let captureAsYUV: Bool
    let yuvConversionRenderPipelineState: MTLRenderPipelineState?
    var yuvLookupTable: [String: (Int, MTLStructMember)] = [:]
    var yuvBufferSize: Int = 0
    var conversionTexture:Texture? = nil

    let frameRenderingSemaphore = DispatchSemaphore(value: 1)
    //let cameraProcessingQueue = DispatchQueue.global()
    let cameraProcessingQueue = DispatchQueue(
        label: "com.sunsetlakesoftware.GPUImage.cameraProcessingQueue",
        qos: .userInteractive,
        attributes: [])
    
    let cameraFrameProcessingQueue = DispatchQueue(
        label: "com.sunsetlakesoftware.GPUImage.cameraFrameProcessingQueue",
        qos: .userInteractive,
        attributes: [])

    let audioProcessingQueue:DispatchQueue = DispatchQueue(
        label: "com.sunsetlakesoftware.GPUImage.audioProcessingQueue",
        qos: .userInteractive,
        attributes: [])
    
    let framesToIgnore = 5
    var numberOfFramesCaptured = 0
    var totalFrameTimeDuringCapture: Double = 0.0
    var framesSinceLastCheck = 0
    var lastCheckTime = CFAbsoluteTimeGetCurrent()

    var sampleStorage = CMSampleBufferStorage(capacity: 0)
    public var videoFrameDelay:Int {
        set {
            sampleStorage.capacity = newValue
        }
        
        get {
            return sampleStorage.capacity
        }
    }
    
    public init(
        sessionPreset: AVCaptureSession.Preset, cameraDevice: AVCaptureDevice? = nil,
        location: PhysicalCameraLocation = .backFacing, orientation: ImageOrientation? = nil,
        captureAsYUV: Bool = true
    ) throws {
        self.location = location
        self.orientation = orientation

        self.captureSession = AVCaptureSession()
        self.captureSession.beginConfiguration()

        self.captureAsYUV = captureAsYUV

        if let cameraDevice = cameraDevice {
            self.inputCamera = cameraDevice
        } else {
            if let device = location.device() {
                self.inputCamera = device
            } else {
                self.videoInput = nil
                self.videoOutput = nil
                self.inputCamera = nil
                self.yuvConversionRenderPipelineState = nil
                super.init()
                throw CameraError()
            }
        }

        do {
            self.videoInput = try AVCaptureDeviceInput(device: inputCamera)
        } catch {
            self.videoInput = nil
            self.videoOutput = nil
            self.yuvConversionRenderPipelineState = nil
            super.init()
            throw error
        }

        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        }

        // Add the video frame output
        videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = false

        if captureAsYUV {
            supportsFullYUVRange = false
            let supportedPixelFormats = videoOutput.availableVideoPixelFormatTypes
            for currentPixelFormat in supportedPixelFormats {
                if (currentPixelFormat as NSNumber).int32Value
                    == Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                {
                    supportsFullYUVRange = true
                }
            }
            if supportsFullYUVRange {
                let (pipelineState, lookupTable, bufferSize) = generateRenderPipelineState(
                    device: sharedMetalRenderingDevice, vertexFunctionName: "twoInputVertex",
                    fragmentFunctionName: "yuvConversionFullRangeFragment",
                    operationName: "YUVToRGB")
                self.yuvConversionRenderPipelineState = pipelineState
                self.yuvLookupTable = lookupTable
                self.yuvBufferSize = bufferSize
                videoOutput.videoSettings = [
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferPixelFormatTypeKey as String: NSNumber(
                        value: Int32(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)),
                ]
            } else {
                let (pipelineState, lookupTable, bufferSize) = generateRenderPipelineState(
                    device: sharedMetalRenderingDevice, vertexFunctionName: "twoInputVertex",
                    fragmentFunctionName: "yuvConversionVideoRangeFragment",
                    operationName: "YUVToRGB")
                self.yuvConversionRenderPipelineState = pipelineState
                self.yuvLookupTable = lookupTable
                self.yuvBufferSize = bufferSize
                videoOutput.videoSettings = [
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferPixelFormatTypeKey as String: NSNumber(
                        value: Int32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)),
                ]
            }
        } else {
            self.yuvConversionRenderPipelineState = nil
            videoOutput.videoSettings = [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(
                    value: Int32(kCVPixelFormatType_32BGRA)),
            ]
        }

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        captureSession.sessionPreset = sessionPreset
        captureSession.commitConfiguration()

        super.init()

        let _ = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, sharedMetalRenderingDevice.device, nil, &videoTextureCache)

        videoOutput.setSampleBufferDelegate(self, queue: cameraProcessingQueue)
    }

    deinit {
        cameraFrameProcessingQueue.sync {
            self.stopCapture()
            self.videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        }
    }

    public func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let sampleBuffer = sampleStorage.push(sampleBuffer, type: output != audioOutput ? .video : .audio) else { return }
        
        guard (output != audioOutput) else {
            self.processAudioSampleBuffer(sampleBuffer)
            return
        }
        
        guard
            frameRenderingSemaphore.wait(timeout: DispatchTime.now())
                == DispatchTimeoutResult.success
        else { return }

        let startTime = CFAbsoluteTimeGetCurrent()

        let cameraFrame = CMSampleBufferGetImageBuffer(sampleBuffer)!
        let bufferWidth = CVPixelBufferGetWidth(cameraFrame)
        let bufferHeight = CVPixelBufferGetHeight(cameraFrame)
        let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        CVPixelBufferLockBaseAddress(
            cameraFrame, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))

        cameraFrameProcessingQueue.async {
            self.delegate?.didCaptureBuffer(sampleBuffer)
            CVPixelBufferUnlockBaseAddress(
                cameraFrame, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))

            let orientation = self.orientation ?? self.location.imageOrientation()
            
            let texture: Texture?
            if self.captureAsYUV {
                var luminanceTextureRef: CVMetalTexture? = nil
                var chrominanceTextureRef: CVMetalTexture? = nil
                // Luminance plane
                let _ = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, self.videoTextureCache!, cameraFrame, nil, .r8Unorm,
                    bufferWidth, bufferHeight, 0, &luminanceTextureRef)
                // Chrominance plane
                let _ = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, self.videoTextureCache!, cameraFrame, nil, .rg8Unorm,
                    bufferWidth / 2, bufferHeight / 2, 1, &chrominanceTextureRef)

                if let concreteLuminanceTextureRef = luminanceTextureRef,
                    let concreteChrominanceTextureRef = chrominanceTextureRef,
                    let luminanceTexture = CVMetalTextureGetTexture(concreteLuminanceTextureRef),
                    let chrominanceTexture = CVMetalTextureGetTexture(concreteChrominanceTextureRef)
                {

                    let conversionMatrix: Matrix3x3
                    if self.supportsFullYUVRange {
                        conversionMatrix = colorConversionMatrix601FullRangeDefault
                    } else {
                        conversionMatrix = colorConversionMatrix601Default
                    }

                    let outputWidth: Int
                    let outputHeight: Int
                    
                    if self.location.imageOrientation().rotationNeeded(for: orientation).flipsDimensions() {
                        outputWidth = bufferHeight
                        outputHeight = bufferWidth
                    } else {
                        outputWidth = bufferWidth
                        outputHeight = bufferHeight
                    }

                    if self.conversionTexture?.texture.width != outputWidth || self.conversionTexture?.texture.height != outputHeight {
                        self.conversionTexture = Texture(
                            device: sharedMetalRenderingDevice.device, orientation: orientation,
                            width: outputWidth, height: outputHeight,
                            timingStyle: .videoFrame(timestamp: Timestamp(currentTime)))
                    }
                    else if self.conversionTexture?.orientation != orientation {
                        self.conversionTexture?.orientation = orientation
                    }
                    
                    self.conversionTexture?.timingStyle = .videoFrame(timestamp: Timestamp(currentTime))
                    
                    convertYUVToRGB(
                        pipelineState: self.yuvConversionRenderPipelineState!,
                        lookupTable: self.yuvLookupTable, bufferSize: self.yuvBufferSize,
                        luminanceTexture: Texture(
                            orientation: self.location.imageOrientation(),
                            texture: luminanceTexture),
                        chrominanceTexture: Texture(
                            orientation: self.location.imageOrientation(),
                            texture: chrominanceTexture),
                        resultTexture: self.conversionTexture!, colorConversionMatrix: conversionMatrix)
                    texture = self.conversionTexture!
                } else {
                    texture = nil
                }
            } else {
                var textureRef: CVMetalTexture? = nil
                let _ = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, self.videoTextureCache!, cameraFrame, nil, .bgra8Unorm,
                    bufferWidth, bufferHeight, 0, &textureRef)
                if let concreteTexture = textureRef,
                    let cameraTexture = CVMetalTextureGetTexture(concreteTexture)
                {
                    texture = Texture(
                        orientation: self.orientation ?? self.location.imageOrientation(),
                        texture: cameraTexture,
                        timingStyle: .videoFrame(timestamp: Timestamp(currentTime)))
                } else {
                    texture = nil
                }
            }

            if texture != nil {
                self.updateTargetsWithTexture(texture!)
            }

            if self.runBenchmark {
                self.numberOfFramesCaptured += 1
                if self.numberOfFramesCaptured > initialBenchmarkFramesToIgnore {
                    let currentFrameTime = (CFAbsoluteTimeGetCurrent() - startTime)
                    self.totalFrameTimeDuringCapture += currentFrameTime
                    print(
                        "Average frame time : \(1000.0 * self.totalFrameTimeDuringCapture / Double(self.numberOfFramesCaptured - initialBenchmarkFramesToIgnore)) ms"
                    )
                    print("Current frame time : \(1000.0 * currentFrameTime) ms")
                }
            }

            if self.logFPS {
                if (CFAbsoluteTimeGetCurrent() - self.lastCheckTime) > 1.0 {
                    self.lastCheckTime = CFAbsoluteTimeGetCurrent()
                    print("FPS: \(self.framesSinceLastCheck)")
                    self.framesSinceLastCheck = 0
                }

                self.framesSinceLastCheck += 1
            }

            self.frameRenderingSemaphore.signal()
        }
    }

    public func startCapture() {
        let _ = frameRenderingSemaphore.wait(timeout: DispatchTime.distantFuture)
        self.numberOfFramesCaptured = 0
        self.totalFrameTimeDuringCapture = 0
        self.frameRenderingSemaphore.signal()

        if !captureSession.isRunning {
            captureSession.startRunning()
        }
    }

    public func stopCapture() {
        if captureSession.isRunning {
            let _ = frameRenderingSemaphore.wait(timeout: DispatchTime.distantFuture)

            captureSession.stopRunning()
            self.frameRenderingSemaphore.signal()
        }
    }

    public func transmitPreviousImage(to target: ImageConsumer, atIndex: UInt) {
        // Not needed for camera
    }
    
    // MARK: -
    // MARK: Audio processing
    
    func addAudioInputsAndOutputs() throws {
        guard (self.audioOutput == nil) else { return }
        
        captureSession.beginConfiguration()
        defer {
            captureSession.commitConfiguration()
        }
        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            return
        }
        let audioInput = try AVCaptureDeviceInput(device:microphone)
        if captureSession.canAddInput(audioInput) {
           captureSession.addInput(audioInput)
        }
        let audioOutput = AVCaptureAudioDataOutput()
        if captureSession.canAddOutput(audioOutput) {
            captureSession.addOutput(audioOutput)
        }
        self.microphone = microphone
        self.audioInput = audioInput
        self.audioOutput = audioOutput
        audioOutput.setSampleBufferDelegate(self, queue:audioProcessingQueue)
    }
    
    func removeAudioInputsAndOutputs() {
        guard (audioOutput != nil) else { return }
        
        captureSession.beginConfiguration()
        captureSession.removeInput(audioInput!)
        captureSession.removeOutput(audioOutput!)
        audioInput = nil
        audioOutput = nil
        microphone = nil
        captureSession.commitConfiguration()
    }
    
    func processAudioSampleBuffer(_ sampleBuffer:CMSampleBuffer) {
        self.audioEncodingTarget?.processAudioBuffer(sampleBuffer)
    }
}
