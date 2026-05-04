import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import {
  AuthResult,
  Credentials,
  TerminalAuthResult,
  approveTerminalAuthUrl,
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
import {
  ControlPlaneSnapshot,
  HappyMachine,
  HappySession,
  getControlPlaneSummary,
  getMachineSubtitle,
  getMachineTitle,
  getSessionSubtitle,
  getSessionTitle,
  loadControlPlaneSnapshot,
} from '../services/HappySync';

const TAB_INBOX: string = 'inbox';
const TAB_TERMINAL: string = 'terminal';
const TAB_SETTINGS: string = 'settings';
const SCAN_CANCEL_CODE: number = scanCore.ScanErrorCode.SCAN_SERVICE_CANCELED;

@Entry
@Component
struct Index {
  @State private activeTab: string = TAB_INBOX;
  @State private serverUrl: string = getDefaultServerUrl();
  @State private status: string = '正在读取登录状态...';
  @State private accountStatus: string = '正在读取登录状态...';
  @State private restoreSecret: string = '';
  @State private backupSecret: string = '';
  @State private terminalQrText: string = '';
  @State private terminalAuthStatus: string = '';
  @State private isAuthenticated: boolean = false;
  @State private hasStateLoadError: boolean = false;
  @State private isLoadingState: boolean = true;
  @State private isValidating: boolean = false;
  @State private showServerPanel: boolean = false;
  @State private serverAction: string = '';
  @State private authAction: string = '';
  @State private machines: HappyMachine[] = [];
  @State private sessions: HappySession[] = [];
  @State private syncStatus: string = '同步未开始';
  @State private isSyncLoading: boolean = false;
  @State private hasQueuedSyncRefresh: boolean = false;
  @State private syncGeneration: number = 0;

  aboutToAppear(): void {
    this.loadStateAsync();
  }

  build() {
    Column() {
      this.AppHeader()

      Scroll() {
        Column({ space: 16 }) {
          if (this.activeTab === TAB_INBOX) {
            this.InboxContent()
          } else if (this.activeTab === TAB_TERMINAL) {
            this.TerminalContent()
          } else {
            this.SettingsContent()
          }
        }
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .justifyContent(FlexAlign.Start)
        .padding({ left: 20, right: 20, top: 18, bottom: 18 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)

      this.BottomNavigation()
    }
    .height('100%')
    .width('100%')
    .justifyContent(FlexAlign.Start)
    .backgroundColor('#F7F8FA')
  }

  @Builder
  private AppHeader() {
    Row() {
      Column({ space: 2 }) {
        Text(this.getHeaderTitle())
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#202124')

        Text(this.getHeaderSubtitle())
          .fontSize(12)
          .fontColor('#5F6368')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.activeTab === TAB_SETTINGS) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.storagebox'))
            .fontSize(22)
            .fontColor([this.showServerPanel ? '#0B57D0' : '#202124'])
        }
          .width(44)
          .height(40)
          .backgroundColor(this.showServerPanel ? '#E8F0FE' : '#FFFFFF')
          .borderRadius(8)
          .onClick(() => {
            this.showServerPanel = !this.showServerPanel;
          })
      } else {
        Blank()
          .width(44)
          .height(40)
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: 12 })
    .backgroundColor('#F7F8FA')
  }

  @Builder
  private InboxContent() {
    Column({ space: 14 }) {
      this.StatusStrip()

      if (this.isLoadingState) {
        this.LoadingPanel()
      } else if (!this.isAuthenticated) {
        Column({ space: 10 }) {
          Text('暂无收件')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#202124')
            .width('100%')

          Text('请先在设置中创建或恢复账号')
            .fontSize(14)
            .fontColor('#5F6368')
            .width('100%')

          Button('去设置账号')
            .width('100%')
            .height(44)
            .enabled(!this.isBusy())
            .onClick(() => {
              this.activeTab = TAB_SETTINGS;
            })
        }
        .width('100%')
        .padding(18)
        .backgroundColor(Color.White)
        .borderRadius(8)
      } else {
        this.SyncSummaryPanel()
        this.SessionListPanel()
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
  }

  @Builder
  private TerminalContent() {
    Column({ space: 14 }) {
      this.StatusStrip()

      if (this.isLoadingState) {
        this.LoadingPanel()
      } else if (!this.isAuthenticated) {
        this.RequireAccountPanel()
      } else {
        this.SyncSummaryPanel()
        this.MachineListPanel()

        Column({ space: 14 }) {
          Text('关联终端')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#202124')
            .width('100%')

          Button({ type: ButtonType.Normal }) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.camera'))
                .fontSize(20)
                .fontColor([Color.White])

              Text(this.authAction === 'terminalScan' ? '扫码中...' : '扫描二维码')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
            }
            .justifyContent(FlexAlign.Center)
          }
            .width('100%')
            .height(48)
            .backgroundColor('#0B57D0')
            .borderRadius(8)
            .enabled(!this.isBusy())
            .onClick(() => {
              this.scanTerminalAuth();
            })

          Text('手动输入 URL')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#202124')
            .width('100%')

          TextArea({ text: this.terminalQrText, placeholder: '粘贴 happy://terminal?... 或终端授权 URL' })
            .width('100%')
            .height(96)
            .backgroundColor('#F7F8FA')
            .onChange((value: string) => {
              this.terminalQrText = value;
            })

          Button(this.authAction === 'terminalAuth' ? '授权中...' : '授权终端')
            .width('100%')
            .height(44)
            .enabled(!this.isBusy())
            .onClick(() => {
              this.approveTerminalAuth();
            })

          if (this.terminalAuthStatus.length > 0) {
            Text(this.terminalAuthStatus)
              .fontSize(13)
              .fontColor('#5F6368')
              .width('100%')
          }
        }
        .width('100%')
        .padding(18)
        .backgroundColor(Color.White)
        .borderRadius(8)
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
  }

  @Builder
  private SettingsContent() {
    Column({ space: 14 }) {
      if (this.showServerPanel) {
        this.ServerPanel()
      } else {
        Row() {
          Column({ space: 2 }) {
            Text('服务器')
              .fontSize(14)
              .fontColor('#5F6368')
            Text(this.serverUrl)
              .fontSize(13)
              .fontColor('#202124')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('点击右上角修改')
            .fontSize(12)
            .fontColor('#5F6368')
        }
        .width('100%')
        .padding(14)
        .backgroundColor(Color.White)
        .borderRadius(8)
        .onClick(() => {
          this.showServerPanel = true;
        })
      }

      this.AccountPanel()
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
  }

  @Builder
  private StatusStrip() {
    Row({ space: 8 }) {
      Circle()
        .width(8)
        .height(8)
        .fill(this.isAuthenticated ? '#137333' : '#9AA0A6')

      Text(this.accountStatus)
        .fontSize(13)
        .fontColor(this.isAuthenticated ? '#137333' : '#5F6368')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor('#EEF3F8')
    .borderRadius(8)
  }

  @Builder
  private SyncSummaryPanel() {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(this.syncStatus)
          .fontSize(13)
          .fontColor('#202124')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.machines.length > 0 || this.sessions.length > 0 ? getControlPlaneSummary({
          machines: this.machines,
          sessions: this.sessions,
        }) : '终端授权后会自动同步机器和会话')
          .fontSize(12)
          .fontColor('#5F6368')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button(this.isSyncLoading ? '同步中' : '刷新')
        .width(76)
        .height(36)
        .enabled(!this.isSyncLoading && this.isAuthenticated)
        .onClick(() => {
          this.refreshControlPlaneData();
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private MachineListPanel() {
    Column({ space: 12 }) {
      Row() {
        Text('已关联终端')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#202124')
          .layoutWeight(1)

        Text(`${this.machines.length} 台`)
          .fontSize(12)
          .fontColor('#5F6368')
      }
      .width('100%')

      if (this.isSyncLoading && this.machines.length === 0) {
        Text('正在读取终端列表...')
          .fontSize(14)
          .fontColor('#5F6368')
          .width('100%')
      } else if (this.machines.length === 0) {
        Text('还没有读取到已授权终端。可以扫码或粘贴 URL 关联 CLI。')
          .fontSize(14)
          .fontColor('#5F6368')
          .width('100%')
      } else {
        ForEach(this.machines, (machine: HappyMachine) => {
          this.MachineRow(machine)
        }, (machine: HappyMachine) => machine.id)
      }
    }
    .width('100%')
    .padding(18)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private MachineRow(machine: HappyMachine) {
    Row({ space: 10 }) {
      Circle()
        .width(10)
        .height(10)
        .fill(machine.active ? '#137333' : '#9AA0A6')

      Column({ space: 2 }) {
        Text(getMachineTitle(machine))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#202124')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(getMachineSubtitle(machine))
          .fontSize(12)
          .fontColor('#5F6368')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor('#F7F8FA')
    .borderRadius(8)
  }

  @Builder
  private SessionListPanel() {
    Column({ space: 12 }) {
      Row() {
        Text('最近会话')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#202124')
          .layoutWeight(1)

        Text(`${this.sessions.length} 个`)
          .fontSize(12)
          .fontColor('#5F6368')
      }
      .width('100%')

      if (this.isSyncLoading && this.sessions.length === 0) {
        Text('正在读取会话列表...')
          .fontSize(14)
          .fontColor('#5F6368')
          .width('100%')
      } else if (this.sessions.length === 0) {
        Text('暂无会话。终端启动 Happy 会话后会显示在这里。')
          .fontSize(14)
          .fontColor('#5F6368')
          .width('100%')
      } else {
        ForEach(this.sessions, (session: HappySession) => {
          this.SessionRow(session)
        }, (session: HappySession) => session.id)
      }
    }
    .width('100%')
    .padding(18)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private SessionRow(session: HappySession) {
    Row({ space: 10 }) {
      Circle()
        .width(10)
        .height(10)
        .fill(session.active ? '#137333' : '#9AA0A6')

      Column({ space: 2 }) {
        Text(getSessionTitle(session))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#202124')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(getSessionSubtitle(session))
          .fontSize(12)
          .fontColor('#5F6368')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor('#F7F8FA')
    .borderRadius(8)
  }

  @Builder
  private LoadingPanel() {
    Column({ space: 8 }) {
      Text('正在读取登录状态...')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#202124')
        .width('100%')

      Text('请稍候')
        .fontSize(13)
        .fontColor('#5F6368')
        .width('100%')
    }
    .width('100%')
    .padding(18)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private RequireAccountPanel() {
    Column({ space: 12 }) {
      Text('需要账号')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#202124')
        .width('100%')

      Text('请先在设置中创建或恢复账号，再关联终端')
        .fontSize(14)
        .fontColor('#5F6368')
        .width('100%')

      Button('去设置账号')
        .width('100%')
        .height(44)
        .enabled(!this.isBusy())
        .onClick(() => {
          this.activeTab = TAB_SETTINGS;
        })
    }
    .width('100%')
    .padding(18)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private ServerPanel() {
    Column({ space: 12 }) {
      Text('服务器地址')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#202124')
        .width('100%')

      TextInput({ text: this.serverUrl, placeholder: '服务器地址' })
        .width('100%')
        .height(44)
        .backgroundColor('#F7F8FA')
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
    .padding(18)
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
          .backgroundColor('#F7F8FA')
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
    .padding(18)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private BottomNavigation() {
    Row() {
      this.TabItem(TAB_INBOX, '收件箱')
      this.TabItem(TAB_TERMINAL, '终端')
      this.TabItem(TAB_SETTINGS, '设置')
    }
    .width('100%')
    .height(70)
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .backgroundColor(Color.White)
    .borderWidth({ top: 1 })
    .borderColor('#E5E7EB')
  }

  @Builder
  private TabItem(tab: string, label: string) {
    Column({ space: 2 }) {
      this.TabIcon(tab)

      Text(label)
        .fontSize(11)
        .fontColor(this.activeTab === tab ? '#0B57D0' : '#5F6368')
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height('100%')
    .borderRadius(8)
    .backgroundColor(this.activeTab === tab ? '#E8F0FE' : Color.Transparent)
    .onClick(() => {
      this.activeTab = tab;
    })
  }

  @Builder
  private TabIcon(tab: string) {
    if (tab === TAB_INBOX) {
      if (this.activeTab === tab) {
        SymbolGlyph($r('sys.symbol.inbox_fill'))
          .fontSize(22)
          .fontColor(['#0B57D0'])
      } else {
        SymbolGlyph($r('sys.symbol.inbox'))
          .fontSize(22)
          .fontColor(['#5F6368'])
      }
    } else if (tab === TAB_TERMINAL) {
      SymbolGlyph($r('sys.symbol.code_square'))
        .fontSize(22)
        .fontColor([this.activeTab === tab ? '#0B57D0' : '#5F6368'])
    } else {
      if (this.activeTab === tab) {
        SymbolGlyph($r('sys.symbol.gearshape_fill'))
          .fontSize(22)
          .fontColor(['#0B57D0'])
      } else {
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(22)
          .fontColor(['#5F6368'])
      }
    }
  }

  private async loadStateAsync(): Promise<void> {
    this.isLoadingState = true;
    this.hasStateLoadError = false;
    this.accountStatus = '正在读取登录状态...';
    this.backupSecret = '';
    this.terminalAuthStatus = '';
    this.status = '正在读取登录状态...';
    this.syncStatus = '同步未开始';
    try {
      const context = this.getAbilityContext();
      this.serverUrl = getServerUrl(context);
      const credentials = await loadCredentials(context);
      if (credentials) {
        this.markAuthenticated(credentials, '已从本机读取登录状态');
        this.backupSecret = formatBackupSecret(credentials.secretBase64Url);
        this.refreshControlPlaneData();
      } else {
        this.markUnauthenticated('未登录');
        this.clearControlPlaneData('未登录，已清空同步数据');
        this.status = '请选择创建账号或手动恢复';
        this.activeTab = TAB_SETTINGS;
      }
    } catch (error) {
      console.error(`读取登录状态失败：${error}`);
      this.isAuthenticated = false;
      this.backupSecret = '';
      this.terminalAuthStatus = '';
      this.accountStatus = '登录状态读取失败';
      this.clearControlPlaneData('同步未开始');
      this.hasStateLoadError = true;
      this.status = '读取登录状态失败，请稍后重试';
      this.activeTab = TAB_SETTINGS;
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
      this.terminalAuthStatus = error;
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
      this.showServerPanel = false;
      this.clearControlPlaneData('服务器已切换，等待重新同步');
      if (this.isAuthenticated) {
        this.refreshControlPlaneData();
      }
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
      this.showServerPanel = false;
      this.clearControlPlaneData('服务器已恢复默认，等待重新同步');
      if (this.isAuthenticated) {
        this.refreshControlPlaneData();
      }
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
      this.activeTab = TAB_INBOX;
      this.refreshControlPlaneData();
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
      this.activeTab = TAB_INBOX;
      this.refreshControlPlaneData();
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
      this.terminalQrText = '';
      this.terminalAuthStatus = '';
      this.clearControlPlaneData('已退出登录，已清空同步数据');
      this.markUnauthenticated('已退出登录，服务器配置已保留');
      this.activeTab = TAB_SETTINGS;
    } catch (error) {
      console.error(`退出登录失败：${error}`);
      this.status = '退出登录失败，请稍后重试';
    } finally {
      this.authAction = '';
    }
  }

  private scanTerminalAuth(): void {
    if (this.isBusy()) {
      return;
    }
    const url = this.serverUrl.trim();
    const error = validateServerUrl(url);
    if (error) {
      this.terminalAuthStatus = error;
      this.status = error;
      return;
    }

    this.authAction = 'terminalScan';
    this.terminalAuthStatus = '正在打开相机...';
    this.status = '正在打开相机...';
    this.scanTerminalAuthAsync(url);
  }

  private async scanTerminalAuthAsync(url: string): Promise<void> {
    try {
      const result = await scanBarcode.startScanForResult(this.getAbilityContext(), {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableAlbum: false,
      });
      const authUrl = result.originalValue.trim();
      if (authUrl.length === 0) {
        throw new Error('未识别到二维码内容');
      }
      this.terminalAuthStatus = '已识别二维码，正在授权终端...';
      this.status = '已识别二维码，正在授权终端...';
      await this.finishTerminalAuth(url, authUrl, false);
    } catch (error) {
      console.error(`扫码授权失败：${error}`);
      const message = this.isScanCancel(error) ? '已取消扫码' : this.toUserError(error, '扫码失败，请检查相机权限后重试', true);
      this.terminalAuthStatus = message;
      this.status = message;
      this.authAction = '';
    }
  }

  private approveTerminalAuth(): void {
    if (this.isBusy()) {
      return;
    }
    const url = this.serverUrl.trim();
    const error = validateServerUrl(url);
    if (error) {
      this.status = error;
      return;
    }
    const authUrl = this.terminalQrText.trim();
    if (authUrl.length === 0) {
      this.terminalAuthStatus = '请先粘贴终端二维码内容';
      this.status = '请先粘贴终端二维码内容';
      return;
    }

    this.authAction = 'terminalAuth';
    this.terminalAuthStatus = '正在授权终端...';
    this.status = '正在授权终端...';
    this.finishTerminalAuth(url, authUrl, true);
  }

  private async finishTerminalAuth(url: string, authUrl: string, clearManualInput: boolean): Promise<void> {
    try {
      const result: TerminalAuthResult = await approveTerminalAuthUrl(this.getAbilityContext(), url, authUrl);
      if (clearManualInput) {
        this.terminalQrText = '';
      }
      if (result.status === 'approved') {
        this.terminalAuthStatus = `终端授权成功：${result.publicKeyPreview}`;
        this.status = '终端授权成功，请回到 CLI 查看连接状态';
        this.refreshControlPlaneData();
      } else if (result.status === 'already_authorized') {
        this.terminalAuthStatus = `该终端已授权：${result.publicKeyPreview}`;
        this.status = '该终端已授权';
        this.refreshControlPlaneData();
      } else {
        this.terminalAuthStatus = `未找到待授权终端：${result.publicKeyPreview}`;
        this.status = '未找到待授权终端，请在 CLI 重新生成二维码';
      }
    } catch (error) {
      console.error(`终端授权失败：${error}`);
      this.terminalAuthStatus = `终端授权失败：${this.toUserError(error, '请检查二维码内容、服务器和网络', true)}`;
      this.status = this.terminalAuthStatus;
    } finally {
      this.authAction = '';
    }
  }

  private refreshControlPlaneData(): void {
    if (!this.isAuthenticated) {
      return;
    }
    if (this.isSyncLoading) {
      this.hasQueuedSyncRefresh = true;
      return;
    }
    const generation = this.syncGeneration + 1;
    const serverUrl = this.serverUrl;
    this.syncGeneration = generation;
    this.hasQueuedSyncRefresh = false;
    this.isSyncLoading = true;
    this.syncStatus = '正在同步终端和会话...';
    this.refreshControlPlaneDataAsync(generation, serverUrl);
  }

  private async refreshControlPlaneDataAsync(generation: number, serverUrl: string): Promise<void> {
    try {
      const snapshot: ControlPlaneSnapshot = await loadControlPlaneSnapshot(this.getAbilityContext(), serverUrl);
      if (!this.isCurrentSync(generation)) {
        return;
      }
      this.machines = snapshot.machines;
      this.sessions = snapshot.sessions;
      this.syncStatus = snapshot.decodeWarningCount > 0 ? `同步完成，${snapshot.decodeWarningCount} 个字段解密失败` : '同步完成';
    } catch (error) {
      if (!this.isCurrentSync(generation)) {
        return;
      }
      console.error(`同步终端和会话失败：${error}`);
      this.syncStatus = `同步失败：${this.toUserError(error, '请检查服务器、网络和登录状态')}`;
    } finally {
      if (generation === this.syncGeneration) {
        this.isSyncLoading = false;
        if (this.hasQueuedSyncRefresh && this.isAuthenticated) {
          this.refreshControlPlaneData();
        }
      }
    }
  }

  private clearControlPlaneData(status: string): void {
    this.syncGeneration += 1;
    this.hasQueuedSyncRefresh = false;
    this.machines = [];
    this.sessions = [];
    this.syncStatus = status;
    this.isSyncLoading = false;
  }

  private isCurrentSync(generation: number): boolean {
    return generation === this.syncGeneration && this.isAuthenticated;
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

  private isScanCancel(error: Object): boolean {
    const scanError = error as BusinessError;
    if (scanError.code === SCAN_CANCEL_CODE) {
      return true;
    }
    const message = `${scanError.message}`;
    const raw = `${error} ${message}`.toLowerCase();
    return raw.indexOf(`${SCAN_CANCEL_CODE}`) >= 0 || raw.indexOf('cancel') >= 0 || raw.indexOf('取消') >= 0;
  }

  private toUserError(error: Object, fallback: string, allowAuthUrlHint: boolean = false): string {
    const message = `${error}`.replace(/^Error:\s*/, '');
    if (allowAuthUrlHint && message.indexOf('happy://terminal?') >= 0) {
      return message;
    }
    if (message.length > 0 && !/[A-Za-z]/.test(message)) {
      return message;
    }
    return fallback;
  }

  private getHeaderTitle(): string {
    if (this.activeTab === TAB_TERMINAL) {
      return '终端';
    }
    if (this.activeTab === TAB_SETTINGS) {
      return '设置';
    }
    return '收件箱';
  }

  private getHeaderSubtitle(): string {
    if (this.activeTab === TAB_TERMINAL) {
      return '扫码或输入 URL 关联终端';
    }
    if (this.activeTab === TAB_SETTINGS) {
      return '账号与服务器';
    }
    return this.isAuthenticated ? 'Happy 鸿蒙客户端' : '请先完成账号设置';
  }

  private getAbilityContext(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }
}
