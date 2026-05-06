import { type Fastify } from "../types";
import { type FastifyReply } from "fastify";

const HARMONYOS_PRIVACY_POLICY_HTML = `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Happy HarmonyOS 隐私政策</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f7f8fa;
      --paper: #ffffff;
      --text: #1f2937;
      --muted: #5f6b7a;
      --border: #e5e7eb;
      --accent: #2563eb;
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
      line-height: 1.72;
    }

    main {
      max-width: 920px;
      margin: 0 auto;
      padding: 40px 18px 64px;
    }

    article {
      background: var(--paper);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 36px;
      box-shadow: 0 10px 30px rgba(15, 23, 42, 0.06);
    }

    h1 {
      margin: 0 0 20px;
      font-size: 30px;
      line-height: 1.25;
      letter-spacing: 0;
    }

    h2 {
      margin: 34px 0 12px;
      font-size: 20px;
      line-height: 1.35;
      letter-spacing: 0;
    }

    p {
      margin: 10px 0;
    }

    ol {
      margin: 10px 0 0;
      padding-left: 1.5em;
    }

    li {
      margin: 6px 0;
    }

    .meta {
      color: var(--muted);
      margin: 4px 0;
    }

    .section-title {
      font-weight: 700;
      margin-top: 18px;
    }

    a {
      color: var(--accent);
    }

    @media (max-width: 640px) {
      main {
        padding: 18px 12px 40px;
      }

      article {
        padding: 22px 18px;
      }

      h1 {
        font-size: 24px;
      }
    }
  </style>
</head>
<body>
  <main>
    <article>
      <h1>Happy HarmonyOS 隐私政策</h1>
      <p class="meta">生效日期：2026 年 5 月 6 日</p>
      <p class="meta">更新日期：2026 年 5 月 6 日</p>
      <p class="meta">应用名称：Happy</p>
      <p class="meta">应用包名：com.ex3ndr.happy</p>
      <p class="meta">运营者：滕翼</p>
      <p class="meta">联系方式：<a href="mailto:ricteng1220@gmail.com">ricteng1220@gmail.com</a></p>

      <p>本隐私政策适用于 Happy 的 HarmonyOS 版本。Happy 是一款跨设备终端协作工具，用于连接用户自己的 Happy 服务账号和终端设备，查看终端状态、同步工作会话，并在移动端处理终端授权和会话审批。</p>

      <h2>一、我们如何收集和使用信息</h2>
      <p>我们仅在实现产品功能所必需的范围内收集和使用信息。</p>
      <p class="section-title">1. 账号创建、恢复与认证</p>
      <p>当你创建或恢复 Happy 账号时，应用会生成或使用你的账号密钥，并向 Happy 服务请求认证 token。认证 token 用于识别你的登录状态并访问与你账号关联的终端和会话数据。账号密钥会保存在设备安全存储中，用于端到端加密和解密数据；请妥善保存恢复密钥。</p>
      <p class="section-title">2. 终端绑定和授权</p>
      <p>当你通过扫码或手动输入授权 URL 绑定终端时，应用会读取授权 URL 中的终端公钥，并向 Happy 服务查询授权请求状态、提交加密后的授权响应。该过程用于确认你同意将指定终端绑定到当前账号。</p>
      <p class="section-title">3. 终端和会话同步</p>
      <p>为展示终端列表、终端在线状态、会话列表、会话消息和审批请求，应用会从 Happy 服务获取与你账号相关的数据，包括终端 ID、终端名称、主机名、平台、架构、用户名、主目录、Happy 目录、CLI 版本、在线状态、最近活动时间、会话 ID、会话名称、工作路径、会话摘要、消息内容、工具调用和审批状态等。</p>
      <p>其中，终端元数据、会话元数据、会话消息和代理状态采用加密方式存储和传输。Happy 服务主要保存密文或必要的同步索引；应用在本地使用你的账号密钥进行解密展示。</p>
      <p class="section-title">4. 发送消息和审批操作</p>
      <p>当你在会话中发送消息、修改会话名称、归档会话、重命名终端、创建新会话、停止守护进程、删除终端或处理工具审批请求时，应用会将你的操作内容发送到 Happy 服务或已绑定终端。会话消息会在发送前加密。</p>
      <p class="section-title">5. 服务器配置和工作目录配置</p>
      <p>应用允许你查看或修改 Happy 服务地址，以及设置新会话默认工作目录。这些配置保存在本机，用于连接服务和创建会话。</p>
      <p class="section-title">6. 日志和错误信息</p>
      <p>当应用出现网络、认证、同步或解密错误时，应用可能会在本地显示错误状态或系统日志中记录必要的诊断信息。我们不会主动收集你的设备系统日志。若你主动联系我们排查问题，你提供的截图、日志或问题描述可能包含账号状态、终端信息、会话信息或错误信息，我们仅用于定位和解决问题。</p>

      <h2>二、设备权限说明</h2>
      <p class="section-title">1. 网络访问权限</p>
      <p>权限名称：ohos.permission.INTERNET</p>
      <p>使用目的：连接 Happy 服务，完成账号认证、终端授权、终端和会话同步、消息发送、审批操作及实时状态更新。</p>
      <p class="section-title">2. 相机权限</p>
      <p>权限名称：ohos.permission.CAMERA</p>
      <p>使用目的：仅用于扫描终端授权二维码，以便识别授权 URL 并完成终端绑定。应用不会将相机画面用于扫码以外的目的，也不会保存、上传照片或视频。你也可以选择手动输入授权 URL 完成绑定。</p>

      <h2>三、我们不收集的信息</h2>
      <p>当前 HarmonyOS 版本不会主动收集你的精确位置、通讯录、短信、通话记录、麦克风录音、日历、相册照片、健康数据、支付信息或广告标识。</p>
      <p>当前 HarmonyOS 版本未接入广告 SDK、统计分析 SDK、推送 SDK、支付 SDK 或第三方登录 SDK。如后续版本新增第三方 SDK 或新的个人信息处理场景，我们会在更新前修改本隐私政策，并按适用规则取得你的同意。</p>

      <h2>四、信息存储和安全</h2>
      <p>应用会将认证 token 和账号密钥保存在 HarmonyOS 提供的安全存储能力中，将服务器地址、工作目录等配置保存在本机偏好设置中。</p>
      <p>Happy 服务会保存实现同步所必需的数据。会话内容、终端元数据和会话元数据等数据采用加密方式处理，服务端通常无法直接读取明文内容。我们会采取合理的安全措施保护数据，包括访问控制、传输加密、密钥分离和最小必要的数据处理。</p>
      <p>由于互联网服务无法保证绝对安全，请你妥善保管账号恢复密钥和终端设备，不要向他人泄露授权二维码、授权 URL、认证 token 或恢复密钥。</p>

      <h2>五、信息共享、转让和公开披露</h2>
      <p>我们不会出售你的个人信息。</p>
      <p>除以下情形外，我们不会向第三方共享、转让或公开披露你的个人信息：</p>
      <ol>
        <li>获得你的明确同意；</li>
        <li>为履行法律法规、监管要求、司法或行政机关要求所必需；</li>
        <li>为保护用户、我们或公众的人身财产安全和合法权益，在法律允许范围内处理必要信息；</li>
        <li>因合并、分立、收购、资产转让等原因需要转移信息时，我们会要求新的持有方继续受本隐私政策约束。</li>
      </ol>

      <h2>六、你的权利</h2>
      <p>你可以在应用内退出登录，以删除本机保存的认证 token 和账号密钥。退出登录不会自动删除服务端已同步的数据。</p>
      <p>你可以通过应用功能删除或归档部分终端、会话信息。若你需要访问、更正、删除账号相关数据，或需要注销账号、撤回同意、投诉和咨询隐私问题，请通过本政策开头列明的联系方式与我们联系。我们会在验证身份后，在法律法规要求的期限内处理。</p>
      <p>请注意，若删除账号密钥或恢复密钥，你可能无法解密历史会话数据。为保障账号安全，我们可能需要你提供必要信息以确认请求来自账号本人。</p>

      <h2>七、未成年人保护</h2>
      <p>Happy 面向具备开发和终端协作需求的用户，不面向未成年人提供专门服务。若你是未成年人，请在监护人同意和指导下使用本应用。若监护人发现未成年人未经同意向我们提供了个人信息，请通过本政策列明的联系方式联系我们，我们会依法处理。</p>

      <h2>八、政策更新</h2>
      <p>我们可能会根据产品功能、法律法规或审核要求更新本隐私政策。发生重大变化时，我们会通过应用内提示、版本更新说明或其他适当方式通知你。更新后的隐私政策自公布或通知载明的日期起生效。</p>

      <h2>九、联系我们</h2>
      <p>如你对本隐私政策或个人信息处理有任何疑问、意见或请求，请通过以下方式联系我们：</p>
      <p>运营者：滕翼</p>
      <p>联系邮箱：<a href="mailto:ricteng1220@gmail.com">ricteng1220@gmail.com</a></p>
      <p>应用名称：Happy</p>
      <p>应用包名：com.ex3ndr.happy</p>
    </article>
  </main>
</body>
</html>`;

function sendHarmonyOsPrivacyPolicy(reply: FastifyReply) {
    return reply
        .header("content-type", "text/html; charset=utf-8")
        .header("cache-control", "public, max-age=300")
        .send(HARMONYOS_PRIVACY_POLICY_HTML);
}

export function legalRoutes(app: Fastify) {
    app.get("/privacy/harmonyos", async (_request, reply) => {
        return sendHarmonyOsPrivacyPolicy(reply);
    });

    app.get("/privacy/harmonyos.html", async (_request, reply) => {
        return sendHarmonyOsPrivacyPolicy(reply);
    });
}
