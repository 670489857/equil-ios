# Equil 独立版（iOS）

微泰 Equil 贴泵的独立 iOS 客户端，不依赖 AAPS。Swift 重写，本仓库**不含任何厂商二进制代码**，可公开。

## 版本
- 0.2.0：连接 + 控制台（查询/暂停/恢复/停止/大剂量/临时百分比/退药/排气/绑定）+ 帧调试台 + 换片向导 + 贴片倒计时。

## 协议层
- 帧：`SOF SOF + 转义(body) + SOF SOF`，默认 SOF=0x7E、ESC=0x7D（可在调试页改）。
- body：`seq + addr + srcPort + dstPort + mode + param(2B) + len + data + crc(2B)`，CRC-16 反射（多项式 0xA001，初值 0xFFFF），`len = data.count + 12`。
- 业务层严格复刻 `com.microtechmd.library.presenter.*`：端口 4↔4 的 param 0=模式、2=基础率、3=大剂量、4=临时率、5=设置、6=退药、7=排气；mode 1=set、2=get；数值为 int32 小端。

> 帧层的 SOF/ESC、CRC 落位、序号语义来自对 `libjni_interface.so` 的静态逆向。若首次下发无回帧，用「调试」页把 AAPS 日志中的 `Write frame, data: ...` 原样发送比对即可定位差异，无需重新编译。

## 构建
GitHub Actions（macos-latest）自动产出未签名 IPA；也可本地 `xcodegen generate && xcodebuild ...`。
未签名 IPA 需自签（Sideloadly/AltStore/开发者证书）后才能装到 iPhone。
