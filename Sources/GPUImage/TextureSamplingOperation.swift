import Foundation

open class TextureSamplingOperation: BasicOperation {
    // public var overriddenTexelSize:Size?

    override public init(
        vertexFunctionName: String? = "nearbyTexelSampling",
        fragmentFunctionName: String,
        numberOfInputs: UInt = 1,
        operationName: String = #file,
        maximumTextureSize:CGSize = .zero,
        textureResizePolicy:TextureResizePolicy = .fill
    ) {
        super.init(
            vertexFunctionName: vertexFunctionName, fragmentFunctionName: fragmentFunctionName,
            numberOfInputs: numberOfInputs, operationName: operationName)
        self.useNormalizedTextureCoordinates = false
    }
}
