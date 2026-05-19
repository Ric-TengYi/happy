# HarmonyOS 上架准备改造清单

最后更新：2026-05-06

这份清单用于跟进 Happy 鸿蒙版在华为 AppGallery / AppGallery Connect 上架前需要补齐的工程、合规、测试和提审事项。

## 当前项目状态

- 鸿蒙工程目录：`packages/happy-harmony`
- 当前包名：`com.ex3ndr.happy`
- 当前版本：`versionCode: 1`，`versionName: 0.1.0`
- 当前应用名称：`Happy`
- 当前构建产物：已可生成签名 `.app`
- 当前本机 SDK：HarmonyOS `6.1.1.115` / API `24` / `Beta1`
- 当前应用图标：已与 Android 主图标 `packages/happy-app/sources/assets/images/icon.png` 对齐
- 当前权限：`ohos.permission.INTERNET`、`ohos.permission.CAMERA`
- 当前鸿蒙默认服务器：`https://47.118.25.177`
- 当前 CLI 默认服务器：`https://47.118.25.177`
- 当前已签名上传包：`packages/happy-harmony/build/outputs/default/happy-harmony-default-signed.app`

## 需要先确认的人工决策

- 确认上架主体和华为开发者账号归属。
- 确认正式应用名称、客服邮箱、官网、应用分类、上架国家/地区。
- 确认正式鸿蒙包名。当前已改为生产移动端同款 `com.ex3ndr.happy`，避免使用 AGC 拒绝的敏感词 `harmony`。
- 确认生产 API 域名。当前已对齐到 `https://47.118.25.177`，上架前还需要确认该服务的长期可用性、备案/合规和 TLS 配置。
- 确认隐私政策 URL：`https://47.118.25.177/privacy/harmonyos`。
- 确认首版是否保留相机扫码登录。如果保留，需要继续申请 `CAMERA` 权限并准备清晰说明。
- 确认首版发布节奏：内部测试、公开测试、分阶段发布，还是直接正式发布。

## 工程改造项

- 发布身份：
  - 更新 `packages/happy-harmony/AppScope/app.json5` 中的 `bundleName`、`vendor`、`versionCode`、`versionName`。
  - 每次提交新包时，`versionCode` 必须递增。
  - AppGallery Connect 中创建应用时填写的包名必须与鸿蒙 `bundleName` 完全一致。

- 发布签名：
  - 在 AppGallery Connect / DevEco Studio 中创建发布证书、Profile 等签名材料。当前发布证书 `Happy.csr` 和 Profile `Happy Release ProfileRelease` 已创建并下载到本地。
  - 当前使用 `packages/happy-harmony/scripts/sign-release-app.sh` 调用 SDK 自带 `hap-sign-tool.jar` 做本地离线签名。
  - 私钥、`.p12`、`.cer`、`.p7b`、Profile 文件不能提交到 git；仓库里只保留示例路径或本地/CI 密钥引用。
  - 已补充 signed release `.app` 构建命令：`pnpm --filter happy-harmony run build:release`。

- SDK 与构建配置：
  - 在 `packages/happy-harmony/build-profile.json5` 显式配置 `targetSdkVersion`，当前值为 `6.1.1(24)`。
  - 当前本机 SDK 产物元数据包含 `releaseType: Beta1`；正式上传前需要确认 AGC 是否接受该 SDK，或在 DevEco SDK Manager 安装可上架的正式版 SDK 后重新构建。
  - 复核 `compatibleSdkVersion: 5.0.0(12)` 是否符合目标设备覆盖范围。
  - 保留稳定的本地构建命令：
    `JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleApp --no-daemon`

- 生产服务器配置：
  - `packages/happy-harmony/entry/src/main/ets/services/HappyAuth.ets` 默认值已对齐到 `https://47.118.25.177`。
  - `packages/happy-harmony/src/core/serverConfigService.ts` 默认值已对齐到 `https://47.118.25.177`。
  - 上架前再次确认 Harmony 与 CLI 默认服务器保持一致。
  - 当前使用 HTTPS 服务地址；如后续切换正式域名，需要同步更新 App、CLI 默认配置和隐私政策 URL。

- 权限：
  - 保留 `ohos.permission.INTERNET`。
  - 仅在首版确实包含扫码登录时保留 `ohos.permission.CAMERA`。
  - 复核 `packages/happy-harmony/entry/src/main/resources/base/element/string.json` 中的 `camera_permission_reason`，确保说明面向用户且与实际用途一致。
  - 测试用户拒绝相机权限、再次授权、无相机权限登录替代路径。

- 应用资源：
  - 在手机和平板上确认替换后的 launcher icon 渲染效果。
  - 准备商店素材：图标、手机截图、平板截图、短描述、完整描述、版本说明、必要的本地化文案。
  - 复核 `module.json5` 中引用的 `startIcon`、`layered_image`，让启动页和桌面图标品牌一致。

## 合规与商店资料

- 准备公开可访问的隐私政策 URL，内容至少覆盖账号/认证数据、加密会话数据、终端/设备元数据、相机扫码、网络请求、日志诊断、数据保留、删除方式、联系方式。
- 在 App 内确认隐私政策、服务条款、客服支持、账号注销/删除入口；若对应地区要求严格，需要在首版前补齐。
- 准备商店元数据：应用名称、分类、年龄分级、联系人、官网、截图、版本说明、审核测试账号或审核说明。
- 如果面向中国大陆发布并使用自有域名服务，确认 ICP/备案及相关地区合规要求。
- 后续如新增第三方 SDK，需要同步更新隐私披露和商店声明。

## 测试门禁

- 执行 `pnpm --filter happy-harmony typecheck`。
- 执行 `pnpm --filter happy-harmony test`。
- 使用 DevEco/hvigor 构建签名 release 包：`pnpm --filter happy-harmony run build:release`。
- 用 `hap-sign-tool.jar verify-app` 校验签名包；当前本地校验结果为 `verify-app success`。
- 尽量在真机上安装 release 包验证，不只依赖模拟器。
- 覆盖新安装、创建账号/登录、扫码绑定终端、终端在线状态、消息/会话同步、拒绝相机权限、退出登录、重启 App、弱网/离线、从上一版本覆盖安装升级。
- 正式发布前优先走 AppGallery Connect 测试能力。

## 提交流程

- 在 AppGallery Connect 创建或选择 HarmonyOS 应用，并使用最终包名。
- 配置应用基本信息和分发信息。
- 上传签名后的 release `.app`。
- 执行可用的预检查、云测或质量检查。
- 时间允许时先发内部测试或公开测试。
- 验证通过后再提交正式发布或分阶段发布。
- 发布后观察崩溃/质量数据、安装转化、用户评价、认证服务指标和客服反馈。

## 官方参考

- 华为 AppGallery 应用创建与提交入口：https://developer.huawei.com/consumer/cn/appgallery/
- AppGallery Connect 分发服务：https://developer.huawei.com/consumer/cn/agconnect/distribute/
- HarmonyOS 应用签名指南：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing
- HarmonyOS 应用发布指南：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-publish-app
