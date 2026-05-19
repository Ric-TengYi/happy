# HarmonyOS AppGallery 提交流程记录

最后更新：2026-05-06

这份 runbook 用于实际进入华为 AppGallery Connect 后提交 Happy 鸿蒙版。账号登录、实名主体、协议确认、证书创建、应用创建等动作需要由账号持有人完成或在旁确认。

## 当前建议填写值

- 应用名称：`Happy`
- 当前包名：`com.ex3ndr.happy`
- AGC App ID：`6917604787824163736`
- 当前版本：`0.1.0`
- 当前 `versionCode`：`1`
- 当前本机 SDK：HarmonyOS `6.1.1.115` / API `24` / `Beta1`
- 应用分类：待确认
- 客服邮箱：待确认
- 官网：待确认
- 隐私政策 URL：`https://47.118.25.177/privacy/harmonyos`
- 生产 API：`https://47.118.25.177`
- 发布证书名称：`Happy.csr`
- 本地发布证书文件：`packages/happy-harmony/signing/Happy.cer`
- 本地发布密钥库：`packages/happy-harmony/signing/release.p12`
- 发布 Profile 名称：`Happy Release ProfileRelease`
- 本地发布 Profile 文件：`packages/happy-harmony/signing/Happy Release ProfileRelease.p7b`
- 已签名上传包：`packages/happy-harmony/build/outputs/default/happy-harmony-default-signed.app`

## 华为后台入口

- AppGallery Connect 控制台：https://developer.huawei.com/consumer/cn/service/josp/agc/index.html
- AppGallery 产品页：https://developer.huawei.com/consumer/cn/appgallery/
- AppGallery Connect 分发服务：https://developer.huawei.com/consumer/cn/agconnect/distribute/
- HarmonyOS 签名指南：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing
- HarmonyOS 发布指南：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-publish-app

## AGC 操作步骤

1. 登录华为开发者账号，进入 AppGallery Connect 控制台。
2. 确认开发者账号已经完成企业/个人实名认证，并具备发布应用权限。
3. 创建 HarmonyOS 应用，包名填写最终确认的 `bundleName`。
4. 创建或下载发布签名材料，包括发布证书、Profile、密钥库等。发布证书 `Happy.csr` 已创建，证书文件已下载到本地。
5. 在左侧 `Profile` 中创建发布 Profile，绑定 App ID `6917604787824163736` 和发布证书 `Happy.csr`。
6. 在本机下载发布 Profile，并确认本地签名目录包含 `.p12`、`.cer`、`.p7b` 和口令文件。
7. 确认 SDK 不是 AGC 禁止上传的 Beta 版本；如果需要，先在 DevEco SDK Manager 安装正式版 SDK。
8. 本地构建签名 release `.app`。
9. 在 AGC 应用发布页填写基础信息、分类、隐私政策、截图、描述、版本说明、审核说明。
10. 上传签名后的 `.app`，运行预检查/云测。
11. 先提交内部测试或公开测试；验证通过后再提交正式发布。

## 本地构建命令

```bash
cd /Users/kenan/work/ideaProjects/happy/packages/happy-harmony
JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home \
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleApp --no-daemon
```

上述命令只产出 unsigned 包。当前项目使用本地脚本读取 `packages/happy-harmony/signing/` 下的签名材料，再调用 SDK 自带 `hap-sign-tool.jar` 产出可提交的签名包：

```bash
cd /Users/kenan/work/ideaProjects/happy
pnpm --filter happy-harmony run build:release
```

当前已验证的输出：

```text
/Users/kenan/work/ideaProjects/happy/packages/happy-harmony/build/outputs/default/happy-harmony-default-signed.app
SHA-256: c7f7a73e29b94e45469a9d5de503803563b03618852c929b36aca2b3e7deac39
```

## 签名配置模板

不要把真实密码或证书提交进 git。可以把签名材料放在本地忽略目录，例如：

```text
packages/happy-harmony/signing/
packages/happy-harmony/signing-config/
```

DevEco 的 `build-profile.json5` signing config 密码字段通常依赖 DevEco 生成的本地加密 `material` 目录。当前仓库不提交这类本机材料，使用 `packages/happy-harmony/scripts/sign-release-app.sh` 进行本地离线签名。

如果以后改用 DevEco Studio 内置签名配置，`build-profile.json5` 中 release signing config 的字段形态参考：

```json5
{
  "app": {
    "signingConfigs": [
      {
        "name": "release",
        "type": "HarmonyOS",
        "material": {
          "storeFile": "./signing/release.p12",
          "storePassword": "<local-only>",
          "keyAlias": "<local-only>",
          "keyPassword": "<local-only>",
          "signAlg": "SHA256withECDSA",
          "profile": "./signing/Happy Release ProfileRelease.p7b",
          "certpath": "./signing/Happy.cer"
        }
      }
    ],
    "products": [
      {
        "name": "default",
        "signingConfig": "release"
      }
    ]
  }
}
```

实际文件要和 DevEco/AGC 下载的材料名称一致。

## 不能代替账号持有人完成的事项

- 登录、短信/扫码/二次验证。
- 同意华为开发者协议、隐私协议、签名服务协议。
- 实名认证和主体资料填写。
- 创建最终包名对应的线上应用。
- 生成、托管或上传私钥材料。
- 最终点击提交审核或发布。
