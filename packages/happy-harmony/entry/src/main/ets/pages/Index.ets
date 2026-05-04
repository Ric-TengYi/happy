import { common } from '@kit.AbilityKit';
import {
  AuthResult,
  Credentials,
  createAccount,
  formatBackupSecret,
  getDefaultServerUrl,
  getServerUrl,
  loadCredentials,
  logout,
  maskToken,
  restoreAccount,
  setServerUrl,
  validateHappyServer,
  validateServerUrl,
} from '../services/HappyAuth';

@Entry
@Component
struct Index {
  @State private serverUrl: string = getDefaultServerUrl();
  @State private status: string = '正在读取登录状态...';
  @State private accountStatus: string = '正在读取登录状态...';
  @State private restoreSecret: string = '';
  @State private backupSecret: string = '';
  @State private isAuthenticated: boolean = false;
  @State private hasStateLoadError: boolean = false;
  @State private isLoadingState: boolean = true;
  @State private isValidating: boolean = false;
  @State private serverAction: string = '';
  @State private authAction: string = '';

  aboutToAppear(): void {
    this.loadStateAsync();
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        this.Header()
        this.ServerPanel()
        this.AccountPanel()
      }
      .width('100%')
      .padding(24)
    }
    .height('100%')
    .backgroundColor('#F7F8FA')
  }

  @Builder
  private Header() {
    Column({ space: 6 }) {
      Text('Happy')
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor('#202124')

      Text('鸿蒙客户端')
        .fontSize(14)
        .fontColor('#5F6368')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  private ServerPanel() {
    Column({ space: 12 }) {
      Text('服务器')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#202124')
        .width('100%')

      TextInput({ text: this.serverUrl, placeholder: '服务器地址' })
        .width('100%')
        .height(44)
        .backgroundColor(Color.White)
        .onChange((value: string) => {
          this.serverUrl = value;
        })

      Row({ space: 10 }) {
        Button(this.serverAction === 'validate' ? '验证中...' : '验证并保存')
          .layoutWeight(1)
          .height(44)
          .enabled(!this.isBusy())
          .onClick(() => {
            this.validateAndSaveServer();
          })

        Button(this.serverAction === 'reset' ? '恢复中...' : '恢复默认')
          .layoutWeight(1)
          .height(44)
          .enabled(!this.isBusy())
          .onClick(() => {
            this.resetServer();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private AccountPanel() {
    Column({ space: 12 }) {
      Text('账号')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#202124')
        .width('100%')

      Text(this.accountStatus)
        .fontSize(14)
        .fontColor(this.isAuthenticated ? '#137333' : '#5F6368')
        .width('100%')

      if (this.isLoadingState) {
        Text('请稍候')
          .fontSize(13)
          .fontColor('#5F6368')
          .width('100%')
      } else if (this.isAuthenticated) {
        if (this.backupSecret.length > 0) {
          Text(`备份密钥：${this.backupSecret}`)
            .fontSize(12)
            .fontColor('#5F6368')
            .width('100%')
        }

        Button(this.authAction === 'logout' ? '退出中...' : '退出登录')
          .width('100%')
          .height(44)
          .enabled(!this.isBusy())
          .onClick(() => {
            this.logoutAccount();
          })
      } else if (this.hasStateLoadError) {
        Button('重新读取')
          .width('100%')
          .height(44)
          .enabled(!this.isBusy())
          .onClick(() => {
            this.loadStateAsync();
          })
      } else {
        Button(this.authAction === 'create' ? '创建中...' : '创建账号')
          .width('100%')
          .height(44)
          .enabled(!this.isBusy())
          .onClick(() => {
            this.createNewAccount();
          })

        TextArea({ text: this.restoreSecret, placeholder: '输入备份密钥' })
          .width('100%')
          .height(92)
          .backgroundColor(Color.White)
          .onChange((value: string) => {
            this.restoreSecret = value;
          })

        Button(this.authAction === 'restore' ? '恢复中...' : '手动恢复')
          .width('100%')
          .height(44)
          .enabled(!this.isBusy())
          .onClick(() => {
            this.restoreExistingAccount();
          })
      }

      Text(this.status)
        .fontSize(13)
        .fontColor('#5F6368')
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  private async loadStateAsync(): Promise<void> {
    this.isLoadingState = true;
    this.hasStateLoadError = false;
    this.accountStatus = '正在读取登录状态...';
    this.backupSecret = '';
    this.status = '正在读取登录状态...';
    try {
      const context = this.getAbilityContext();
      this.serverUrl = getServerUrl(context);
      const credentials = await loadCredentials(context);
      if (credentials) {
        this.markAuthenticated(credentials, '已从本机读取登录状态');
        this.backupSecret = formatBackupSecret(credentials.secretBase64Url);
      } else {
        this.markUnauthenticated('未登录');
        this.status = '请选择创建账号或手动恢复';
      }
    } catch (error) {
      console.error(`读取登录状态失败：${error}`);
      this.isAuthenticated = false;
      this.backupSecret = '';
      this.accountStatus = '登录状态读取失败';
      this.hasStateLoadError = true;
      this.status = '读取登录状态失败，请稍后重试';
    } finally {
      this.isLoadingState = false;
    }
  }

  private validateAndSaveServer(): void {
    if (this.isBusy()) {
      return;
    }
    const url = this.serverUrl.trim();
    const error = validateServerUrl(url);
    if (error) {
      this.status = error;
      return;
    }

    this.isValidating = true;
    this.serverAction = 'validate';
    this.status = '正在连接服务器...';
    this.validateAndSaveServerAsync(url);
  }

  private async validateAndSaveServerAsync(url: string): Promise<void> {
    try {
      const ok = await validateHappyServer(url);
      if (!ok) {
        this.status = '未识别到 Happy Server';
        return;
      }
      await setServerUrl(this.getAbilityContext(), url);
      this.serverUrl = getServerUrl(this.getAbilityContext());
      this.status = '服务器连接正常，已保存';
    } catch (error) {
      console.error(`无法连接服务器：${error}`);
      this.status = '无法连接服务器，请检查地址和网络';
    } finally {
      this.isValidating = false;
      this.serverAction = '';
    }
  }

  private resetServer(): void {
    if (this.isBusy()) {
      return;
    }
    this.isValidating = true;
    this.serverAction = 'reset';
    this.status = '正在恢复默认服务器...';
    this.resetServerAsync();
  }

  private async resetServerAsync(): Promise<void> {
    try {
      await setServerUrl(this.getAbilityContext(), getDefaultServerUrl());
      this.serverUrl = getDefaultServerUrl();
      this.status = '已恢复默认服务器';
    } catch (error) {
      console.error(`恢复默认服务器失败：${error}`);
      this.status = '恢复默认服务器失败，请稍后重试';
    } finally {
      this.isValidating = false;
      this.serverAction = '';
    }
  }

  private createNewAccount(): void {
    if (this.isBusy()) {
      return;
    }
    const url = this.serverUrl.trim();
    const error = validateServerUrl(url);
    if (error) {
      this.status = error;
      return;
    }

    this.authAction = 'create';
    this.status = '正在创建账号...';
    this.createNewAccountAsync(url);
  }

  private async createNewAccountAsync(url: string): Promise<void> {
    try {
      const result = await createAccount(this.getAbilityContext(), url);
      this.markAuthenticated(result.credentials, '账号创建成功');
      this.backupSecret = result.backupSecret;
      this.serverUrl = getServerUrl(this.getAbilityContext());
    } catch (error) {
      console.error(`创建账号失败：${error}`);
      this.status = `创建账号失败：${this.toUserError(error, '请检查服务器和网络后重试')}`;
    } finally {
      this.authAction = '';
    }
  }

  private restoreExistingAccount(): void {
    if (this.isBusy()) {
      return;
    }
    const url = this.serverUrl.trim();
    const error = validateServerUrl(url);
    if (error) {
      this.status = error;
      return;
    }
    if (this.restoreSecret.trim().length === 0) {
      this.status = '请输入备份密钥';
      return;
    }

    this.authAction = 'restore';
    this.status = '正在恢复账号...';
    this.restoreExistingAccountAsync(url, this.restoreSecret);
  }

  private async restoreExistingAccountAsync(url: string, secret: string): Promise<void> {
    try {
      const result: AuthResult = await restoreAccount(this.getAbilityContext(), url, secret);
      this.restoreSecret = '';
      this.markAuthenticated(result.credentials, '账号恢复成功');
      this.backupSecret = result.backupSecret;
      this.serverUrl = getServerUrl(this.getAbilityContext());
    } catch (error) {
      console.error(`恢复账号失败：${error}`);
      this.status = `恢复账号失败：${this.toUserError(error, '请检查备份密钥、服务器和网络')}`;
    } finally {
      this.authAction = '';
    }
  }

  private logoutAccount(): void {
    if (this.isBusy()) {
      return;
    }
    this.authAction = 'logout';
    this.status = '正在退出登录...';
    this.logoutAccountAsync();
  }

  private async logoutAccountAsync(): Promise<void> {
    try {
      await logout(this.getAbilityContext());
      this.backupSecret = '';
      this.markUnauthenticated('已退出登录，服务器配置已保留');
    } catch (error) {
      console.error(`退出登录失败：${error}`);
      this.status = '退出登录失败，请稍后重试';
    } finally {
      this.authAction = '';
    }
  }

  private markAuthenticated(credentials: Credentials, status: string): void {
    this.isAuthenticated = true;
    this.hasStateLoadError = false;
    this.accountStatus = `已登录：${maskToken(credentials.token)}`;
    this.status = status;
  }

  private markUnauthenticated(status: string): void {
    this.isAuthenticated = false;
    this.hasStateLoadError = false;
    this.accountStatus = '未登录';
    this.status = status;
  }

  private isBusy(): boolean {
    return this.isLoadingState || this.isValidating || this.authAction.length > 0;
  }

  private toUserError(error: Object, fallback: string): string {
    const message = `${error}`.replace(/^Error:\s*/, '');
    if (message.length > 0 && !/[A-Za-z]/.test(message)) {
      return message;
    }
    return fallback;
  }

  private getAbilityContext(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }
}
