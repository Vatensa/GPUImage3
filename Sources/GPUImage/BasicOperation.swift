import Foundation
import Metal

public func defaultVertexFunctionNameForInputs(_ inputCount: UInt) -> String {
    switch inputCount {
    case 1:
        return "oneInputVertex"
    case 2:
        return "twoInputVertex"
    default:
        return "oneInputVertex"
    }
}

open class BasicOperation: ImageProcessingOperation {
    public enum TextureResizePolicy {
        case aspectFill
        case aspectFit
        case fill

        public func resize(sourceSize: CGSize, destinationSize: CGSize) -> CGSize {
            guard sourceSize.width > 0,
                  sourceSize.height > 0,
                  destinationSize.width > 0,
                  destinationSize.height > 0 else {
                return .zero
            }

            let sx = destinationSize.width / sourceSize.width
            let sy = destinationSize.height / sourceSize.height

            switch self {
            case .fill:
                return destinationSize

            case .aspectFit:
                let scale = min(sx, sy)
                return CGSize(
                    width: sourceSize.width * scale,
                    height: sourceSize.height * scale
                )

            case .aspectFill:
                let scale = max(sx, sy)
                return CGSize(
                    width: sourceSize.width * scale,
                    height: sourceSize.height * scale
                )
            }
        }
    }
    
    public let maximumInputs: UInt
    public let targets = TargetContainer()
    public let sources = SourceContainer()

    public var activatePassthroughOnNextFrame: Bool = false
    public var uniformSettings: ShaderUniformSettings
    public var useMetalPerformanceShaders: Bool = false {
        didSet {
            if !sharedMetalRenderingDevice.metalPerformanceShadersAreSupported {
                print("Warning: Metal Performance Shaders are not supported on this device")
                useMetalPerformanceShaders = false
            }
        }
    }

    let renderPipelineState: MTLRenderPipelineState
    let operationName: String
    var inputTextures = [UInt: Texture]()
    let textureInputSemaphore = DispatchSemaphore(value: 1)
    var useNormalizedTextureCoordinates = true
    var metalPerformanceShaderPathway: ((MTLCommandBuffer, [UInt: Texture], Texture) -> Void)?
    
    public private(set) var maximumTextureSize:CGSize
    public private(set) var textureResizePolicy:TextureResizePolicy

    public init(
        vertexFunctionName: String? = nil, fragmentFunctionName: String, numberOfInputs: UInt = 1,
        operationName: String = #file, maximumTextureSize:CGSize = .zero, textureResizePolicy:TextureResizePolicy = .fill
    ) {
        self.maximumInputs = numberOfInputs
        self.operationName = operationName

        let concreteVertexFunctionName =
            vertexFunctionName ?? defaultVertexFunctionNameForInputs(numberOfInputs)
        
        let (pipelineState, lookupTable, bufferSize) = generateRenderPipelineState(
            device: sharedMetalRenderingDevice, vertexFunctionName: concreteVertexFunctionName,
            fragmentFunctionName: fragmentFunctionName, operationName: operationName)
        
        self.renderPipelineState = pipelineState
        self.uniformSettings = ShaderUniformSettings(uniformLookupTable: lookupTable, bufferSize: bufferSize)
        self.maximumTextureSize = maximumTextureSize
        self.textureResizePolicy = textureResizePolicy
    }

    public func transmitPreviousImage(to target: ImageConsumer, atIndex: UInt) {
        // TODO: Finish implementation later
    }

