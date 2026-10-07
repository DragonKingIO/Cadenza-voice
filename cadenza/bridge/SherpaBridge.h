// sherpa-onnx C API。仅在 build.sh 找到 third_party/sherpa-onnx 时通过 -import-objc-header 引入。
#include "sherpa-onnx/c-api/c-api.h"
// onnxruntime C API, for the on-device text recognition models (tools/fetch-sherpa-onnx.sh fetches the headers).
#if __has_include("onnxruntime/core/session/onnxruntime_c_api.h")
#include "onnxruntime/core/session/onnxruntime_c_api.h"
#endif
