# 第三方组件

- [BGE-small-zh-v1.5](https://huggingface.co/BAAI/bge-small-zh-v1.5) 搭配 [Xenova 的 INT8 ONNX 转换](https://huggingface.co/Xenova/bge-small-zh-v1.5)。原模型采用 MIT。
- [TinyCLIP ONNX](https://huggingface.co/onnx-community/TinyCLIP-ViT-8M-16-Text-3M-YFCC15M-ONNX) 采用 MIT。此项目将首个卷积的 INT8 权重及零点等值转换到 UINT8，以兼容随附的 CPU 推理库。
- [ONNX Runtime](https://github.com/microsoft/onnxruntime) 采用 MIT。随附 ARM64 共享库来自 [sherpa-onnx 的 HarmonyOS 构建](https://github.com/k2-fsa/sherpa-onnx/blob/master/build-ohos-arm64-v8a.sh)。其许可证和第三方声明随源码保留。
- MobileNetV2 权重由开发者从 [MindSpore Lite 官方示例](https://www.mindspore.cn/lite/docs/en/r2.3.0/quick_start/quick_start_c.html) 单独获取。

随附许可证见 [licenses](entry/src/main/resources/rawfile/licenses/)。
