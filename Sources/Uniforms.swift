import simd

// Must match the Metal `Uniforms` struct layout exactly (96 bytes).
struct Uniforms {
    var scnA: SIMD4<Float>          // current scene: seed, subtype, flags, duration
    var scnB: SIMD4<Float>          // previous scene
    var palA: SIMD4<Float>          // current palette: baseHue, accentHue, nebulaAmt, starTint
    var palB: SIMD4<Float>
    var resolution: SIMD2<Float>
    var time: Float
    var sceneTime: Float
    var prevSceneTime: Float
    var transition: Float
    var sceneType: Int32
    var prevSceneType: Int32
}
