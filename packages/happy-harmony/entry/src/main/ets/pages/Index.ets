import { http } from '@kit.NetworkKit';

const DEFAULT_SERVER_URL: string = 'https://47.118.25.177';
const HAPPY_SERVER_MARKER: string = 'Welcome to Happy Server!';

@Entry
@Component
struct Index {
  @State private serverUrl: string = DEFAULT_SERVER_URL;
  @State private status: string = '未登录';
  @State private isValidating: boolean = false;

  build() {
    Row() {
      Column({ space: 16 }) {
        Text('Happy')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)

        TextInput({ text: this.serverUrl, placeholder: '服务器地址' })
          .width('100%')
          .height(44)
          .onChange((value: string) => {
            this.serverUrl = value;
          })

        Button(this.isValidating ? '验证中...' : '验证服务器')
          .width('100%')
          .height(44)
          .enabled(!this.isValidating)
          .onClick(() => {
            this.validateServer();
          })

        Text(this.status)
          .fontSize(14)
          .fontColor('#5F6368')
      }
      .width('100%')
      .padding(24)
    }
    .height('100%')
    .backgroundColor('#F7F8FA')
  }

  private validateServer(): void {
    const url = this.serverUrl.trim();
    const error = this.validateServerUrl(url);
    if (error) {
      this.status = error;
      return;
    }

    this.isValidating = true;
    this.status = '正在连接服务器...';
    this.requestServerRoot(url);
  }

  private validateServerUrl(url: string): string | undefined {
    if (url.length === 0) {
      return '请输入服务器地址';
    }
    const schemeEnd = url.indexOf('://');
    if (schemeEnd <= 0) {
      return '服务器地址格式不正确';
    }
    const scheme = url.substring(0, schemeEnd);
    if (scheme !== 'http' && scheme !== 'https') {
      return '服务器地址必须以 http:// 或 https:// 开头';
    }
    const hostAndPath = url.substring(schemeEnd + 3);
    if (hostAndPath.length === 0 || hostAndPath.startsWith('/') || hostAndPath.indexOf(' ') >= 0) {
      return '服务器地址格式不正确';
    }
    return undefined;
  }

  private async requestServerRoot(url: string): Promise<void> {
    const request = http.createHttp();
    try {
      const response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: {
          Accept: 'text/plain',
        },
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 8000,
      });
      const text = this.toResponseText(response.result);
      const isSuccessful = response.responseCode >= 200 && response.responseCode < 300;
      this.status = isSuccessful && text.includes(HAPPY_SERVER_MARKER)
        ? '服务器连接正常'
        : '未识别到 Happy Server';
    } catch {
      this.status = '无法连接服务器';
    } finally {
      request.destroy();
      this.isValidating = false;
    }
  }

  private toResponseText(result: string | Object | ArrayBuffer): string {
    if (typeof result === 'string') {
      return result;
    }
    if (result instanceof ArrayBuffer) {
      return '';
    }
    return JSON.stringify(result);
  }
}
