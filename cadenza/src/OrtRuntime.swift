import Foundation

/// A small synchronous wrapper around the onnxruntime C API for float32 models with a single input, used by the on-device
/// text recognition models. It exists only when build.sh found the onnxruntime headers (`LOCAL_ORT`); without them
/// `OrtModel.isAvailable` is false and nothing here is compiled in.
enum OrtModelError: Error, Equatable { case unavailable, load(String), run(String) }

#if LOCAL_ORT

final class OrtModel {
    struct Output { var shape: [Int]; var data: [Float] }

    static var isAvailable: Bool { api != nil && env != nil }

    private static let api: UnsafePointer<OrtApi>? = OrtGetApiBase()?.pointee.GetApi?(UInt32(ORT_API_VERSION))
    private static let env: OpaquePointer? = {
        guard let api, let create = api.pointee.CreateEnv else { return nil }
        var env: OpaquePointer?
        return create(ORT_LOGGING_LEVEL_ERROR, "cadenza", &env) == nil ? env : nil
    }()

    private var session: OpaquePointer?
    private var options: OpaquePointer?
    private var inputName = "", outputName = ""

    /// Loads a model file. Throws with the onnxruntime message when it cannot be loaded.
    init(path: String, threads: Int = 2) throws {
        guard let api = Self.api, let env = Self.env else { throw OrtModelError.unavailable }
        func message(_ status: OpaquePointer?) -> String? {
            guard let status else { return nil }
            defer { api.pointee.ReleaseStatus?(status) }
            return api.pointee.GetErrorMessage?(status).map { String(cString: $0) } ?? "unknown error"
        }
        var opts: OpaquePointer?
        if let e = message(api.pointee.CreateSessionOptions?(&opts)) { throw OrtModelError.load(e) }
        options = opts
        _ = api.pointee.SetIntraOpNumThreads?(opts, Int32(max(1, threads)))
        _ = api.pointee.SetSessionGraphOptimizationLevel?(opts, ORT_ENABLE_ALL)
        var s: OpaquePointer?
        if let e = message(api.pointee.CreateSession?(env, path, opts, &s)) {
            api.pointee.ReleaseSessionOptions?(opts); options = nil
            throw OrtModelError.load(e)
        }
        session = s
        var allocator: UnsafeMutablePointer<OrtAllocator>?
        if message(api.pointee.GetAllocatorWithDefaultOptions?(&allocator)) == nil, let allocator {
            var name: UnsafeMutablePointer<CChar>?
            if message(api.pointee.SessionGetInputName?(s, 0, allocator, &name)) == nil, let name { inputName = String(cString: name); _ = api.pointee.AllocatorFree?(allocator, name) }
            name = nil
            if message(api.pointee.SessionGetOutputName?(s, 0, allocator, &name)) == nil, let name { outputName = String(cString: name); _ = api.pointee.AllocatorFree?(allocator, name) }
        }
        guard !inputName.isEmpty, !outputName.isEmpty else { release(); throw OrtModelError.load("model has no named input or output") }
    }

    deinit { release() }

    private func release() {
        guard let api = Self.api else { return }
        if let session { api.pointee.ReleaseSession?(session); self.session = nil }
        if let options { api.pointee.ReleaseSessionOptions?(options); self.options = nil }
    }

    /// Runs the model on one float32 tensor and returns its first output.
    func run(_ input: [Float], shape: [Int]) throws -> Output {
        guard let api = Self.api, let session else { throw OrtModelError.unavailable }
        func message(_ status: OpaquePointer?) -> String? {
            guard let status else { return nil }
            defer { api.pointee.ReleaseStatus?(status) }
            return api.pointee.GetErrorMessage?(status).map { String(cString: $0) } ?? "unknown error"
        }
        let count = shape.reduce(1, *)
        guard count == input.count, count > 0 else { throw OrtModelError.run("input has \(input.count) values, shape needs \(count)") }
        var memory: OpaquePointer?
        if let e = message(api.pointee.CreateCpuMemoryInfo?(OrtArenaAllocator, OrtMemTypeDefault, &memory)) { throw OrtModelError.run(e) }
        defer { api.pointee.ReleaseMemoryInfo?(memory) }
        var buffer = input
        let dims = shape.map { Int64($0) }
        var inputValue: OpaquePointer?
        let created: String? = buffer.withUnsafeMutableBytes { raw in
            message(api.pointee.CreateTensorWithDataAsOrtValue?(memory, raw.baseAddress, raw.count, dims, dims.count, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &inputValue))
        }
        if let created { throw OrtModelError.run(created) }
        defer { api.pointee.ReleaseValue?(inputValue) }
        var outputValue: OpaquePointer?
        let ran: String? = inputName.withCString { inName in outputName.withCString { outName in
            var names: [UnsafePointer<CChar>?] = [inName], outNames: [UnsafePointer<CChar>?] = [outName]
            var inputs: [OpaquePointer?] = [inputValue]
            return message(api.pointee.Run?(session, nil, &names, &inputs, 1, &outNames, 1, &outputValue))
        } }
        if let ran { throw OrtModelError.run(ran) }
        defer { api.pointee.ReleaseValue?(outputValue) }
        var info: OpaquePointer?
        if let e = message(api.pointee.GetTensorTypeAndShape?(outputValue, &info)) { throw OrtModelError.run(e) }
        defer { api.pointee.ReleaseTensorTypeAndShapeInfo?(info) }
        var rank = 0
        _ = api.pointee.GetDimensionsCount?(info, &rank)
        var outDims = [Int64](repeating: 0, count: rank)
        _ = api.pointee.GetDimensions?(info, &outDims, rank)
        var total = 0
        _ = api.pointee.GetTensorShapeElementCount?(info, &total)
        var raw: UnsafeMutableRawPointer?
        if let e = message(api.pointee.GetTensorMutableData?(outputValue, &raw)) { throw OrtModelError.run(e) }
        guard let raw, total > 0 else { throw OrtModelError.run("empty output") }
        let floats = Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: total))
        return Output(shape: outDims.map { Int($0) }, data: floats)
    }
}

#else

final class OrtModel {
    struct Output { var shape: [Int]; var data: [Float] }
    static var isAvailable: Bool { false }
    init(path: String, threads: Int = 2) throws { throw OrtModelError.unavailable }
    func run(_ input: [Float], shape: [Int]) throws -> Output { throw OrtModelError.unavailable }
}

#endif
