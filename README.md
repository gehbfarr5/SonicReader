# 英文随听 · SonicReader

用于英文学习的 iOS 朗读工具，通过 Cartesia Sonic 3.6 / Daniel 生成音频，支持从分享菜单或快捷指令播放例句。

当前版本：**0.1.10**。首次公开版本管理基线为 0.1.9。

## 功能

- 从 App 的分享菜单接收英文，显示播放器；关闭后停止播放。
- 快捷指令接收复制的文本，直接朗读。播放弹层只保留原文、关闭与重复播放；重复使用已有音频，不再请求 API。
- App / 分享播放器支持重播、连续循环及 0.8 / 0.9 / 1.0 / 1.1 / 1.2 倍速。
- 原文和音频保存在本地，最多 500 条。右滑收藏或取消收藏，收藏置顶；左滑直接删除。新增时清理最久未播放的未收藏记录；500 条全收藏时阻止新增。
- 统一历史行高与滑动按钮高度；音量增强保留原始录音，避免反复叠加增益。
- API 密钥由使用者在 App 设置中输入，存入共享 Keychain，不内置在源码或 IPA 中。

## 环境

- macOS、Xcode 27、XcodeGen。
- App 与分享扩展部署目标为 iOS 18；快捷指令系统弹层使用 iOS 26+ App Intents 接口。
- Cartesia API 版本为 `2026-08-14`，模型 `sonic-3.6`。

## 构建与签名

```sh
brew install xcodegen
xcodegen generate
open SonicReader.xcodeproj
```

在 Xcode 配置自己的签名团队、Bundle ID 和可用 App Group。主 App 与分享扩展必须使用相同共享组，并与运行时 `SonicAppGroup` 配置一致。Keychain access group 使用相同 App Group。

不含签名的通用 IPA：

```sh
zsh Scripts/build-unsigned.sh
```

按自己描述文件授权的共享组构建：

```sh
python3 Scripts/build-profile-matched.py /path/to/your.mobileprovision \
  --group group.your.authorized.group --version 0.1.10 --build 11
```

构建结果位于 `Artifacts/`，仍需合法签名后安装。检查签名包：

```sh
python3 Scripts/check-signed-ipa.py /path/to/signed.ipa
```

本仓库不发布私人证书、描述文件或针对个人共享权限打包的 IPA。

## 可选额外交付目录

默认只保留本机 `Artifacts/` 的构建文件。如需自动复制到自己的目录，在项目根目录创建被 Git 忽略的 `release-local.json`：

```json
{
  "deliveryDirectory": "/absolute/path/to/your/release-folder",
  "profileIPASuffix": "profile-matched"
}
```

已配置的交付目录不可用时构建会明确失败；不会悄悄换目录。复制会校验 SHA-256，本机文件存在不代表云同步已完成。

## 快捷指令入口

首次设置：隐藏控制中心 → 获取剪贴板 → 英文随听的“直接朗读文本”，把文本参数连接到剪贴板输出。先安装并打开 App 一次，再在快捷指令动作搜索中选择该 App 动作。入口不读取选区，不从分享菜单接收输入；分享由 App 扩展处理。

现有快捷指令名称和图标可自行修改。App 更新保持 `ReadCopiedTextIntent` 与 `text` 参数，通常无需重新导入现有工作流。系统片段的具体显示和连续重播需要设备验证。

## 测试与版本

```sh
xcodegen generate
xcodebuild -project SonicReader.xcodeproj -scheme SonicReader \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonicReaderTests test
```

核心测试使用本地测试音频，不依赖真实 API 密钥。历史 UI 测试需要在测试共享容器准备对应的公开 fixture，不纳入默认核心测试命令。

0.1.9 修正了音频会话在播放器准备之后才配置的问题；冷会话回归测试能区分修复前后的顺序，用户已确认本版手机播放通过。模拟器逻辑测试不等于所有系统弹层行为已通过。[版本记录](Docs/Release-Notes.md)

## 目录

- `App/`：主界面、历史与快捷指令 App Intents。
- `ShareExtension/`：分享扩展。
- `Shared/`：API、音频、共享密钥、历史与播放器。
- `Tests/`：单元测试与设备 UI 测试。
- `Scripts/`：构建、包检查与可选交付。
- `project.yml`：XcodeGen 项目定义。