    public func newTextureAvailable(_ texture: Texture, fromSourceIndex: UInt) {
        let _ = textureInputSemaphore.wait(timeout: DispatchTime.distantFuture)
        defer { textureInputSemaphore.signal() }

        inputTextures[fromSourceIndex] = texture

        //print("[\(String(describing: type(of: self)))] input: \(texture.orientation)")
        
        if (UInt(inputTextures.count) >= maximumInputs) || activatePassthroughOnNextFrame {
            let firstInputTexture = inputTextures[0]!

//            let outputWidth: Int
//            let outputHeight: Int
 
//            if firstInputTexture.orientation.rotationNeeded(for: .portrait).flipsDimensions() {
//                outputWidth = firstInputTexture.texture.height
//                outputHeight = firstInputTexture.texture.width
//            } else {
//                outputWidth = firstInputTexture.texture.width
//                outputHeight = firstInputTexture.texture.height
//            }

//            if uniformSettings.usesAspectRatio {
//                let outputRotation = firstInputTexture.orientation.rotationNeeded(for: .portrait)
//                uniformSettings["aspectRatio"] = firstInputTexture.aspectRatio(for: outputRotation)
//            }

            var outputWidth = firstInputTexture.texture.width
            var outputHeight = firstInputTexture.texture.height
            //let outputOrientation:ImageOrientation = outputWidth > outputHeight ? .landscapeRight : .portrait
            let outputOrientation:ImageOrientation = firstInputTexture.orientation
            
            if maximumTextureSize.width.isFinite && maximumTextureSize.width > 0
            && maximumTextureSize.height.isFinite && maximumTextureSize.height > 0 {
                let newOutputSize = textureResizePolicy.resize(sourceSize: CGSize(width: outputWidth, height: outputHeight),
                                                               destinationSize: maximumTextureSize)
                
                outputWidth = Int(ceil(newOutputSize.width))
                outputHeight = Int(ceil(newOutputSize.height))
            }

            if uniformSettings.usesAspectRatio {
                let outputRotation = firstInputTexture.orientation.rotationNeeded(for: outputOrientation)
                uniformSettings["aspectRatio"] = firstInputTexture.aspectRatio(for: outputRotation)
            }

            guard let commandBuffer = sharedMetalRenderingDevice.commandQueue.makeCommandBuffer()
            else { return }

            let outputTexture = Texture(
                device: sharedMetalRenderingDevice.device, orientation: outputOrientation,
                width: outputWidth, height: outputHeight, timingStyle: firstInputTexture.timingStyle
            )

            guard !activatePassthroughOnNextFrame else {
                // Use this to allow a bootstrap of cyclical processing, like with a low pass filter.
                activatePassthroughOnNextFrame = false
                // TODO: Render rotated passthrough image here

                removeTransientInputs()
                textureInputSemaphore.signal()
                updateTargetsWithTexture(outputTexture)
                let _ = textureInputSemaphore.wait(timeout: DispatchTime.distantFuture)

                return
            }

            if let alternateRenderingFunction = metalPerformanceShaderPathway,
                useMetalPerformanceShaders
            {
                var rotatedInputTextures: [UInt: Texture]
                if firstInputTexture.orientation.rotationNeeded(for: .portrait) != .noRotation {
                    let rotationOutputTexture = Texture(
                        device: sharedMetalRenderingDevice.device, orientation: .portrait,
                        width: outputWidth, height: outputHeight)
                    guard
                        let rotationCommandBuffer = sharedMetalRenderingDevice.commandQueue
                            .makeCommandBuffer()
                    else { return }
                    rotationCommandBuffer.renderQuad(
                        pipelineState: sharedMetalRenderingDevice.passthroughRenderState,
                        uniformSettings: uniformSettings, inputTextures: inputTextures,
                        useNormalizedTextureCoordinates: useNormalizedTextureCoordinates,
                        outputTexture: rotationOutputTexture)
                    rotationCommandBuffer.commit()
                    rotatedInputTextures = inputTextures
                    rotatedInputTextures[0] = rotationOutputTexture
                } else {
                    rotatedInputTextures = inputTextures
                }
                alternateRenderingFunction(commandBuffer, rotatedInputTextures, outputTexture)
            } else {
                internalRenderFunction(commandBuffer: commandBuffer, outputTexture: outputTexture)
            }
            commandBuffer.commit()

            removeTransientInputs()
            textureInputSemaphore.signal()
            
            //print("[\(String(describing: type(of: self)))] output: \(outputTexture.orientation)")
            
            updateTargetsWithTexture(outputTexture)
            let _ = textureInputSemaphore.wait(timeout: DispatchTime.distantFuture)
        }
    }

    func removeTransientInputs() {
        for index in 0..<self.maximumInputs {
            if let texture = inputTextures[index], texture.timingStyle.isTransient() {
                inputTextures[index] = nil
            }
        }
    }

    func internalRenderFunction(commandBuffer: MTLCommandBuffer, outputTexture: Texture) {
        commandBuffer.renderQuad(
            pipelineState: renderPipelineState, uniformSettings: uniformSettings,
            inputTextures: inputTextures,
            useNormalizedTextureCoordinates: useNormalizedTextureCoordinates,
            outputTexture: outputTexture, outputOrientation: outputTexture.orientation)
    }
}
