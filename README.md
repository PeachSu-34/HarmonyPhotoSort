# 照片归类 · HarmonyPhotoSort

面向 HarmonyOS 的本地照片整理应用。通过系统选图器批量选图，在设备端识别文字和画面，然后按用户定义的类别整理。可逐张改组、将各分类归档到已有相册，或手动标记照片并在确认后移到系统图库的「最近删除」。

照片、OCR 文本和分类结果在设备端处理。相册读取、归档和删除受设备授权及签名 Profile 中的图库权限控制。

## 构建

1. 用 DevEco Studio 26.0.0 Release 打开本仓库。工程面向 ARM64，目标 SDK 为 26.0.0，最低兼容版本为 HarmonyOS 6.1.1（API 24）。Windows 下使用纯 ASCII 的工程和 SDK 路径。
2. 如需自然风景分类，从 [MindSpore Lite 官方示例](https://www.mindspore.cn/lite/docs/en/r2.3.0/quick_start/quick_start_c.html) 下载 `mobilenetv2.ms`，放到 `entry/src/main/resources/rawfile/photosort_model/`。预期 SHA-256 为 `5a7ccd53bf92d8b294a703a1302d4230a311b2d19a8d212eedd65ff6838cfa84`。
3. 同步工程后构建 HAP 或 APP。真机调试使用自己的调试签名。验证相册归档和删除时，需为自己的应用标识配置相应的图库读写权限，并在设备端授权。

## 许可证

项目原创代码采用 [MIT](LICENSE)。第三方模型和运行库沿用各自许可证。见 [第三方组件](THIRD_PARTY.md)。
