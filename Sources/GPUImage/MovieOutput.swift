import AVFoundation
import CoreLocation

public protocol AudioEncodingTarget {
    func activateAudioTrack()
    func processAudioBuffer(_ sampleBuffer: CMSampleBuffer)
}

public class MovieOutput: ImageConsumer, AudioEncodingTarget {
    public let sources = SourceContainer()
    public let maximumInputs: UInt = 1

    let assetWriter: AVAssetWriter
    let assetWriterVideoInput: AVAssetWriterInput
    var assetWriterAudioInput: AVAssetWriterInput?

    let assetWriterPixelBufferInput: AVAssetWriterInputPixelBufferAdaptor
    let size: Size
    private var isRecording = false
    private var videoEncodingIsFinished = false
    private var audioEncodingIsFinished = false
    private var startTime: CMTime?
    private var previousFrameTime = CMTime.negativeInfinity
    private var previousAudioTime = CMTime.negativeInfinity
    private var encodingLiveVideo: Bool
    var pixelBuffer: CVPixelBuffer? = nil

    var renderPipelineState: MTLRenderPipelineState!

    var transform: CGAffineTransform {
        get {
            return assetWriterVideoInput.transform
        }
        set {
            assetWriterVideoInput.transform = newValue
        }
    }
    
    public var readyForNextVideoFrame: Bool {
        return assetWriterVideoInput.expectsMediaDataInRealTime || assetWriterVideoInput.isReadyForMoreMediaData
    }
    
    public var readyForNextAudioFrame: Bool {
        return (assetWriterAudioInput?.expectsMediaDataInRealTime ?? true) || (assetWriterAudioInput?.isReadyForMoreMediaData ?? true)
    }
    
    private var outputTexture: Texture? = nil

    public init(
        URL: Foundation.URL, size: Size, fileType: AVFileType = AVFileType.mov,
        liveVideo: Bool = false, settings: [String: AnyObject]? = nil
    ) throws {
        self.size = size
        assetWriter = try AVAssetWriter(url: URL, fileType: fileType)
        // Set this to make sure that a functional movie is produced, even if the recording is cut off mid-stream. Only the last second should be lost in that case.
        assetWriter.movieFragmentInterval = CMTimeMakeWithSeconds(1.0, preferredTimescale: 1000)

        var localSettings: [String: AnyObject]
        if let settings = settings {
            localSettings = settings
        } else {
            localSettings = [String: AnyObject]()
        }

        localSettings[AVVideoWidthKey] =
            localSettings[AVVideoWidthKey] ?? NSNumber(value: size.width)
        localSettings[AVVideoHeightKey] =
            localSettings[AVVideoHeightKey] ?? NSNumber(value: size.height)
        localSettings[AVVideoCodecKey] =
            localSettings[AVVideoCodecKey] ?? AVVideoCodecH264 as NSString

        assetWriterVideoInput = AVAssetWriterInput(
            mediaType: AVMediaType.video, outputSettings: localSettings)
        assetWriterVideoInput.expectsMediaDataInRealTime = liveVideo
        encodingLiveVideo = liveVideo

        let sourcePixelBufferAttributesDictionary: [String: AnyObject] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(
                value: Int32(kCVPixelFormatType_32BGRA)),
            kCVPixelBufferWidthKey as String: NSNumber(value: size.width),
            kCVPixelBufferHeightKey as String: NSNumber(value: size.height),
        ]

