# Equil 探测版（iOS）

微泰 Equil 贴泵的 iOS 侧工程。当前为 **0.1 探测版**：只做 BLE 扫描、连接、GATT 枚举和帧抓取，**还不能控泵**。

## 为什么不能直接搬 Android 版

- 原 SDK `com.microtechmd.library` 是 Android Java，依赖 `android.*`
- 协议栈在 `libjni_interface.so` 里，是 Android ELF（aarch64/armv7），iOS 无法加载
- 所以 iOS 必须用 Swift 重写：BLE(UUID F000/FFE1) → 帧封装 → 链路状态机 → 业务命令

## 已逆向到的协议结构（继续做 0.2 的依据）

`LibFrame_Pack` 反汇编结果是典型的转义帧：

```
[SOF][payload 每字节: 若等于 SOF 或 ESC 则先输出 ESC][ESC][ESC]
```

原生层其它符号：`DevComm_Send/Query/Receive/Link/Tick/Unlink`、`LibChecksum_GetChecksumPartial16Bit`、`LibChecksum_GetChecksumPartial8Bit`、`DrvUART_*`。说明是「校验 + 序列号 + 重传」的链路层，业务消息体就是 `EntityMessage`（源/目标地址、端口、操作码、参数、数据）。

## 构建

公开仓库用 GitHub macOS runner 构建（私有仓库在免费账号没有 macOS 配额）：

```
xcodegen generate
xcodebuild -project EquilProbe.xcodeproj -target EquilProbe -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

产物 `EquilProbe-unsigned.ipa` 未签名，需要 AltStore / SideStore / 自己的开发者证书签名后才能装。

## 路线

- 0.1（当前）：扫描 + 连接 + 特征/帧抓取，用来在你的泵上验证 UUID、通知特征和真实帧格式
- 0.2：Swift 实现解帧/组帧 + 查询设备、绑定、模式、大剂量、临时基础率
- 0.3：前台保持、告警、贴片倒计时（与 Android 版对齐）
