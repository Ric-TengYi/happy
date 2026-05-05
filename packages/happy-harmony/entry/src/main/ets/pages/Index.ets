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
import {
  HappyRealtimeSync,
  MachineActivityEvent,
  SessionActivityEvent,
} from '../services/HappyRealtimeSync';
import {
  HappyMessage,
  HappyPermission,
  SendSessionMessageResult,
  SessionMessagesSnapshot,
  createLocalMessageId,
  createOptimisticUserMessage,
  getMessageRoleLabel,
  loadSessionMessages,
  sendSessionTextMessage,
} from '../services/HappyMessages';
import { PermissionAction, respondToSessionPermission } from '../services/HappySessionRpc';

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
  @State private realtimeStatus: string = '实时同步未连接';
  @State private isSyncLoading: boolean = false;
  @State private hasQueuedSyncRefresh: boolean = false;
  @State private syncGeneration: number = 0;
  @State private selectedSessionId: string = '';
  @State private messages: HappyMessage[] = [];
  @State private permissions: HappyPermission[] = [];
  @State private messageStatus: string = '';
  @State private messageDraft: string = '';
  @State private messageSendStatus: string = '';
  @State private permissionActionStatus: string = '';
  @State private activePermissionActionId: string = '';
  @State private isMessagesLoading: boolean = false;
  @State private isMessageSending: boolean = false;
  @State private isPermissionSubmitting: boolean = false;
  @State private hasQueuedMessageRefresh: boolean = false;
  @State private messageGeneration: number = 0;
  private realtimeSync: HappyRealtimeSync = new HappyRealtimeSync();
  private isPageActive: boolean = false;
  private loadStateGeneration: number = 0;
  private realtimeGeneration: number = 0;
  private messageSendGeneration: number = 0;
  private pendingMessages: HappyMessage[] = [];
  private retryMessageLocalId: string = '';
  private retryMessageText: string = '';
  private retryMessageCreatedAt: number = 0;

  aboutToAppear(): void {
    this.isPageActive = true;
    this.loadStateAsync();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    this.loadStateGeneration += 1;
    this.messageGeneration += 1;
    this.messageSendGeneration += 1;
    this.hasQueuedMessageRefresh = false;
    this.isMessagesLoading = false;
    this.isMessageSending = false;
    this.isPermissionSubmitting = false;
    this.activePermissionActionId = '';
    this.pendingMessages = [];
    this.clearRetryMessage();
    this.stopRealtimeSync('实时同步未连接');
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
        if (this.selectedSessionId.length > 0) {
          this.SessionDetailPanel()
        } else {
          this.SyncSummaryPanel()
          this.SessionListPanel()
        }
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

        Text(this.realtimeStatus)
          .fontSize(12)
          .fontColor('#5F6368')
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
    .onClick(() => {
      this.openSessionDetail(session.id);
    })
  }

  @Builder
  private SessionDetailPanel() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Button('返回')
          .width(68)
          .height(36)
          .enabled(!this.isMessagesLoading)
          .onClick(() => {
            this.closeSessionDetail();
          })

        Column({ space: 2 }) {
          Text(this.getSelectedSessionTitle())
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#202124')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(this.getSelectedSessionSubtitle())
            .fontSize(12)
            .fontColor('#5F6368')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button(this.isMessagesLoading ? '读取中' : '刷新')
          .width(76)
          .height(36)
          .enabled(!this.isMessagesLoading && this.isAuthenticated)
          .onClick(() => {
            this.refreshSelectedSessionMessages();
          })
      }
      .width('100%')

      Text(this.messageStatus.length > 0 ? this.messageStatus : '点击刷新读取消息')
        .fontSize(12)
        .fontColor('#5F6368')
        .width('100%')

      if (this.permissions.length > 0) {
        this.PermissionPanel()
      }

      if (this.isMessagesLoading && this.messages.length === 0) {
        Text('正在读取会话消息...')
          .fontSize(14)
          .fontColor('#5F6368')
          .width('100%')
      } else if (this.messages.length === 0) {
        Text('暂无消息。该会话有新消息后会显示在这里。')
          .fontSize(14)
          .fontColor('#5F6368')
          .width('100%')
      } else {
        ForEach(this.messages, (message: HappyMessage) => {
          this.MessageRow(message)
        }, (message: HappyMessage) => message.id)
      }

      Column({ space: 10 }) {
        TextArea({ text: this.messageDraft, placeholder: '输入消息' })
          .width('100%')
          .height(92)
          .backgroundColor('#F7F8FA')
          .onChange((value: string) => {
            this.messageDraft = value;
            if (this.retryMessageText.length > 0 && value.trim() !== this.retryMessageText) {
              this.clearRetryMessage();
            }
          })

        Row({ space: 10 }) {
          Text(this.messageSendStatus.length > 0 ? this.messageSendStatus : ' ')
            .fontSize(12)
            .fontColor('#5F6368')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Button(this.isMessageSending ? '发送中' : '发送')
            .width(76)
            .height(36)
            .enabled(this.canSendMessage())
            .onClick(() => {
              this.sendSelectedSessionMessage();
            })
        }
        .width('100%')
      }
      .width('100%')
    }
    .width('100%')
    .padding(18)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private PermissionPanel() {
    Column({ space: 10 }) {
      Row() {
        Text('工具审批')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#202124')
          .layoutWeight(1)

        Text(`${this.getPendingPermissionCount()} 个待处理`)
          .fontSize(12)
          .fontColor('#5F6368')
      }
      .width('100%')

      if (this.permissionActionStatus.length > 0) {
        Text(this.permissionActionStatus)
          .fontSize(12)
          .fontColor('#5F6368')
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      ForEach(this.permissions, (permission: HappyPermission) => {
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text(permission.toolName)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#202124')
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            Text(this.getPermissionStatusLabel(permission))
              .fontSize(12)
              .fontColor(this.getPermissionStatusColor(permission))
          }
          .width('100%')

          if (permission.argumentsText.length > 0) {
            Text(permission.argumentsText)
              .fontSize(12)
              .fontColor('#5F6368')
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }

          if (permission.status === 'pending') {
            Row({ space: 8 }) {
              Button('允许')
                .height(34)
                .layoutWeight(1)
                .enabled(this.canSubmitPermission(permission))
                .onClick(() => {
                  this.submitPermissionAction(permission, 'allow');
                })

              if (this.shouldShowAllowForSession(permission)) {
                Button(this.getAllowForSessionLabel(permission))
                  .height(34)
                  .layoutWeight(1.4)
                  .enabled(this.canSubmitPermission(permission))
                  .onClick(() => {
                    this.submitPermissionAction(permission, 'allowForSession');
                  })
              }

              Button(this.getDenyPermissionLabel(permission))
                .height(34)
                .layoutWeight(1)
                .enabled(this.canSubmitPermission(permission))
                .onClick(() => {
                  this.submitPermissionAction(permission, 'deny');
                })
            }
            .width('100%')

            if (this.shouldShowClaudeModeActions(permission)) {
              Row({ space: 8 }) {
                if (this.shouldShowAllowAllEdits(permission)) {
                  Button('允许全部编辑')
                    .height(34)
                    .layoutWeight(1)
                    .enabled(this.canSubmitPermission(permission))
                    .onClick(() => {
                      this.submitPermissionAction(permission, 'allowAllEdits');
                    })
                }

                if (this.shouldShowAllowEverything(permission)) {
                  Button('允许全部操作')
                    .height(34)
                    .layoutWeight(1)
                    .enabled(this.canSubmitPermission(permission))
                    .onClick(() => {
                      this.submitPermissionAction(permission, 'allowEverything');
                    })
                }
              }
              .width('100%')
            }
          } else if (permission.reason.length > 0) {
            Text(permission.reason)
              .fontSize(12)
              .fontColor('#5F6368')
              .width('100%')
          }
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#F7F8FA')
        .borderRadius(8)
      }, (permission: HappyPermission) => permission.id)
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFF7E6')
    .borderRadius(8)
  }

  @Builder
  private MessageRow(message: HappyMessage) {
    Row() {
      if (message.role === 'user') {
        Blank()
          .layoutWeight(1)
      }

      Column({ space: 4 }) {
        Text(getMessageRoleLabel(message))
          .fontSize(11)
          .fontColor(this.getMessageMetaColor(message))
          .width('100%')

        Text(message.text)
          .fontSize(14)
          .fontColor(this.getMessageTextColor(message))
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('84%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor(this.getMessageBackgroundColor(message))
      .borderRadius(8)

      if (message.role !== 'user') {
        Blank()
          .layoutWeight(1)
      }
    }
    .width('100%')
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
    const generation = this.loadStateGeneration + 1;
    this.loadStateGeneration = generation;
    this.isLoadingState = true;
    this.hasStateLoadError = false;
    this.accountStatus = '正在读取登录状态...';
    this.backupSecret = '';
    this.terminalAuthStatus = '';
    this.status = '正在读取登录状态...';
    this.syncStatus = '同步未开始';
    this.stopRealtimeSync('实时同步未连接');
    try {
      const context = this.getAbilityContext();
      this.serverUrl = getServerUrl(context);
      const credentials = await loadCredentials(context);
      if (!this.isCurrentLoadState(generation)) {
        return;
      }
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
      if (!this.isCurrentLoadState(generation)) {
        return;
      }
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
      if (this.isCurrentLoadState(generation)) {
        this.isLoadingState = false;
      }
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
        this.restartRealtimeSync();
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
        this.restartRealtimeSync();
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
      const previousSessions = this.sessions;
      const selectedSessionId = this.selectedSessionId;
      const snapshot: ControlPlaneSnapshot = await loadControlPlaneSnapshot(this.getAbilityContext(), serverUrl);
      if (!this.isCurrentSync(generation)) {
        return;
      }
      this.machines = snapshot.machines;
      this.sessions = snapshot.sessions;
      this.dropSelectedSessionIfMissing();
      this.syncStatus = snapshot.decodeWarningCount > 0 ? `同步完成，${snapshot.decodeWarningCount} 个字段解密失败` : '同步完成';
      if (this.shouldRefreshSelectedSessionMessagesAfterSync(previousSessions, snapshot.sessions, selectedSessionId)) {
        this.messageStatus = '会话状态已更新，正在读取消息...';
        this.refreshSelectedSessionMessages();
      }
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
    this.closeSessionDetail();
    this.syncStatus = status;
    this.isSyncLoading = false;
  }

  private isCurrentSync(generation: number): boolean {
    return generation === this.syncGeneration && this.isAuthenticated;
  }

  private isCurrentLoadState(generation: number): boolean {
    return this.isPageActive && generation === this.loadStateGeneration;
  }

  private startRealtimeSync(credentials: Credentials): void {
    if (!this.isPageActive || !this.isAuthenticated) {
      return;
    }
    const url = this.serverUrl.trim();
    const error = validateServerUrl(url);
    if (error) {
      this.realtimeStatus = `实时同步未连接：${error}`;
      return;
    }
    const generation = this.realtimeGeneration + 1;
    this.realtimeGeneration = generation;

    this.realtimeSync.start(
      url,
      credentials,
      (status: string, message: string): void => {
        if (!this.isCurrentRealtime(generation)) {
          return;
        }
        this.realtimeStatus = message;
      },
      (): void => {
        if (!this.isCurrentRealtime(generation)) {
          return;
        }
        this.refreshControlPlaneData();
        this.refreshSelectedSessionMessages();
      },
      (): void => {
        if (!this.isCurrentRealtime(generation)) {
          return;
        }
        this.syncStatus = '收到实时更新，正在同步...';
        this.refreshControlPlaneData();
        if (this.selectedSessionId.length > 0) {
          this.messageStatus = '收到实时更新，正在读取消息...';
          this.refreshSelectedSessionMessages();
        }
      },
      (event: MachineActivityEvent): void => {
        if (!this.isCurrentRealtime(generation)) {
          return;
        }
        this.applyMachineActivity(event);
      },
      (event: SessionActivityEvent): void => {
        if (!this.isCurrentRealtime(generation)) {
          return;
        }
        this.applySessionActivity(event);
      },
    );
  }

  private stopRealtimeSync(status: string): void {
    this.realtimeGeneration += 1;
    this.realtimeSync.stop();
    this.realtimeStatus = status;
  }

  private restartRealtimeSync(): void {
    this.realtimeGeneration += 1;
    const generation = this.realtimeGeneration;
    this.realtimeSync.stop();
    this.realtimeStatus = '实时同步正在重连...';
    this.restartRealtimeSyncAsync(generation);
  }

  private async restartRealtimeSyncAsync(generation: number): Promise<void> {
    try {
      const credentials = await loadCredentials(this.getAbilityContext());
      if (!this.isCurrentRealtime(generation)) {
        return;
      }
      if (credentials) {
        this.startRealtimeSync(credentials);
      } else {
        this.stopRealtimeSync('实时同步未连接');
      }
    } catch (error) {
      console.error(`实时同步重连失败：${error}`);
      if (this.isCurrentRealtime(generation)) {
        this.realtimeStatus = '实时同步重连失败';
      }
    }
  }

  private isCurrentRealtime(generation: number): boolean {
    return this.isPageActive && this.isAuthenticated && generation === this.realtimeGeneration;
  }

  private applyMachineActivity(event: MachineActivityEvent): void {
    let found = false;
    const machines = this.machines.map((machine: HappyMachine): HappyMachine => {
      if (machine.id !== event.id) {
        return machine;
      }
      found = true;
      return {
        id: machine.id,
        seq: machine.seq,
        createdAt: machine.createdAt,
        updatedAt: machine.updatedAt,
        active: event.active,
        activeAt: event.activeAt,
        metadata: machine.metadata,
        metadataVersion: machine.metadataVersion,
        daemonState: machine.daemonState,
        daemonStateVersion: machine.daemonStateVersion,
        dataEncryptionKey: machine.dataEncryptionKey,
      };
    });
    if (!found) {
      this.syncStatus = '收到未知终端状态，正在同步...';
      this.refreshControlPlaneData();
      return;
    }
    this.machines = machines;
    this.syncStatus = '终端状态已实时更新';
  }

  private applySessionActivity(event: SessionActivityEvent): void {
    let found = false;
    const sessions = this.sessions.map((session: HappySession): HappySession => {
      if (session.id !== event.id) {
        return session;
      }
      found = true;
      return {
        id: session.id,
        seq: session.seq,
        createdAt: session.createdAt,
        updatedAt: session.updatedAt,
        active: event.active,
        activeAt: event.activeAt,
        thinking: event.thinking,
        thinkingAt: event.activeAt,
        metadata: session.metadata,
        metadataVersion: session.metadataVersion,
        agentState: session.agentState,
        agentStateVersion: session.agentStateVersion,
        dataEncryptionKey: session.dataEncryptionKey,
      };
    });
    if (!found) {
      this.syncStatus = '收到未知会话状态，正在同步...';
      this.refreshControlPlaneData();
      return;
    }
    this.sessions = sessions;
    this.syncStatus = event.thinking ? '会话正在思考' : '会话状态已实时更新';
  }

  private shouldRefreshSelectedSessionMessagesAfterSync(
    previousSessions: HappySession[],
    nextSessions: HappySession[],
    selectedSessionId: string,
  ): boolean {
    if (selectedSessionId.length === 0 || this.selectedSessionId !== selectedSessionId) {
      return false;
    }
    const previous = this.findSessionInList(previousSessions, selectedSessionId);
    const next = this.findSessionInList(nextSessions, selectedSessionId);
    if (!previous || !next) {
      return false;
    }
    return previous.agentStateVersion !== next.agentStateVersion;
  }

  private findSessionInList(sessions: HappySession[], sessionId: string): HappySession | null {
    for (const session of sessions) {
      if (session.id === sessionId) {
        return session;
      }
    }
    return null;
  }

  private openSessionDetail(sessionId: string): void {
    this.selectedSessionId = sessionId;
    this.messages = [];
    this.permissions = [];
    this.messageStatus = '正在读取消息...';
    this.messageDraft = '';
    this.messageSendStatus = '';
    this.permissionActionStatus = '';
    this.activePermissionActionId = '';
    this.isMessageSending = false;
    this.isPermissionSubmitting = false;
    this.messageSendGeneration += 1;
    this.pendingMessages = [];
    this.clearRetryMessage();
    this.refreshSelectedSessionMessages();
  }

  private closeSessionDetail(): void {
    this.messageGeneration += 1;
    this.messageSendGeneration += 1;
    this.hasQueuedMessageRefresh = false;
    this.selectedSessionId = '';
    this.messages = [];
    this.permissions = [];
    this.messageStatus = '';
    this.messageDraft = '';
    this.messageSendStatus = '';
    this.permissionActionStatus = '';
    this.activePermissionActionId = '';
    this.isMessagesLoading = false;
    this.isMessageSending = false;
    this.isPermissionSubmitting = false;
    this.pendingMessages = [];
    this.clearRetryMessage();
  }

  private refreshSelectedSessionMessages(): void {
    if (!this.isAuthenticated || this.selectedSessionId.length === 0) {
      return;
    }
    if (this.isMessagesLoading) {
      this.hasQueuedMessageRefresh = true;
      return;
    }
    const session = this.getSelectedSession();
    if (!session) {
      this.messages = [];
      this.permissions = [];
      this.messageStatus = '该会话已不存在';
      return;
    }
    const generation = this.messageGeneration + 1;
    this.messageGeneration = generation;
    this.hasQueuedMessageRefresh = false;
    this.isMessagesLoading = true;
    this.messageStatus = '正在读取消息...';
    this.refreshSelectedSessionMessagesAsync(generation, this.serverUrl, session);
  }

  private async refreshSelectedSessionMessagesAsync(generation: number, serverUrl: string, session: HappySession): Promise<void> {
    try {
      const snapshot: SessionMessagesSnapshot = await loadSessionMessages(this.getAbilityContext(), serverUrl, session);
      if (!this.isCurrentMessageLoad(generation, session.id)) {
        return;
      }
      this.messages = this.mergePendingMessages(snapshot.messages);
      this.permissions = snapshot.permissions;
      this.messageStatus = snapshot.decodeWarningCount > 0
        ? `消息读取完成，${snapshot.decodeWarningCount} 条解密失败`
        : `消息读取完成，${snapshot.messages.length} 条`;
    } catch (error) {
      if (!this.isCurrentMessageLoad(generation, session.id)) {
        return;
      }
      console.error(`读取会话消息失败：${error}`);
      this.messageStatus = `消息读取失败：${this.toUserError(error, '请检查服务器、网络和登录状态')}`;
    } finally {
      if (this.isCurrentMessageLoad(generation, session.id)) {
        this.isMessagesLoading = false;
        if (this.hasQueuedMessageRefresh && this.isAuthenticated && this.selectedSessionId.length > 0) {
          this.refreshSelectedSessionMessages();
        }
      }
    }
  }

  private isCurrentMessageLoad(generation: number, sessionId: string): boolean {
    return this.isPageActive && this.isAuthenticated && generation === this.messageGeneration && this.selectedSessionId === sessionId;
  }

  private canSendMessage(): boolean {
    return this.isAuthenticated
      && !this.isMessageSending
      && this.selectedSessionId.length > 0
      && this.messageDraft.trim().length > 0;
  }

  private sendSelectedSessionMessage(): void {
    if (!this.canSendMessage()) {
      if (this.messageDraft.trim().length === 0) {
        this.messageSendStatus = '请输入消息内容';
      }
      return;
    }
    const session = this.getSelectedSession();
    if (!session) {
      this.messageSendStatus = '该会话已不存在';
      return;
    }

    const text = this.messageDraft.trim();
    const retryLocalId = this.retryMessageText === text ? this.retryMessageLocalId : '';
    const localId = retryLocalId.length > 0 ? retryLocalId : createLocalMessageId();
    const createdAt = retryLocalId.length > 0 ? this.retryMessageCreatedAt : Date.now();
    this.clearRetryMessage();
    const optimistic = createOptimisticUserMessage(localId, text, createdAt);
    const messages = this.messages.slice();
    messages.push(optimistic);
    this.messages = messages;
    this.addPendingMessage(optimistic);
    this.messageDraft = '';
    this.messageSendStatus = '正在发送...';
    this.isMessageSending = true;
    const sendGeneration = this.messageSendGeneration + 1;
    this.messageSendGeneration = sendGeneration;
    this.sendSelectedSessionMessageAsync(sendGeneration, session, text, localId, createdAt);
  }

  private async sendSelectedSessionMessageAsync(
    sendGeneration: number,
    session: HappySession,
    text: string,
    localId: string,
    createdAt: number,
  ): Promise<void> {
    try {
      const result: SendSessionMessageResult = await sendSessionTextMessage(
        this.getAbilityContext(),
        this.serverUrl,
        session,
        text,
        localId,
        createdAt,
      );
      if (!this.isCurrentMessageSend(sendGeneration, session.id)) {
        return;
      }
      this.messageSendStatus = result.responseMessages.length > 0 ? '发送成功，正在同步...' : '发送成功';
      this.refreshSelectedSessionMessages();
    } catch (error) {
      if (!this.isCurrentMessageSend(sendGeneration, session.id)) {
        return;
      }
      console.error(`发送会话消息失败：${error}`);
      this.removePendingMessage(localId);
      this.removeMessageByLocalId(localId);
      this.retryMessageLocalId = localId;
      this.retryMessageText = text;
      this.retryMessageCreatedAt = createdAt;
      if (this.messageDraft.trim().length === 0) {
        this.messageDraft = text;
      }
      this.messageSendStatus = `发送失败：${this.toUserError(error, '请检查服务器、网络和登录状态')}`;
    } finally {
      if (this.isCurrentMessageSend(sendGeneration, session.id)) {
        this.isMessageSending = false;
      }
    }
  }

  private isCurrentMessageSend(sendGeneration: number, sessionId: string): boolean {
    return this.isPageActive
      && this.isAuthenticated
      && this.selectedSessionId === sessionId
      && this.messageSendGeneration === sendGeneration;
  }

  private addPendingMessage(message: HappyMessage): void {
    const pending = this.pendingMessages.slice();
    pending.push(message);
    this.pendingMessages = pending;
  }

  private clearRetryMessage(): void {
    this.retryMessageLocalId = '';
    this.retryMessageText = '';
    this.retryMessageCreatedAt = 0;
  }

  private removePendingMessage(localId: string): void {
    const pending: HappyMessage[] = [];
    for (const message of this.pendingMessages) {
      if (message.localId !== localId && message.id !== localId) {
        pending.push(message);
      }
    }
    this.pendingMessages = pending;
  }

  private removeMessageByLocalId(localId: string): void {
    const messages: HappyMessage[] = [];
    for (const message of this.messages) {
      if (message.localId !== localId && message.id !== localId) {
        messages.push(message);
      }
    }
    this.messages = messages;
  }

  private mergePendingMessages(serverMessages: HappyMessage[]): HappyMessage[] {
    if (this.pendingMessages.length === 0) {
      return serverMessages;
    }
    const merged = serverMessages.slice();
    const stillPending: HappyMessage[] = [];
    for (const pending of this.pendingMessages) {
      if (!this.hasMessageIdentity(serverMessages, pending)) {
        merged.push(pending);
        stillPending.push(pending);
      }
    }
    this.pendingMessages = stillPending;
    return merged;
  }

  private hasMessageIdentity(messages: HappyMessage[], target: HappyMessage): boolean {
    for (const message of messages) {
      if (target.localId && message.localId === target.localId) {
        return true;
      }
      if (message.id === target.id) {
        return true;
      }
    }
    return false;
  }

  private getPendingPermissionCount(): number {
    let count = 0;
    for (const permission of this.permissions) {
      if (permission.status === 'pending') {
        count += 1;
      }
    }
    return count;
  }

  private getPermissionStatusLabel(permission: HappyPermission): string {
    if (permission.status === 'pending') {
      return this.activePermissionActionId === permission.id && this.isPermissionSubmitting ? '提交中' : '待审批';
    }
    if (permission.status === 'approved') {
      if (permission.decision === 'approved_for_session') {
        return '本会话已允许';
      }
      return '已允许';
    }
    if (permission.status === 'denied') {
      return permission.decision === 'abort' ? '已停止' : '已拒绝';
    }
    if (permission.status === 'canceled') {
      return '已取消';
    }
    return permission.status;
  }

  private getPermissionStatusColor(permission: HappyPermission): string {
    if (permission.status === 'pending') {
      return '#B06000';
    }
    if (permission.status === 'approved') {
      return '#137333';
    }
    if (permission.status === 'denied' || permission.status === 'canceled') {
      return '#A50E0E';
    }
    return '#5F6368';
  }

  private getAllowForSessionLabel(permission: HappyPermission): string {
    return this.usesDecisionPermission(permission) ? '本会话允许' : '本工具允许';
  }

  private getDenyPermissionLabel(permission: HappyPermission): string {
    return this.usesDecisionPermission(permission) ? '停止并说明' : '拒绝';
  }

  private shouldShowAllowForSession(permission: HappyPermission): boolean {
    return this.usesDecisionPermission(permission) || (!this.isClaudeEditPermission(permission) && !this.isClaudeExitPlanPermission(permission));
  }

  private shouldShowClaudeModeActions(permission: HappyPermission): boolean {
    return this.shouldShowAllowAllEdits(permission) || this.shouldShowAllowEverything(permission);
  }

  private shouldShowAllowAllEdits(permission: HappyPermission): boolean {
    return this.isClaudePermission() && (this.isClaudeEditPermission(permission) || this.isClaudeExitPlanPermission(permission));
  }

  private shouldShowAllowEverything(permission: HappyPermission): boolean {
    return this.isClaudePermission() && this.isClaudeExitPlanPermission(permission);
  }

  private usesDecisionPermission(permission: HappyPermission): boolean {
    return !this.isClaudePermission() || permission.toolName.startsWith('Codex');
  }

  private isClaudePermission(): boolean {
    const session = this.getSelectedSession();
    const flavor = session?.metadata?.flavor;
    return !flavor || flavor === 'claude';
  }

  private isClaudeEditPermission(permission: HappyPermission): boolean {
    return permission.toolName === 'Edit'
      || permission.toolName === 'MultiEdit'
      || permission.toolName === 'Write'
      || permission.toolName === 'NotebookEdit';
  }

  private isClaudeExitPlanPermission(permission: HappyPermission): boolean {
    return permission.toolName === 'exit_plan_mode' || permission.toolName === 'ExitPlanMode';
  }

  private canSubmitPermission(permission: HappyPermission): boolean {
    return this.isAuthenticated
      && permission.status === 'pending'
      && !this.isPermissionSubmitting
      && this.selectedSessionId.length > 0;
  }

  private submitPermissionAction(permission: HappyPermission, action: PermissionAction): void {
    if (!this.canSubmitPermission(permission)) {
      return;
    }
    const session = this.getSelectedSession();
    if (!session) {
      this.permissionActionStatus = '该会话已不存在';
      return;
    }
    this.isPermissionSubmitting = true;
    this.activePermissionActionId = permission.id;
    this.permissionActionStatus = '正在提交审批...';
    this.submitPermissionActionAsync(session, permission, action);
  }

  private async submitPermissionActionAsync(session: HappySession, permission: HappyPermission, action: PermissionAction): Promise<void> {
    try {
      await respondToSessionPermission(
        this.getAbilityContext(),
        this.serverUrl,
        session,
        permission,
        action,
      );
      if (this.selectedSessionId !== session.id || this.activePermissionActionId !== permission.id) {
        return;
      }
      this.applyPermissionModeFromAction(session.id, action);
      this.permissionActionStatus = '审批已提交，正在同步...';
      this.refreshSelectedSessionMessages();
      this.refreshControlPlaneData();
    } catch (error) {
      if (this.selectedSessionId !== session.id || this.activePermissionActionId !== permission.id) {
        return;
      }
      console.error(`提交工具审批失败：${error}`);
      this.permissionActionStatus = `提交失败：${this.toUserError(error, '请检查实时连接、终端状态和登录状态')}`;
    } finally {
      if (this.selectedSessionId === session.id && this.activePermissionActionId === permission.id) {
        this.isPermissionSubmitting = false;
        this.activePermissionActionId = '';
      }
    }
  }

  private applyPermissionModeFromAction(sessionId: string, action: PermissionAction): void {
    let mode = '';
    if (action === 'allowAllEdits') {
      mode = 'acceptEdits';
    } else if (action === 'allowEverything') {
      mode = 'bypassPermissions';
    }
    if (mode.length === 0) {
      return;
    }
    const sessions = this.sessions.map((session: HappySession): HappySession => {
      if (session.id !== sessionId) {
        return session;
      }
      return {
        id: session.id,
        seq: session.seq,
        createdAt: session.createdAt,
        updatedAt: session.updatedAt,
        active: session.active,
        activeAt: session.activeAt,
        thinking: session.thinking,
        thinkingAt: session.thinkingAt,
        metadata: session.metadata,
        metadataVersion: session.metadataVersion,
        agentState: session.agentState,
        agentStateVersion: session.agentStateVersion,
        dataEncryptionKey: session.dataEncryptionKey,
        permissionMode: mode,
        modelMode: session.modelMode ?? null,
      };
    });
    this.sessions = sessions;
  }

  private getSelectedSession(): HappySession | null {
    for (let index = 0; index < this.sessions.length; index += 1) {
      if (this.sessions[index].id === this.selectedSessionId) {
        return this.sessions[index];
      }
    }
    return null;
  }

  private dropSelectedSessionIfMissing(): void {
    if (this.selectedSessionId.length === 0) {
      return;
    }
    if (!this.getSelectedSession()) {
      this.closeSessionDetail();
      this.syncStatus = '当前会话已删除，已返回会话列表';
    }
  }

  private getSelectedSessionTitle(): string {
    const session = this.getSelectedSession();
    return session ? getSessionTitle(session) : '会话详情';
  }

  private getSelectedSessionSubtitle(): string {
    const session = this.getSelectedSession();
    return session ? getSessionSubtitle(session) : '会话已不存在';
  }

  private getMessageBackgroundColor(message: HappyMessage): string {
    if (message.role === 'user') {
      return '#E8F0FE';
    }
    if (message.kind === 'tool-call' || message.kind === 'tool-result') {
      return '#F1F3F4';
    }
    if (message.kind === 'thinking') {
      return '#FFF7E0';
    }
    return '#F7F8FA';
  }

  private getMessageTextColor(message: HappyMessage): string {
    if (message.isError) {
      return '#B3261E';
    }
    return '#202124';
  }

  private getMessageMetaColor(message: HappyMessage): string {
    if (message.role === 'user') {
      return '#0B57D0';
    }
    if (message.isError) {
      return '#B3261E';
    }
    return '#5F6368';
  }

  private markAuthenticated(credentials: Credentials, status: string): void {
    this.isAuthenticated = true;
    this.hasStateLoadError = false;
    this.accountStatus = `已登录：${maskToken(credentials.token)}`;
    this.status = status;
    this.startRealtimeSync(credentials);
  }

  private markUnauthenticated(status: string): void {
    this.isAuthenticated = false;
    this.hasStateLoadError = false;
    this.accountStatus = '未登录';
    this.status = status;
    this.stopRealtimeSync('实时同步未连接');
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
    if (this.selectedSessionId.length > 0) {
      return '会话';
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
    if (this.selectedSessionId.length > 0) {
      return this.getSelectedSessionTitle();
    }
    return this.isAuthenticated ? 'Happy 鸿蒙客户端' : '请先完成账号设置';
  }

  private getAbilityContext(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }
}
