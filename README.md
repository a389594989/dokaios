# DokaiOS（M0–M2 骨架）

纯原生 iOS 相机：SwiftUI + AVFoundation + Metal + Vision + CoreImage，全程离线、无网络请求。

## 已包含
| 里程碑 | 内容 | 文件 |
| :--- | :--- | :--- |
| M0 | 资产提取、LUT 转 3D、XcodeGen 工程、CI 构建 | `scripts/extract_assets.py`, `project.yml`, `.github/workflows/build.yml` |
| M1 | 虚拟多摄预览、变焦条（按机型自动推导 0.5/1x/2/3/5）、拍照、保存相册并写 EXIF 配方 | `Camera/`, `Processing/` |
| M2 | Metal 实时 LUT + 颗粒 + 暗角；Vision 构图（人脸眼线/显著性/地平线）；三槽位胶片推荐；长按选主体 | `Rendering/`, `Analysis/`, `UI/` |

## 构建与安装
1. 在 Linux 上把本目录作为仓库根推到 GitHub（公开仓库 macOS 构建免费）。
2. Actions 页 **Build iOS (unsigned IPA)** 跑完后下载 `DokaiOS-ipa` 里的 `DokaiOS.ipa`。
3. 重启到 Windows，用 Sideloadly（或 AltStore）+ 免费 Apple ID 签名安装，数据线连接 iPhone。
4. 手机：设置 → 通用 → VPN 与设备管理 → 信任开发者；首次运行允许相机、相册权限。
5. 免费账号证书 7 天过期，需重新签名。

> `com.example.dokaios` 是占位 Bundle ID，Sideloadly 会自动改写。

## 重要说明
- **这套代码没有在 Xcode 里编译过**（当前机器无 macOS）。第一次 CI 很可能有少量编译错误，把 Actions 日志贴给我即可逐个修。
- 构图阈值与胶片推荐规则是初版经验值，**尚未逐项对齐**安卓 `I1/a.java`，属 TODO。
- LUT 布局（512×512，8×8 个 64×64 图块，图块序号=B、块内 x=R、y=G）由像素抽样推断，需真机目测确认色彩无通道错位；若偏色，调整 `LUTStore.build` 的索引。
- `ExtractedUI/` 里是提取出的位图与字体（M4 再挑选转入 `Assets.xcassets`），不参与构建。原版切图版权属原作者，仅限个人使用。
- 后续 M3 调参 / M4（水印、画幅、水平仪、设置页、复古拟物 UI）尚未开始。
