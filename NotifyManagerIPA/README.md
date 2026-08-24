# 通知管理 - 独立控制面板 (IPA)

## 简介

这是**通知管理**越狱插件的独立控制面板 IPA。与 Tweak 通过 `NSUserDefaults suiteName: com.ntm.notifymanager` 共享配置，实现：

- 分类查看 App（用户应用 / 巨魔应用 / 系统应用）
- 每应用：总开关 + 5 维子开关（锁定屏幕/通知中心/横幅/声音/标记）
- 每应用：4 种网络策略（打开 wifi/流量/wifi+流量/断网）
- 搜索、批量开启/关闭/恢复、导入/导出配置

## 与 Tweak 的关系

```
┌──────────────────────────────┐     NSUserDefaults      ┌──────────────────────┐
│  NotifyManagerIPA.app        │  ──────────────────▶    │  Tweak.dylib         │
│  (独立面板，管理配置)          │  suiteName:             │  (注入 SpringBoard    │
│                               │  com.ntm.notifymanager  │   拦截通知展示)       │
└──────────────────────────────┘                         └──────────────────────┘
```

**IPA 只管写配置，Tweak 只管读配置拦截通知，互不依赖进程存活。**

## 构建方式

### 方式 1：GitHub Actions（推荐）

1. 将整个项目推送到 GitHub
2. 在 Actions 页面选择 `build-ipa` workflow
3. 下载产物 `NotifyManagerIPA.ipa`

### 方式 2：本地 macOS 构建

```bash
# 需要 Xcode 15+，iOS SDK
cd 越狱插件-通知管理
# 运行构建脚本
chmod +x NotifyManagerIPA/build_ipa.sh
./NotifyManagerIPA/build_ipa.sh
```

产物在 `build/NotifyManagerIPA.ipa`

## 安装方式

### 方式 1：TrollStore（推荐）

用 TrollStore 打开 `NotifyManagerIPA.ipa` 安装即可。

### 方式 2：侧载

使用 SideStore / AltStore / Sideloadly 等工具签名安装。

## 注意事项

1. **IPA 必须配合 Tweak 使用**：IPA 只负责管理配置，实际通知拦截由 Tweak.dylib 在 SpringBoard 中完成
2. **TrollStore 安装效果最佳**：通过 TrollStore 安装可获得 `no-sandbox` 权限，能读取所有已安装 App 列表
3. **配置双向同步**：IPA 和设置面板（PreferenceBundle）读写同一份 NSUserDefaults，配置完全互通
4. **系统通知/网络同步**：由于 IPA 是独立 App，无法调用 BBSettingsGateway 和 PSAppDataUsagePolicyCache 等私有 API 同步系统设置。如需系统同步，请使用设置面板