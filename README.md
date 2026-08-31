# TeslaDash — 特斯拉车载蓝牙手机仪表盘

通过 **车机蓝牙（Tesla BLE）** 直连车辆，读取车速、电量、续航、空调、车门等状态，
并支持锁车、闪灯、鸣笛、控制充电口 / 空调 / 哨兵 / 充电上限等快捷操作。
无需联网、无需特斯拉账号，钥匙保存在本机 Keychain。

- 部署目标：**iOS 15.0+**（兼容 iOS 15 老设备）
- 语言：Swift 5 / SwiftUI，零第三方依赖（手写 Protobuf 编解码）
- 协议：VCSEC（车控域）+ CarServer（信息娱乐域），ECDH + AES-GCM 加密

## 目录结构

```
TeslaDash/
├── TeslaDash.xcodeproj/      # 由 gen_project.py 生成（已生成，可直接用）
├── TeslaDash/
│   ├── *.swift               # 源码
│   ├── Info.plist
│   └── Assets.xcassets/
├── gen_project.py            # 重新生成 Xcode 工程（部署目标锁 iOS 15）
├── build_ipa.sh              # 本地一键打包（需 macOS + Xcode 15+）
└── .github/workflows/build.yml   # GitHub Actions 自动打包 IPA
```

## 源码说明

| 文件 | 作用 |
|------|------|
| `Protobuf.swift` | 零依赖 Protobuf 编解码器 |
| `TeslaCrypto.swift` | ECDH→SHA1 派生会话密钥、AES-GCM、HMAC 会话校验 |
| `TeslaProtocol.swift` | 双域消息构建与入帧解析 |
| `VehicleState.swift` | 车辆状态模型 + 解析器 + 单位设置 |
| `KeyStore.swift` | Keychain 钥匙存储 |
| `TeslaBLEManager.swift` | CoreBluetooth 扫描 / 握手 / 轮询 / 控制 |
| `SpeedGauge.swift` / `*View.swift` | SwiftUI 界面 |

## 首次使用（配对）

> 配对是特斯拉的安全强制流程，必须在车旁操作。

1. 在「设置」中填写 **VIN**（17 位车架号），保存。
2. 点击「开始配对」。
3. 按提示把 **实体钥匙卡** 放在中控台读卡器上。
4. 在车机屏幕上点「确认」。
5. 配对成功后 App 自动建立会话，开始显示实时数据。

钥匙（P-256 私钥）生成后存入 Keychain，**不会上传任何服务器**。
重装 App 或换设备需重新配对。

## 本地打包 IPA（macOS）

```bash
cd TeslaDash
python3 gen_project.py        # 确保工程最新
bash build_ipa.sh             # 编译并产出 TeslaDash.ipa
```

## 用 GitHub 自动打包 IPA

1. 把本仓库推送到 GitHub（main / master 分支）。
2. 仓库 **Actions → Build IPA** 会自动运行（macOS runner）。
3. 运行结束后在 **Artifacts** 中下载 `TeslaDash-unsigned-ipa`（即 `TeslaDash.ipa`）。

> 也可在仓库页面手动 **Run workflow** 触发。

## 安装 IPA

产出的 IPA 是**未签名**的，需要你自己签名后安装到 iOS 15+ 设备：

- **AltStore / SideStore**：导入 IPA，用 Apple ID 自签（7 天需刷新）。
- **Sideloadly**（Windows / macOS）：连接设备，用 Apple ID 签名安装。
- **3uTools / Apple Configurator**：企业 / 自签后安装。

安装时 Bundle ID 默认为 `com.example.tesladash`，如需自定可在
`gen_project.py` 顶部修改 `BUNDLE_ID` 后重新生成工程。

## 已知限制

- iOS 出于隐私不暴露蓝牙 MAC，App 依靠系统返回的 `identifier` 重连 + 广播名匹配。
- 车辆休眠时不会主动唤醒信息娱乐域（避免无谓耗电）。
- 车速原始单位官方未完全公开，默认按 mph 解析，可在「设置」切换；若数值异常请改单位。
- 未签名 IPA 受 Apple ID 自签有效期限制（通常 7 天）。