        assetWriterPixelBufferInput = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: assetWriterVideoInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributesDictionary)
        assetWriter.add(assetWriterVideoInput)

        let (pipelineState, _, _) = generateRenderPipelineState(
            device: sharedMetalRenderingDevice, vertexFunctionName: "oneInputVertex",
            fragmentFunctionName: "passthroughFragment", operationName: "RenderView")
        self.renderPipelineState = pipelineState
    }

    public func startRecording(transform: CGAffineTransform? = nil) {
        if let transform = transform {
            assetWriterVideoInput.transform = transform
        }
        startTime = nil
        self.isRecording = self.assetWriter.startWriting()
    }

    public func finishRecording(_ completionCallback: (() -> Void)? = nil) {
        self.isRecording = false

        if self.assetWriter.status == .completed || self.assetWriter.status == .cancelled
            || self.assetWriter.status == .unknown
        {
            DispatchQueue.global().async {
                completionCallback?()
            }
            return
        }
        if (self.assetWriter.status == .writing) && (!self.videoEncodingIsFinished) {
            self.videoEncodingIsFinished = true
            self.assetWriterVideoInput.markAsFinished()
        }
        if (self.assetWriter.status == .writing) && (!self.audioEncodingIsFinished) {
            self.audioEncodingIsFinished = true
            self.assetWriterAudioInput?.markAsFinished()
        }

        // Why can't I use ?? here for the callback?
        if let callback = completionCallback {
            self.assetWriter.finishWriting(completionHandler: callback)
        } else {
            self.assetWriter.finishWriting {}

        }
    }

    public func newTextureAvailable(_ texture: Texture, fromSourceIndex: UInt) {
        guard isRecording else { return }
        // Ignore still images and other non-video updates (do I still need this?)
        guard let frameTime = texture.timingStyle.timestamp?.asCMTime else { return }
        // If two consecutive times with the same value are added to the movie, it aborts recording, so I bail on that case
        guard frameTime != previousFrameTime else { return }

        if startTime == nil {
            if assetWriter.status != .writing {
                assetWriter.startWriting()
            }

            assetWriter.startSession(atSourceTime: frameTime)
            startTime = frameTime
        }

        // TODO: Run the following on an internal movie recording dispatch queue, context
        guard assetWriterVideoInput.isReadyForMoreMediaData || (!encodingLiveVideo) else {
            debugPrint("Had to drop a frame at time \(frameTime)")
            return
        }

        var pixelBufferFromPool: CVPixelBuffer? = nil

        let pixelBufferStatus = CVPixelBufferPoolCreatePixelBuffer(
            nil, assetWriterPixelBufferInput.pixelBufferPool!, &pixelBufferFromPool)
        guard let pixelBuffer = pixelBufferFromPool, pixelBufferStatus == kCVReturnSuccess else {
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        renderIntoPixelBuffer(pixelBuffer, texture: texture)

        if !assetWriterPixelBufferInput.append(pixelBuffer, withPresentationTime: frameTime) {
            print("Problem appending pixel buffer at time: \(frameTime)")
        }

        CVPixelBufferUnlockBaseAddress(
            pixelBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
    }

    func renderIntoPixelBuffer(_ pixelBuffer:CVPixelBuffer, texture:Texture) {
        guard let pixelBufferBytes = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            print("Could not get buffer bytes")
            return
        }

        if (Int(round(self.size.width)) != outputTexture?.texture.width) && (Int(round(self.size.height)) != outputTexture?.texture.height) {
            outputTexture = Texture(device:sharedMetalRenderingDevice.device,
                                    orientation: texture.orientation,
                                    width: Int(round(self.size.width)),
                                    height: Int(round(self.size.height)),
                                    timingStyle: texture.timingStyle)
        }
        
        let commandBuffer = sharedMetalRenderingDevice.commandQueue.makeCommandBuffer()
        commandBuffer?.renderQuad(pipelineState: renderPipelineState, inputTextures: [0:texture], outputTexture: outputTexture!, outputOrientation: texture.orientation)
        commandBuffer?.commit()
        commandBuffer?.waitUntilCompleted()
        
        let region = MTLRegionMake2D(0, 0, outputTexture!.texture.width, outputTexture!.texture.height)
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        outputTexture!.texture.getBytes(pixelBufferBytes, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
    }
    
    // MARK: -
    // MARK: Audio support

    public func activateAudioTrack() {
        // TODO: Add ability to set custom output settings
        assetWriterAudioInput = AVAssetWriterInput(
            mediaType: AVMediaType.audio, outputSettings: nil)
        assetWriter.add(assetWriterAudioInput!)
        assetWriterAudioInput?.expectsMediaDataInRealTime = encodingLiveVideo
    }

    public func processAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let startTime else { return } // wait until video starts the session
        guard let assetWriterAudioInput = assetWriterAudioInput else { return }

        guard assetWriterAudioInput.isReadyForMoreMediaData || (!self.encodingLiveVideo) else {
            return
        }

        if !assetWriterAudioInput.append(sampleBuffer) {
            print("Trouble appending audio sample buffer")
        }
    }
}

// MARK: Adding GPS location to video's metadata

public extension MovieOutput {
    private func iso6709String(_ loc: CLLocation) -> String {
        let c = loc.coordinate
        let lat = String(format: "%+.6f", c.latitude)
        let lon = String(format: "%+.6f", c.longitude)

        if loc.verticalAccuracy >= 0 {
            let alt = String(format: "%+.2f", loc.altitude)
            return "\(lat)\(lon)\(alt)/"
        } else {
            return "\(lat)\(lon)/"
        }
    }

    public func setLocationMetadata(_ location: CLLocation) {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataLocationISO6709
        item.value = iso6709String(location) as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String

        assetWriter.metadata = (assetWriter.metadata) + [item]
    }
}
