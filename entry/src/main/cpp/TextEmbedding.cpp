#include <napi/native_api.h>
#define ORT_API_MANUAL_INIT
#include <onnxruntime_cxx_api.h>

#include <array>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr size_t MAX_TOKENS = 192;
constexpr size_t FEATURE_COUNT = 512;
constexpr int32_t VOCABULARY_SIZE = 21128;
constexpr size_t IMAGE_VALUES = 3 * 224 * 224;
constexpr size_t SCENE_COUNT = 30;
constexpr size_t PROMPT_WIDTH = 10;

struct EmbeddingRequest {
    napi_async_work work = nullptr;
    napi_deferred result = nullptr;
    std::vector<uint8_t> model;
    std::vector<int64_t> ids;
    std::vector<float> pixels;
    std::array<float, FEATURE_COUNT> embedding{};
    size_t resultCount = FEATURE_COUNT;
    std::string error = "Offline inference cancelled";
};

void InitializeRuntime()
{
    Dl_info module{};
    if (dladdr(reinterpret_cast<const void*>(&InitializeRuntime), &module) == 0 || module.dli_fname == nullptr) {
        throw std::runtime_error("Cannot locate the packaged runtime directory");
    }
    const std::string wrapperPath(module.dli_fname);
    const std::string runtimePath = wrapperPath.substr(0, wrapperPath.find_last_of('/') + 1) + "libonnxruntime.so";
    void* library = dlopen(runtimePath.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (library == nullptr) {
        const char* reason = dlerror();
        throw std::runtime_error(reason == nullptr ? "Cannot load the packaged ONNX Runtime" : reason);
    }
    // Resolve the default symbol after loading our copy. The device linker
    // could not bind the third-party build's versioned relocation at import.
    const auto getApiBase = reinterpret_cast<decltype(&OrtGetApiBase)>(dlsym(library, "OrtGetApiBase"));
    const OrtApi* api = getApiBase == nullptr ? nullptr : getApiBase()->GetApi(ORT_API_VERSION);
    if (api == nullptr) {
        dlclose(library);
        throw std::runtime_error("Packaged ONNX Runtime API unavailable");
    }
    Ort::InitApi(api);
}

Ort::Session& GetSession(const std::vector<uint8_t>& model, bool vision = false)
{
    static std::once_flag apiInitialized;
    std::call_once(apiInitialized, InitializeRuntime);
    static Ort::Env runtime(ORT_LOGGING_LEVEL_ERROR, "PhotoSort");
    static std::mutex sessionMutex;
    static std::unique_ptr<Ort::Session> textSession;
    static std::unique_ptr<Ort::Session> imageSession;
    auto& session = vision ? imageSession : textSession;
    std::lock_guard<std::mutex> lock(sessionMutex);
    if (session == nullptr) {
        if (model.empty()) {
            throw std::invalid_argument("Missing model");
        }
        Ort::SessionOptions options;
        options.SetIntraOpNumThreads(2);
        options.SetInterOpNumThreads(1);
        session = std::make_unique<Ort::Session>(runtime, model.data(), model.size(), options);
    }
    return *session;
}

void CalculateScenes(napi_env, void* data)
{
    auto& request = *static_cast<EmbeddingRequest*>(data);
    try {
        auto& session = GetSession(request.model, true);
        // Fixed captions from the desktop TinyCLIP check. 1 is the model padding token.
        std::array<int64_t, SCENE_COUNT * PROMPT_WIDTH> tokens{
            49406, 320, 4925, 6469, 1844, 4009, 6052, 49407, 1, 1,
            49406, 550, 6469, 10560, 530, 4925, 10344, 1844, 49407, 1,
            49406, 320, 11444, 6469, 6052, 539, 320, 5727, 49407, 1,
            49406, 320, 1532, 8853, 539, 320, 2533, 49407, 1, 1,
            49406, 320, 8853, 539, 3288, 16025, 49407, 1, 1, 1,
            49406, 320, 12646, 539, 550, 2231, 593, 4160, 49407, 1,
            49406, 320, 11639, 652, 19450, 4245, 541, 4160, 15121, 49407,
            49406, 320, 11873, 5352, 3610, 49407, 1, 1, 1, 1,
            49406, 320, 1449, 537, 1579, 11873, 6052, 49407, 1, 1,
            49406, 320, 2660, 705, 6469, 1710, 6052, 49407, 1, 1,
            49406, 550, 4757, 7189, 9169, 593, 320, 11327, 49407, 1,
            49406, 320, 11873, 3724, 593, 320, 4902, 10799, 49407, 1,
            49406, 550, 6469, 7189, 2867, 593, 4160, 49407, 1, 1,
            49406, 320, 7189, 9169, 593, 320, 3789, 1710, 49407, 1,
            49406, 320, 7651, 4962, 3724, 593, 4160, 49407, 1, 1,
            49406, 320, 2016, 12646, 593, 39479, 49407, 1, 1, 1,
            49406, 320, 1125, 539, 35192, 6025, 5795, 49407, 1, 1,
            49406, 320, 5589, 620, 1907, 541, 1868, 15121, 49407, 1,
            49406, 320, 1228, 31971, 593, 9409, 537, 29056, 49407, 1,
            49406, 320, 12609, 6469, 1063, 4009, 6052, 49407, 1, 1,
            49406, 320, 3789, 7189, 11270, 49407, 1, 1, 1, 1,
            49406, 320, 2794, 3086, 539, 320, 2308, 49407, 1, 1,
            49406, 320, 38577, 1993, 274, 323, 4009, 13024, 49407, 1,
            49406, 320, 6684, 16157, 2794, 4009, 6052, 49407, 1, 1,
            49406, 320, 3789, 1125, 593, 4160, 44827, 49407, 1, 1,
            49406, 320, 3789, 7651, 7189, 49407, 1, 1, 1, 1,
            49406, 320, 9169, 1105, 633, 320, 2016, 6481, 49407, 1,
            49406, 550, 6469, 24318, 3574, 49407, 1, 1, 1, 1,
            49406, 320, 1125, 11258, 593, 3789, 41878, 49407, 1, 1,
            49406, 320, 3789, 7189, 1125, 49407, 1, 1, 1, 1
        };
        std::array<int64_t, SCENE_COUNT * PROMPT_WIDTH> mask{};
        for (size_t index = 0; index < tokens.size(); index++) {
            mask[index] = tokens[index] != 1;
        }
        const std::array<int64_t, 2> promptShape{SCENE_COUNT, PROMPT_WIDTH};
        const std::array<int64_t, 4> imageShape{1, 3, 224, 224};
        const auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        const std::array<const char*, 3> names{"input_ids", "attention_mask", "pixel_values"};
        std::array<Ort::Value, 3> inputs{
            Ort::Value::CreateTensor<int64_t>(memory, tokens.data(), tokens.size(), promptShape.data(), promptShape.size()),
            Ort::Value::CreateTensor<int64_t>(memory, mask.data(), mask.size(), promptShape.data(), promptShape.size()),
            Ort::Value::CreateTensor<float>(memory, request.pixels.data(), IMAGE_VALUES, imageShape.data(), imageShape.size())
        };
        const char* resultName = "logits_per_image";
        auto output = session.Run(Ort::RunOptions{nullptr}, names.data(), inputs.data(), inputs.size(), &resultName, 1);
        if (output[0].GetTensorTypeAndShapeInfo().GetElementCount() != SCENE_COUNT) {
            throw std::runtime_error("Unexpected scene score count");
        }
        std::memcpy(request.embedding.data(), output[0].GetTensorData<float>(), SCENE_COUNT * sizeof(float));
        request.resultCount = SCENE_COUNT;
        request.error.clear();
    } catch (const std::exception& failure) {
        request.error = failure.what();
    }
}

void CalculateEmbedding(napi_env, void* data)
{
    auto& request = *static_cast<EmbeddingRequest*>(data);
    try {
        request.error = "Could not start offline text model";
        auto& session = GetSession(request.model);
        request.error = "Offline text inference failed";
        const size_t count = request.ids.size();
        std::array<int64_t, 2> shape{1, static_cast<int64_t>(count)};
        std::vector<int64_t> attention(count, 1);
        std::vector<int64_t> segment(count, 0);
        const auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        const std::array<const char*, 3> names{"input_ids", "attention_mask", "token_type_ids"};
        std::array<Ort::Value, 3> inputs{
            Ort::Value::CreateTensor<int64_t>(memory, request.ids.data(), count, shape.data(), shape.size()),
            Ort::Value::CreateTensor<int64_t>(memory, attention.data(), count, shape.data(), shape.size()),
            Ort::Value::CreateTensor<int64_t>(memory, segment.data(), count, shape.data(), shape.size())
        };
        const char* outputName = "last_hidden_state";
        auto output = session.Run(Ort::RunOptions{nullptr}, names.data(), inputs.data(), inputs.size(), &outputName, 1);
        const auto dimensions = output[0].GetTensorTypeAndShapeInfo().GetShape();
        if (dimensions.size() != 3 || dimensions[0] != 1 ||
            dimensions[1] != static_cast<int64_t>(count) || dimensions[2] != FEATURE_COUNT) {
            request.error = "Unexpected text embedding shape";
            for (const auto dimension : dimensions) {
                request.error += " " + std::to_string(dimension);
            }
            return;
        }
        std::memcpy(request.embedding.data(), output[0].GetTensorData<float>(), sizeof(request.embedding));
        request.error.clear();
    } catch (const std::exception& failure) {
        // Only the synthetic debug check displays inference diagnostics.
        request.error = failure.what();
    }
}

void CompleteEmbedding(napi_env env, napi_status status, void* data)
{
    auto request = std::unique_ptr<EmbeddingRequest>(static_cast<EmbeddingRequest*>(data));
    napi_value buffer;
    napi_value result;
    void* bytes = nullptr;
    const size_t resultBytes = request->resultCount * sizeof(float);
    if (status == napi_ok && request->error.empty() &&
        napi_create_arraybuffer(env, resultBytes, &bytes, &buffer) == napi_ok &&
        napi_create_typedarray(env, napi_float32_array, request->resultCount, buffer, 0, &result) == napi_ok) {
        std::memcpy(bytes, request->embedding.data(), resultBytes);
        napi_resolve_deferred(env, request->result, result);
    } else {
        napi_value message;
        const char* detail = request->error.empty() ? "Could not return offline inference result" : request->error.c_str();
        napi_create_string_utf8(env, detail, NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &result);
        napi_reject_deferred(env, request->result, result);
    }
    napi_delete_async_work(env, request->work);
}

napi_value SubmitInference(napi_env env, napi_callback_info info, bool vision)
{
    try {
        size_t argc = 2;
        napi_value argv[2];
        void* model = nullptr;
        size_t modelSize = 0;
        if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc != 2 ||
            napi_get_arraybuffer_info(env, argv[0], &model, &modelSize) != napi_ok) {
            napi_throw_type_error(env, nullptr, "Expected an offline model and input data");
            return nullptr;
        }
        auto request = std::make_unique<EmbeddingRequest>();
        if (modelSize != 0) {
            const auto* bytes = static_cast<const uint8_t*>(model);
            request->model.assign(bytes, bytes + modelSize);
        }
        if (vision) {
            void* pixels = nullptr;
            size_t pixelBytes = 0;
            if (napi_get_arraybuffer_info(env, argv[1], &pixels, &pixelBytes) != napi_ok ||
                pixelBytes != IMAGE_VALUES * sizeof(float)) {
                napi_throw_type_error(env, nullptr, "Expected a 224 × 224 RGB image buffer");
                return nullptr;
            }
            request->pixels.resize(IMAGE_VALUES);
            std::memcpy(request->pixels.data(), pixels, pixelBytes);
        } else {
            uint32_t tokenCount = 0;
            if (napi_get_array_length(env, argv[1], &tokenCount) != napi_ok || tokenCount < 2 || tokenCount > MAX_TOKENS) {
                napi_throw_type_error(env, nullptr, "Expected 2 to 192 token IDs");
                return nullptr;
            }
            request->ids.reserve(tokenCount);
            for (uint32_t index = 0; index < tokenCount; index++) {
                napi_value value;
                int32_t token = -1;
                if (napi_get_element(env, argv[1], index, &value) != napi_ok ||
                    napi_get_value_int32(env, value, &token) != napi_ok || token < 0 || token >= VOCABULARY_SIZE) {
                    napi_throw_range_error(env, nullptr, "Text token ID is outside the packaged vocabulary");
                    return nullptr;
                }
                request->ids.push_back(token);
            }
        }

        napi_value promise;
        napi_value name;
        if (napi_create_promise(env, &request->result, &promise) != napi_ok ||
            napi_create_string_utf8(env, "PhotoSortTextEmbedding", NAPI_AUTO_LENGTH, &name) != napi_ok ||
            napi_create_async_work(env, nullptr, name, vision ? CalculateScenes : CalculateEmbedding, CompleteEmbedding,
                request.get(), &request->work) != napi_ok) {
            napi_throw_error(env, nullptr, "Could not create offline inference work");
            return nullptr;
        }
        if (napi_queue_async_work(env, request->work) != napi_ok) {
            napi_delete_async_work(env, request->work);
            napi_throw_error(env, nullptr, "Could not queue offline inference work");
            return nullptr;
        }
        request.release();
        return promise;
    } catch (const std::exception&) {
        napi_throw_error(env, nullptr, "Could not prepare offline inference");
        return nullptr;
    }
}

napi_value Embed(napi_env env, napi_callback_info info)
{
    return SubmitInference(env, info, false);
}

napi_value RankScenes(napi_env env, napi_callback_info info)
{
    return SubmitInference(env, info, true);
}

napi_value Initialize(napi_env env, napi_value exports)
{
    const napi_property_descriptor methods[] = {
        {"embed", nullptr, Embed, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rankScenes", nullptr, RankScenes, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods);
    return exports;
}

napi_module module = {
    1, 0, nullptr, Initialize, "photosort_ort", nullptr, {nullptr, nullptr, nullptr, nullptr}
};
}  // namespace

extern "C" __attribute__((constructor)) void RegisterPhotoSortOrt()
{
    napi_module_register(&module);
}
