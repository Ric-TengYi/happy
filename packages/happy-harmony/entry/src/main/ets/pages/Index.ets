import { common } from '@kit.AbilityKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
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
  MachineMetadata,
  MachineAvailability,
  SessionMetadata,
  getControlPlaneSummary,
  getMachineSubtitle,
  getMachineTitle,
  getSessionSubtitle,
  getSessionTitle,
  isSessionArchived,
  loadControlPlaneSnapshot,
} from '../services/HappySync';
import {
  HappyRealtimeSync,
  MachineActivityEvent,
  SessionActivityEvent,
} from '../services/HappyRealtimeSync';
import {
  getWorkspacePath,
  setWorkspacePath,
} from '../services/HappyWorkspace';
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
import {
  PermissionAction,
  CodexThreadListResult,
  CodexThreadSummary,
  DirectoryEntrySummary,
  DirectoryListResult,
  MachineDeleteResult,
  MachineRenameResult,
  SessionArchiveResult,
  SessionRenameResult,
  SpawnMachineSessionResult,
  StopMachineDaemonResult,
  archiveSession,
  attachCodexThread,
  deleteMachine,
  listCodexThreads,
  listMachineDirectories,
  renameMachine,
  renameSession,
  respondToSessionPermission,
  spawnMachineSession,
  stopMachineDaemon,
} from '../services/HappySessionRpc';

const TAB_INBOX: string = 'inbox';
const TAB_TERMINAL: string = 'terminal';
const TAB_SETTINGS: string = 'settings';
const SCAN_CANCEL_CODE: number = scanCore.ScanErrorCode.SCAN_SERVICE_CANCELED;
const MACHINE_DELETE_CONFIRM_MESSAGE: string = '再次点击确认删除设备（8 秒内有效）';
const DIRECTORY_PICKER_NEW_SESSION: string = 'new-session';
const DIRECTORY_PICKER_WORKSPACE: string = 'workspace';

interface SessionModeOption {
  key: string;
  label: string;
}

interface DetailRow {
  label: string;
  value: string;
  tone?: string;
  monospace?: boolean;
}

const CLAUDE_PERMISSION_OPTIONS: SessionModeOption[] = [
  { key: 'default', label: '默认' },
  { key: 'plan', label: '计划模式' },
  { key: 'acceptEdits', label: '接受编辑' },
  { key: 'bypassPermissions', label: '全部允许' },
];

const CODEX_PERMISSION_OPTIONS: SessionModeOption[] = [
  { key: 'default', label: 'CLI 设置' },
  { key: 'read-only', label: '只读' },
  { key: 'safe-yolo', label: '安全自动' },
  { key: 'yolo', label: '全部允许' },
];

const GEMINI_PERMISSION_OPTIONS: SessionModeOption[] = [
  { key: 'default', label: '默认' },
  { key: 'read-only', label: '只读' },
  { key: 'safe-yolo', label: '安全自动' },
  { key: 'yolo', label: '全部允许' },
];

const CODEX_MODEL_OPTIONS: SessionModeOption[] = [
  { key: 'default', label: '默认模型' },
  { key: 'gpt-5.5', label: 'gpt-5.5' },
  { key: 'gpt-5.4', label: 'gpt-5.4' },
  { key: 'gpt-5.3-codex', label: 'gpt-5.3-codex' },
  { key: 'gpt-5.2-codex', label: 'gpt-5.2-codex' },
  { key: 'gpt-5.1-codex-max', label: 'gpt-5.1-codex-max' },
  { key: 'gpt-5.2', label: 'gpt-5.2' },
  { key: 'gpt-5.1-codex-mini', label: 'gpt-5.1-codex-mini' },
];

const CLAUDE_MODEL_OPTIONS: SessionModeOption[] = [
  { key: 'default', label: '默认模型' },
  { key: 'opus', label: 'opus 4.7' },
  { key: 'sonnet', label: 'sonnet 4.6' },
  { key: 'haiku', label: 'haiku 4.5' },
];

const DEFAULT_MODEL_OPTIONS: SessionModeOption[] = [
  { key: 'default', label: '默认模型' },
];

const NEW_SESSION_AGENT_OPTIONS: SessionModeOption[] = [
  { key: 'claude', label: 'claude code' },
  { key: 'codex', label: 'codex' },
  { key: 'openclaw', label: 'openclaw' },
  { key: 'gemini', label: 'gemini' },
];

const EFFORT_OPTIONS: SessionModeOption[] = [
  { key: 'low', label: '低' },
  { key: 'medium', label: '中' },
  { key: 'high', label: '高' },
  { key: 'xhigh', label: '超高' },
];

@Entry
@Component
struct Index {
  @State private activeTab: string = TAB_TERMINAL;
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
  @State private showSessionSettingsPanel: boolean = false;
  @State private showNewSessionPanel: boolean = false;
  @State private selectedMachineId: string = '';
  @State private selectedNewSessionAgent: string = '';
  @State private newSessionPath: string = '';
  @State private newSessionStatus: string = '';
  @State private newSessionApprovalDirectory: string = '';
  @State private newSessionApprovalMachineId: string = '';
  @State private isSpawningSession: boolean = false;
  @State private showDirectoryPicker: boolean = false;
  @State private directoryPickerPurpose: string = '';
  @State private directoryPickerMachineId: string = '';
  @State private directoryPickerPath: string = '';
  @State private directoryPickerParentPath: string = '';
  @State private directoryPickerEntries: DirectoryEntrySummary[] = [];
  @State private directoryPickerStatus: string = '';
  @State private isDirectoryPickerLoading: boolean = false;
  @State private directoryPickerShowHidden: boolean = false;
  @State private workspacePath: string = '';
  @State private workspaceStatus: string = '';
  @State private workspaceMachineId: string = '';
  @State private isSavingWorkspace: boolean = false;
  @State private editingMachineId: string = '';
  @State private machineRenameDraft: string = '';
  @State private machineRenameStatus: string = '';
  @State private isRenamingMachine: boolean = false;
  @State private isStoppingMachineDaemon: boolean = false;
  @State private machineDaemonActionStatus: string = '';
  @State private machineStopConfirmMachineId: string = '';
  @State private isDeletingMachine: boolean = false;
  @State private machineDeleteStatus: string = '';
  @State private machineDeleteConfirmMachineId: string = '';
  @State private machineDetailShowAllPaths: boolean = false;
  @State private codexThreads: CodexThreadSummary[] = [];
  @State private codexThreadStatus: string = '';
  @State private codexThreadMachineId: string = '';
  @State private codexThreadCwd: string = '';
  @State private isLoadingCodexThreads: boolean = false;
  @State private attachingCodexThreadId: string = '';
  @State private editingSessionId: string = '';
  @State private sessionRenameDraft: string = '';
  @State private sessionRenameStatus: string = '';
  @State private isRenamingSession: boolean = false;
  @State private archivingSessionId: string = '';
  @State private sessionArchiveStatus: string = '';
  @State private selectedMachineDetailId: string = '';
  @State private hasQueuedMessageRefresh: boolean = false;
  @State private messageGeneration: number = 0;
  @State private showJumpToLatestButton: boolean = false;
  private realtimeSync: HappyRealtimeSync = new HappyRealtimeSync();
  private messageScroller: Scroller = new Scroller();
  private isPageActive: boolean = false;
  private loadStateGeneration: number = 0;
  private realtimeGeneration: number = 0;
  private messageSendGeneration: number = 0;
  private directoryPickerGeneration: number = 0;
  private codexThreadGeneration: number = 0;
  private pendingMessages: HappyMessage[] = [];
  private retryMessageLocalId: string = '';
  private retryMessageText: string = '';
  private retryMessageCreatedAt: number = 0;
  private pendingOpenSessionId: string = '';
  private pendingDeletedMachineIds: string[] = [];
  private pendingArchivedSessionIds: string[] = [];
  private machineStopConfirmToken: number = 0;
  private machineDeleteConfirmToken: number = 0;
  private hasMessageScrollOffset: boolean = false;
  private lastMessageScrollOffsetY: number = 0;
  private messageScrollAwayDistance: number = 0;

  aboutToAppear(): void {
    this.isPageActive = true;
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
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
    this.isSpawningSession = false;
    this.isRenamingMachine = false;
    this.isStoppingMachineDaemon = false;
    this.machineDaemonActionStatus = '';
    this.invalidateMachineStopConfirmation();
    this.isDeletingMachine = false;
    this.invalidateMachineDeleteConfirmation();
    this.machineDeleteStatus = '';
    this.resetCodexThreadState();
    this.isRenamingSession = false;
    this.editingMachineId = '';
    this.editingSessionId = '';
    this.selectedMachineDetailId = '';
    this.machineDetailShowAllPaths = false;
    this.activePermissionActionId = '';
    this.pendingMessages = [];
    this.clearRetryMessage();
    this.resetMessageScrollState();
    this.stopRealtimeSync('实时同步未连接');
  }

  build() {
    if (this.selectedSessionId.length > 0) {
      this.SessionDetailScreen()
    } else if (this.selectedMachineDetailId.length > 0) {
      this.MachineDetailScreen()
    } else {
      Column() {
        this.AppHeader()

        Scroll() {
          Column({ space: 12 }) {
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
          .padding({ left: 16, right: 16, top: 8, bottom: 12 })
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
  }

  @Builder
  private AppHeader() {
    Row() {
      if (this.shouldShowControlPlaneRefresh()) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(17)
            .fontColor([this.isSyncLoading ? '#9AA0A6' : '#202124'])
        }
          .width(32)
          .height(32)
          .backgroundColor(this.isSyncLoading ? '#EEF3F8' : '#FFFFFF')
          .borderRadius(8)
          .enabled(!this.isSyncLoading && this.isAuthenticated)
          .onClick(() => {
            this.refreshControlPlaneData();
          })
      } else {
        Blank()
          .width(32)
          .height(32)
      }

      Column({ space: 3 }) {
        Text(this.getHeaderTitle())
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#202124')
          .textAlign(TextAlign.Center)
          .width('100%')

        this.HeaderStatusBadge()
      }
      .alignItems(HorizontalAlign.Center)
      .layoutWeight(1)

      if (this.activeTab === TAB_SETTINGS) {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.storagebox'))
            .fontSize(18)
            .fontColor([this.showServerPanel ? '#0B57D0' : '#202124'])
        }
          .width(32)
          .height(32)
          .backgroundColor(this.showServerPanel ? '#E8F0FE' : '#FFFFFF')
          .borderRadius(8)
          .onClick(() => {
            this.showServerPanel = !this.showServerPanel;
          })
      } else if (this.activeTab === TAB_TERMINAL) {
        Button({ type: ButtonType.Normal }) {
          Text('+')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.showNewSessionPanel ? '#0B57D0' : '#202124')
        }
          .width(32)
          .height(32)
          .backgroundColor(this.showNewSessionPanel ? '#E8F0FE' : '#FFFFFF')
          .borderRadius(8)
          .enabled(this.isAuthenticated && !this.isSpawningSession)
          .onClick(() => {
            this.toggleNewSessionPanel();
          })
      } else {
        Blank()
          .width(32)
          .height(32)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 4 })
    .backgroundColor('#F7F8FA')
  }

  @Builder
  private HeaderStatusBadge() {
    Row({ space: 4 }) {
      Circle()
        .width(5)
        .height(5)
        .fill(this.getHeaderStatusColor())

      Text(this.getHeaderStatusLabel())
        .fontSize(9)
        .fontColor(this.getHeaderStatusColor())
    }
    .justifyContent(FlexAlign.Center)
    .padding({ left: 7, right: 7, top: 2, bottom: 2 })
    .backgroundColor(this.getHeaderStatusBackgroundColor())
    .borderRadius(9)
  }

  @Builder
  private InboxContent() {
    Column({ space: 14 }) {
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
        Column({ space: 10 }) {
          Text('暂无收件')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#202124')
            .width('100%')

          Text('好友请求、公告和提醒会显示在这里')
            .fontSize(14)
            .fontColor('#5F6368')
            .width('100%')
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
  private TerminalContent() {
    Column({ space: 10 }) {
      if (this.isLoadingState) {
        this.LoadingPanel()
      } else if (!this.isAuthenticated) {
        this.RequireAccountPanel()
      } else {
        if (this.showNewSessionPanel) {
          this.NewSessionPanel()
        }

        this.SessionListPanel()
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

      this.WorkspacePanel()
      this.TerminalAuthPanel()
      if (this.isAuthenticated) {
        this.SyncSummaryPanel()
        this.MachineListPanel()
      }
      this.AccountPanel()
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
  }

  @Builder
  private WorkspacePanel() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 2 }) {
          Text('工作空间')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#202124')
            .width('100%')

          Text(this.workspacePath.trim().length > 0 ? this.workspacePath : '未设置默认目录')
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

      if (this.getOnlineMachineCount() > 0) {
        Text('选择浏览终端')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#5F6368')
          .width('100%')

        ForEach(this.getOnlineMachines(), (machine: HappyMachine) => {
          Row({ space: 8 }) {
            Circle()
              .width(8)
              .height(8)
              .fill(this.getWorkspaceMachineId() === machine.id ? '#0B57D0' : '#137333')

            Text(getMachineTitle(machine))
              .fontSize(13)
              .fontColor(this.getWorkspaceMachineId() === machine.id ? '#0B57D0' : '#202124')
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .backgroundColor(this.getWorkspaceMachineId() === machine.id ? '#E8F0FE' : '#F7F8FA')
          .borderRadius(8)
          .onClick(() => {
            this.workspaceMachineId = machine.id;
            if (this.isDirectoryPickerOpenForMachine(machine, DIRECTORY_PICKER_WORKSPACE)) {
              this.closeDirectoryPicker();
            }
          })
        }, (machine: HappyMachine) => this.getMachineRowKey(machine))
      }

      Row({ space: 8 }) {
        TextInput({ text: this.workspacePath, placeholder: '默认工作目录，例如 ~/uniubi/work' })
          .height(44)
          .layoutWeight(1)
          .backgroundColor('#F7F8FA')
          .onChange((value: string) => {
            this.workspacePath = value;
            this.workspaceStatus = '';
            const machine = this.getWorkspacePickerMachine();
            if (machine && this.isDirectoryPickerOpenForMachine(machine, DIRECTORY_PICKER_WORKSPACE)) {
              this.closeDirectoryPicker();
            }
          })

        Button(this.isWorkspaceDirectoryPickerOpen() ? '收起' : '选择')
          .width(70)
          .height(44)
          .fontSize(13)
          .enabled(this.getWorkspacePickerMachine() !== null && !this.isDirectoryPickerLoading)
          .onClick(() => {
            const machine = this.getWorkspacePickerMachine();
            if (machine) {
              this.toggleWorkspaceDirectoryPicker(machine);
            }
          })
      }
      .width('100%')

      if (this.isWorkspaceDirectoryPickerOpen()) {
        this.DirectoryPickerPanel(this.getWorkspacePickerMachine() as HappyMachine)
      }

      Row({ space: 10 }) {
        Button(this.isSavingWorkspace ? '保存中' : '保存')
          .height(38)
          .layoutWeight(1)
          .enabled(!this.isSavingWorkspace)
          .onClick(() => {
            this.saveWorkspacePath();
          })

        Button('清除')
          .height(38)
          .layoutWeight(1)
          .enabled(!this.isSavingWorkspace && this.workspacePath.trim().length > 0)
          .onClick(() => {
            this.clearWorkspacePath();
          })
      }
      .width('100%')

      if (this.workspaceStatus.length > 0) {
        Text(this.workspaceStatus)
          .fontSize(12)
          .fontColor('#5F6368')
          .width('100%')
      }
    }
    .width('100%')
    .padding(18)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private SyncSummaryPanel() {
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
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private MachineListPanel() {
    Column({ space: 12 }) {
      Row() {
        Text('设备列表')
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
          Column({ space: 8 }) {
            this.MachineRow(machine)
            if (this.editingMachineId === machine.id) {
              this.MachineRenamePanel(machine)
            }
          }
          .width('100%')
        }, (machine: HappyMachine) => this.getMachineRowKey(machine))
      }
    }
    .width('100%')
    .padding(18)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private NewSessionPanel() {
    Column({ space: 12 }) {
      Row() {
        Text('新建会话')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#202124')
          .layoutWeight(1)

        Button('收起')
          .width(64)
          .height(34)
          .enabled(!this.isSpawningSession)
          .onClick(() => {
            this.showNewSessionPanel = false;
            this.closeDirectoryPicker();
          })
      }
      .width('100%')

      if (this.getOnlineMachineCount() === 0) {
        Text('暂无在线终端。请先在电脑上启动 happy daemon，或到设置中重新关联终端。')
          .fontSize(14)
          .fontColor('#5F6368')
          .width('100%')
      } else {
        Text('选择终端')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#202124')
          .width('100%')

        ForEach(this.getOnlineMachines(), (machine: HappyMachine) => {
          Row({ space: 8 }) {
            Circle()
              .width(10)
              .height(10)
              .fill(this.selectedMachineId === machine.id ? '#0B57D0' : '#137333')

            Column({ space: 2 }) {
              Text(getMachineTitle(machine))
                .fontSize(14)
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
          .padding({ left: 12, right: 12, top: 9, bottom: 9 })
          .backgroundColor(this.selectedMachineId === machine.id ? '#E8F0FE' : '#F7F8FA')
          .borderRadius(8)
          .onClick(() => {
            const machineChanged = this.selectedMachineId !== machine.id;
            if (this.selectedMachineId !== machine.id) {
              this.clearNewSessionDirectoryApproval();
              this.closeDirectoryPicker();
              this.resetCodexThreadState();
            }
            this.selectedMachineId = machine.id;
            if (machineChanged || this.newSessionPath.trim().length === 0) {
              this.newSessionPath = this.getMachineDefaultDirectory(machine);
            }
            this.ensureSelectedNewSessionAgent(machine);
            if (this.getSelectedNewSessionAgentKeyForMachine(machine) === 'codex') {
              this.refreshCodexThreads(machine);
            }
          })
        }, (machine: HappyMachine) => this.getMachineRowKey(machine))

        if (this.getNewSessionAgentOptions().length > 1) {
          Text('选择 Agent')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#202124')
            .width('100%')

          ForEach(this.getNewSessionAgentOptions(), (agent: SessionModeOption) => {
            Row({ space: 8 }) {
              Circle()
                .width(10)
                .height(10)
                .fill(this.getSelectedNewSessionAgentKey() === agent.key ? '#0B57D0' : '#DADCE0')

              Text(agent.label)
                .fontSize(14)
                .fontColor(this.getSelectedNewSessionAgentKey() === agent.key ? '#0B57D0' : '#202124')
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 9, bottom: 9 })
            .backgroundColor(this.getSelectedNewSessionAgentKey() === agent.key ? '#E8F0FE' : '#F7F8FA')
            .borderRadius(8)
            .onClick(() => {
              this.selectedNewSessionAgent = agent.key;
              if (agent.key === 'codex') {
                const machine = this.getSelectedNewSessionMachine();
                if (machine) {
                  this.refreshCodexThreads(machine);
                }
              } else {
                this.resetCodexThreadState();
              }
            })
          }, (agent: SessionModeOption) => agent.key)
        }
        if (this.getNewSessionAgentOptions().length === 0 && this.getSelectedNewSessionMachine() !== null) {
          Text('当前终端未检测到可用 Agent，请在电脑端安装或刷新终端状态。')
            .fontSize(13)
            .fontColor('#5F6368')
            .width('100%')
        }

        if (this.getSelectedNewSessionMachine() !== null) {
          this.NewSessionDirectoryInput(this.getSelectedNewSessionMachine() as HappyMachine)
        }
        if (this.shouldShowNewSessionCodexThreads(this.getSelectedNewSessionMachine())) {
          this.NewSessionCodexThreads(this.getSelectedNewSessionMachine() as HappyMachine)
        }

        Row({ space: 10 }) {
          Button(this.isSpawningSession ? '创建中' : this.newSessionApprovalDirectory.length > 0 ? '确认创建目录' : '创建会话')
            .height(44)
            .layoutWeight(1)
            .enabled(this.canSpawnSession())
            .onClick(() => {
              this.spawnNewSessionFromPanel();
            })

          Button('取消')
            .height(44)
            .layoutWeight(1)
            .enabled(!this.isSpawningSession)
            .onClick(() => {
              this.showNewSessionPanel = false;
              this.newSessionStatus = '';
              this.clearNewSessionDirectoryApproval();
              this.closeDirectoryPicker();
            })
        }
        .width('100%')
      }

      if (this.newSessionStatus.length > 0) {
        Text(this.newSessionStatus)
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

  @Builder
  private MachineRow(machine: HappyMachine) {
    Row({ space: 10 }) {
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
      .layoutWeight(1)
      .onClick(() => {
        this.openMachineDetail(machine.id);
      })

      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.pencil_line'))
          .fontSize(17)
          .fontColor(['#0B57D0'])
      }
        .width(34)
        .height(34)
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .onClick(() => {
          this.startMachineRename(machine);
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor('#F7F8FA')
    .borderRadius(8)
  }

  @Builder
  private MachineRenamePanel(machine: HappyMachine) {
    Column({ space: 8 }) {
      TextInput({ text: this.machineRenameDraft, placeholder: getMachineTitle(machine) })
        .width('100%')
        .height(42)
        .backgroundColor(Color.White)
        .onChange((value: string) => {
          this.machineRenameDraft = value;
        })

      Row({ space: 8 }) {
        Button(this.isRenamingMachine ? '保存中' : '保存')
          .height(36)
          .layoutWeight(1)
          .enabled(this.canSubmitMachineRename(machine))
          .onClick(() => {
            this.submitMachineRename(machine);
          })

        Button('取消')
          .height(36)
          .layoutWeight(1)
          .enabled(!this.isRenamingMachine)
          .onClick(() => {
            this.clearMachineRename();
          })
      }
      .width('100%')

      if (this.machineRenameStatus.length > 0) {
        Text(this.machineRenameStatus)
          .fontSize(12)
          .fontColor('#5F6368')
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor('#EEF3F8')
    .borderRadius(8)
  }

  @Builder
  private SessionListPanel() {
    Column({ space: 10 }) {
      Row() {
        Text('最近会话')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#202124')
          .layoutWeight(1)

        Text(`${this.getVisibleSessionCount()} 个`)
          .fontSize(12)
          .fontColor('#5F6368')
      }
      .width('100%')

      if (this.isSyncLoading && this.getVisibleSessionCount() === 0) {
        Text('正在读取会话列表...')
          .fontSize(14)
          .fontColor('#5F6368')
          .width('100%')
      } else if (this.getVisibleSessionCount() === 0) {
        Text('暂无会话。终端启动 Happy 会话后会显示在这里。')
          .fontSize(14)
          .fontColor('#5F6368')
          .width('100%')
      } else {
        ForEach(this.getVisibleSessions(), (session: HappySession) => {
          Column({ space: 8 }) {
            this.SessionRow(session)
            if (this.editingSessionId === session.id && this.selectedSessionId.length === 0) {
              this.SessionRenamePanel(session)
            }
          }
          .width('100%')
        }, (session: HappySession) => this.getSessionRowKey(session))
      }

      if (this.sessionArchiveStatus.length > 0) {
        Text(this.sessionArchiveStatus)
          .fontSize(12)
          .fontColor('#5F6368')
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private SessionRow(session: HappySession) {
    Row({ space: 10 }) {
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
      .layoutWeight(1)
      .onClick(() => {
        this.openSessionDetail(session.id);
      })

      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.pencil_line'))
          .fontSize(17)
          .fontColor(['#0B57D0'])
      }
        .width(34)
        .height(34)
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .onClick(() => {
          this.startSessionRename(session);
        })

      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.archivebox'))
          .fontSize(17)
          .fontColor([this.archivingSessionId === session.id ? '#9AA0A6' : '#5F6368'])
      }
        .width(34)
        .height(34)
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .enabled(this.canArchiveSession(session))
        .onClick(() => {
          this.submitSessionArchive(session);
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor('#F7F8FA')
    .borderRadius(8)
  }

  @Builder
  private SessionRenamePanel(session: HappySession) {
    Column({ space: 8 }) {
      TextInput({ text: this.sessionRenameDraft, placeholder: getSessionTitle(session) })
        .width('100%')
        .height(42)
        .backgroundColor(Color.White)
        .onChange((value: string) => {
          this.sessionRenameDraft = value;
        })

      Row({ space: 8 }) {
        Button(this.isRenamingSession ? '保存中' : '保存')
          .height(36)
          .layoutWeight(1)
          .enabled(this.canSubmitSessionRename(session))
          .onClick(() => {
            this.submitSessionRename(session);
          })

        Button('取消')
          .height(36)
          .layoutWeight(1)
          .enabled(!this.isRenamingSession)
          .onClick(() => {
            this.clearSessionRename();
          })
      }
      .width('100%')

      if (this.sessionRenameStatus.length > 0) {
        Text(this.sessionRenameStatus)
          .fontSize(12)
          .fontColor('#5F6368')
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor('#EEF3F8')
    .borderRadius(8)
  }

  @Builder
  private MachineDetailScreen() {
    Column() {
      Row() {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.arrow_left'))
            .fontSize(18)
            .fontColor(['#202124'])
        }
          .width(34)
          .height(34)
          .backgroundColor(Color.Transparent)
          .enabled(!this.isRenamingMachine)
          .onClick(() => {
            this.closeMachineDetail();
          })

        Column({ space: 2 }) {
          Text(this.getSelectedMachineTitle())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#202124')
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(this.getSelectedMachineSubtitle())
            .fontSize(11)
            .fontColor('#5F6368')
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1)

        if (this.getSelectedMachineDetail()) {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.pencil_line'))
              .fontSize(17)
              .fontColor(['#0B57D0'])
          }
            .width(34)
            .height(34)
            .backgroundColor(Color.Transparent)
            .enabled(!this.isRenamingMachine)
            .onClick(() => {
              const machine = this.getSelectedMachineDetail();
              if (machine) {
                this.startMachineRename(machine);
              }
            })
        } else {
          Blank()
            .width(34)
            .height(34)
        }
      }
      .width('100%')
      .height(44)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .backgroundColor('#F7F8FA')

      Scroll() {
        Column({ space: 12 }) {
          if (!this.getSelectedMachineDetail()) {
            Text('设备已不存在，请返回设备列表重新同步。')
              .fontSize(14)
              .fontColor('#5F6368')
              .width('100%')
          } else {
            if (this.editingMachineId === this.selectedMachineDetailId) {
              this.MachineRenamePanel(this.getSelectedMachineDetail() as HappyMachine)
            }

            this.MachineDetailSummary(this.getSelectedMachineDetail() as HappyMachine)
            this.MachineSessionLauncher(this.getSelectedMachineDetail() as HappyMachine)
            this.MachineDaemonSection(this.getSelectedMachineDetail() as HappyMachine)
            this.MachineDetailGroup('CLI 可用性', this.getMachineAvailabilityRows(this.getSelectedMachineDetail() as HappyMachine), '暂无 CLI 检测记录')
            this.MachineCodexThreads(this.getSelectedMachineDetail() as HappyMachine)
            this.MachineRecentSessions(this.getSelectedMachineDetail() as HappyMachine)
            this.MachineDetailGroup('终端', this.getMachineInfoRows(this.getSelectedMachineDetail() as HappyMachine), '暂无终端详情')
            this.MachineDangerZone(this.getSelectedMachineDetail() as HappyMachine)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      }
      .layoutWeight(1)
      .width('100%')
    }
    .height('100%')
    .width('100%')
    .backgroundColor('#F7F8FA')
  }

  @Builder
  private MachineDetailSummary(machine: HappyMachine) {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Circle()
          .width(10)
          .height(10)
          .fill(machine.active ? '#137333' : '#9AA0A6')

        Text(machine.active ? '在线' : '离线')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(machine.active ? '#137333' : '#5F6368')
          .layoutWeight(1)

        Text(`元数据 v${machine.metadataVersion}`)
          .fontSize(12)
          .fontColor('#5F6368')
      }
      .width('100%')

      Text(`最后在线：${this.formatRelativeTime(machine.activeAt)}`)
        .fontSize(13)
        .fontColor('#5F6368')
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private MachineSessionLauncher(machine: HappyMachine) {
    Column({ space: 10 }) {
      Text('在此终端新建会话')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#202124')
        .width('100%')

      if (!machine.active) {
        Text('终端离线，暂时不能创建新会话。请在电脑上启动 happy daemon 后刷新。')
          .fontSize(13)
          .fontColor('#5F6368')
          .width('100%')
      } else {
        if (this.getNewSessionAgentOptionsForMachine(machine).length > 1) {
          Text('选择 Agent')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#5F6368')
            .width('100%')

          ForEach(this.getNewSessionAgentOptionsForMachine(machine), (agent: SessionModeOption) => {
            Row({ space: 8 }) {
              Circle()
                .width(10)
                .height(10)
                .fill(this.getSelectedNewSessionAgentKeyForMachine(machine) === agent.key ? '#0B57D0' : '#DADCE0')

              Text(agent.label)
                .fontSize(14)
                .fontColor(this.getSelectedNewSessionAgentKeyForMachine(machine) === agent.key ? '#0B57D0' : '#202124')
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 9, bottom: 9 })
            .backgroundColor(this.getSelectedNewSessionAgentKeyForMachine(machine) === agent.key ? '#E8F0FE' : '#F7F8FA')
            .borderRadius(8)
            .onClick(() => {
              if (this.selectedMachineId !== machine.id) {
                this.resetCodexThreadState();
              }
              this.selectedMachineId = machine.id;
              this.selectedNewSessionAgent = agent.key;
              if (agent.key === 'codex') {
                this.refreshCodexThreads(machine);
              } else {
                this.resetCodexThreadState();
              }
            })
          }, (agent: SessionModeOption) => agent.key)
        }
        if (this.getNewSessionAgentOptionsForMachine(machine).length === 0) {
          Text('当前终端未检测到可用 Agent，请在电脑端安装或刷新终端状态。')
            .fontSize(13)
            .fontColor('#5F6368')
            .width('100%')
        }

        this.NewSessionDirectoryInput(machine)

        if (this.getMachineRecentPathCount(machine.id) > 0) {
          Row() {
            Text('最近目录')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#5F6368')
              .layoutWeight(1)

            Text(`${this.getMachineRecentPathCount(machine.id)} 个`)
              .fontSize(12)
              .fontColor('#5F6368')
          }
          .width('100%')

          ForEach(this.getMachineRecentPathsToShow(machine.id), (path: string) => {
            Text(this.formatMachinePathForDisplay(path, machine))
              .fontSize(13)
              .fontColor(this.isNewSessionPathSelected(path, machine) ? '#0B57D0' : '#202124')
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 12, right: 12, top: 9, bottom: 9 })
              .backgroundColor(this.isNewSessionPathSelected(path, machine) ? '#E8F0FE' : '#F7F8FA')
              .borderRadius(8)
              .onClick(() => {
                this.selectedMachineId = machine.id;
                this.newSessionPath = this.formatMachinePathForInput(path, machine);
                this.closeDirectoryPicker();
                this.clearNewSessionDirectoryApproval();
                if (this.getSelectedNewSessionAgentKeyForMachine(machine) === 'codex') {
                  this.refreshCodexThreads(machine);
                }
              })
          }, (path: string) => path)

          if (this.getMachineRecentPathCount(machine.id) > 5) {
            Button(this.machineDetailShowAllPaths ? '收起目录' : `显示全部 ${this.getMachineRecentPathCount(machine.id)} 个目录`)
              .width('100%')
              .height(36)
              .backgroundColor(Color.Transparent)
              .fontSize(13)
              .fontColor('#0B57D0')
              .onClick(() => {
                this.machineDetailShowAllPaths = !this.machineDetailShowAllPaths;
              })
          }
        }

        Button(this.isSpawningSession ? '创建中' : this.newSessionApprovalDirectory.length > 0 ? '确认创建目录' : '创建会话')
          .width('100%')
          .height(40)
          .enabled(this.canSpawnSessionForMachine(machine))
          .onClick(() => {
            this.selectedMachineId = machine.id;
            this.ensureSelectedNewSessionAgent(machine);
            this.spawnNewSessionFromPanel();
          })

        if (this.newSessionStatus.length > 0 && this.selectedMachineId === machine.id) {
          Text(this.newSessionStatus)
            .fontSize(13)
            .fontColor('#5F6368')
            .width('100%')
        }
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private NewSessionDirectoryInput(machine: HappyMachine) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.newSessionPath, placeholder: '工作目录，例如 ~/project' })
          .height(44)
          .layoutWeight(1)
          .backgroundColor('#F7F8FA')
          .onChange((value: string) => {
            this.selectedMachineId = machine.id;
            this.newSessionPath = value;
            if (this.isDirectoryPickerOpenForMachine(machine)) {
              this.closeDirectoryPicker();
            }
            if (this.newSessionApprovalDirectory.length > 0 && this.resolveMachineSpawnPath(value, machine) !== this.newSessionApprovalDirectory) {
              this.clearNewSessionDirectoryApproval();
            }
          })

        Button(this.isDirectoryPickerOpenForMachine(machine) ? '收起' : '选择')
          .width(70)
          .height(44)
          .fontSize(13)
          .enabled(machine.active && !this.isDirectoryPickerLoading)
          .onClick(() => {
            this.toggleDirectoryPicker(machine);
          })
      }
      .width('100%')

      if (this.isDirectoryPickerOpenForMachine(machine)) {
        this.DirectoryPickerPanel(machine)
      }
    }
    .width('100%')
  }

  @Builder
  private DirectoryPickerPanel(machine: HappyMachine) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.formatMachinePathForDisplay(this.directoryPickerPath, machine))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#202124')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Row({ space: 6 }) {
          Text('显示隐藏目录')
            .fontSize(12)
            .fontColor('#5F6368')

          Text(this.directoryPickerShowHidden ? '开' : '关')
            .fontSize(12)
            .fontColor(this.directoryPickerShowHidden ? '#0B57D0' : '#5F6368')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(this.directoryPickerShowHidden ? '#E8F0FE' : '#ECEFF3')
            .borderRadius(12)
        }
        .onClick(() => {
          this.toggleDirectoryPickerHidden(machine);
        })
      }
      .width('100%')

      Row({ space: 8 }) {
        if (this.directoryPickerParentPath.length > 0) {
          Button('上一级')
            .height(34)
            .fontSize(12)
            .backgroundColor(Color.Transparent)
            .fontColor('#0B57D0')
            .onClick(() => {
              this.openDirectoryPickerPath(machine, this.directoryPickerParentPath);
            })
        }

        Button('使用当前目录')
          .height(34)
          .fontSize(12)
          .layoutWeight(1)
          .onClick(() => {
            this.useDirectoryPickerCurrent(machine);
          })
      }
      .width('100%')

      if (this.directoryPickerStatus.length > 0) {
        Text(this.directoryPickerStatus)
          .fontSize(12)
          .fontColor('#5F6368')
          .width('100%')
      }

      if (!this.isDirectoryPickerLoading && this.directoryPickerEntries.length === 0) {
        Text(this.directoryPickerShowHidden ? '当前目录没有子目录' : '当前目录没有可见子目录')
          .fontSize(13)
          .fontColor('#5F6368')
          .width('100%')
          .padding({ top: 6, bottom: 6 })
      }

      if (!this.isDirectoryPickerLoading) {
        ForEach(this.directoryPickerEntries, (entry: DirectoryEntrySummary) => {
          Row({ space: 8 }) {
            Text(entry.hidden ? '隐藏' : '目录')
              .fontSize(11)
              .fontColor(entry.hidden ? '#5F6368' : '#137333')
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(entry.hidden ? '#ECEFF3' : '#E6F4EA')
              .borderRadius(10)

            Text(entry.name)
              .fontSize(14)
              .fontColor('#202124')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 9, bottom: 9 })
          .backgroundColor('#FFFFFF')
          .borderRadius(8)
          .onClick(() => {
            this.openDirectoryPickerPath(machine, entry.path);
          })
        }, (entry: DirectoryEntrySummary) => entry.path)
      }
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#F7F8FA')
    .borderRadius(8)
  }

  @Builder
  private MachineDaemonSection(machine: HappyMachine) {
    Column({ space: 10 }) {
      Text('守护进程')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#202124')
        .width('100%')

      ForEach(this.getMachineDaemonRows(machine), (row: DetailRow) => {
        Row({ space: 12 }) {
          Text(row.label)
            .fontSize(13)
            .fontColor('#5F6368')
            .width(108)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(row.value)
            .fontSize(13)
            .fontColor(row.tone && row.tone.length > 0 ? row.tone : '#202124')
            .fontFamily(row.monospace ? 'monospace' : 'HarmonyOS Sans')
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ top: 5, bottom: 5 })
      }, (row: DetailRow) => row.label)

      Button(this.getStopMachineDaemonButtonLabel(machine))
        .width('100%')
        .height(40)
        .backgroundColor(this.canStopMachineDaemon(machine) ? '#FFF4E5' : '#F1F3F4')
        .fontColor(this.canStopMachineDaemon(machine) ? '#B06000' : '#9AA0A6')
        .enabled(this.canStopMachineDaemon(machine))
        .onClick(() => {
          this.submitStopMachineDaemon(machine);
        })

      if (this.machineDaemonActionStatus.length > 0) {
        Text(this.machineDaemonActionStatus)
          .fontSize(13)
          .fontColor('#5F6368')
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private MachineDetailGroup(title: string, rows: DetailRow[], emptyText: string) {
    Column({ space: 10 }) {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#202124')
        .width('100%')

      if (rows.length === 0) {
        Text(emptyText)
          .fontSize(13)
          .fontColor('#5F6368')
          .width('100%')
      } else {
        ForEach(rows, (row: DetailRow) => {
          Row({ space: 12 }) {
            Text(row.label)
              .fontSize(13)
              .fontColor('#5F6368')
              .width(108)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            Text(row.value)
              .fontSize(13)
              .fontColor(row.tone && row.tone.length > 0 ? row.tone : '#202124')
              .fontFamily(row.monospace ? 'monospace' : 'HarmonyOS Sans')
              .layoutWeight(1)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ top: 5, bottom: 5 })
        }, (row: DetailRow) => row.label)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private MachineCodexThreads(machine: HappyMachine) {
    Column({ space: 10 }) {
      this.CodexThreadListContent(machine)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private NewSessionCodexThreads(machine: HappyMachine) {
    Column({ space: 10 }) {
      this.CodexThreadListContent(machine)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  private CodexThreadListContent(machine: HappyMachine) {
    Row() {
      Column({ space: 2 }) {
        Text('当前目录 Codex 会话')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#202124')
          .width('100%')

        Text(this.formatMachinePathForDisplay(this.getCodexThreadListCwd(machine), machine))
          .fontSize(12)
          .fontColor('#5F6368')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(16)
          .fontColor([this.canRefreshCodexThreads(machine) ? '#0B57D0' : '#9AA0A6'])
      }
        .width(32)
        .height(32)
        .backgroundColor(Color.Transparent)
        .enabled(this.canRefreshCodexThreads(machine))
        .onClick(() => {
          this.refreshCodexThreads(machine);
        })
    }
    .width('100%')

    if (!machine.active) {
      Text('终端离线，启动 happy daemon 后可读取本机 Codex 历史。')
        .fontSize(13)
        .fontColor('#5F6368')
        .width('100%')
    } else if (!this.isMachineCodexAvailable(machine)) {
      Text('未检测到 Codex CLI。')
        .fontSize(13)
        .fontColor('#5F6368')
        .width('100%')
    } else {
      if (this.isCodexThreadStateForCurrentPath(machine) && this.codexThreadStatus.length > 0) {
        Text(this.codexThreadStatus)
          .fontSize(13)
          .fontColor(this.codexThreadStatus.startsWith('失败') || this.codexThreadStatus.startsWith('接入失败') ? '#C5221F' : '#5F6368')
          .width('100%')
      }

      if (!this.hasCodexThreadsForCurrentPath(machine) && !this.isLoadingCodexThreads) {
        Text('暂无已加载的 Codex 会话，点击刷新读取当前目录记录。')
          .fontSize(13)
          .fontColor('#5F6368')
          .width('100%')
      } else {
        ForEach(this.getCodexThreadsForCurrentPath(machine), (thread: CodexThreadSummary) => {
          Row({ space: 10 }) {
            Column({ space: 3 }) {
              Text(this.getCodexThreadTitle(thread))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor('#202124')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')

              Text(this.getCodexThreadSubtitle(thread, machine))
                .fontSize(12)
                .fontColor('#5F6368')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Button(this.attachingCodexThreadId === thread.id ? '接入中' : '接入')
              .width(64)
              .height(32)
              .fontSize(12)
              .backgroundColor(this.canAttachCodexThread(machine, thread) ? '#E8F0FE' : '#F1F3F4')
              .fontColor(this.canAttachCodexThread(machine, thread) ? '#0B57D0' : '#9AA0A6')
              .enabled(this.canAttachCodexThread(machine, thread))
              .onClick(() => {
                this.attachCodexThreadFromList(machine, thread);
              })
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .backgroundColor('#F7F8FA')
          .borderRadius(8)
          .onClick(() => {
            this.attachCodexThreadFromList(machine, thread);
          })
        }, (thread: CodexThreadSummary) => thread.id)
      }
    }
  }

  @Builder
  private MachineDangerZone(machine: HappyMachine) {
    Column({ space: 10 }) {
      Text('危险区')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#202124')
        .width('100%')

      Text(this.getMachineDeleteWarning(machine))
        .fontSize(13)
        .fontColor('#5F6368')
        .width('100%')

      Button(this.getDeleteMachineButtonLabel(machine))
        .width('100%')
        .height(40)
        .backgroundColor(this.canDeleteMachine(machine) ? '#FCE8E6' : '#F1F3F4')
        .fontColor(this.canDeleteMachine(machine) ? '#C5221F' : '#9AA0A6')
        .enabled(this.canDeleteMachine(machine))
        .onClick(() => {
          this.submitDeleteMachine(machine);
        })

      if (this.machineDeleteStatus.length > 0) {
        Text(this.machineDeleteStatus)
          .fontSize(13)
          .fontColor(this.machineDeleteStatus.startsWith('删除失败') ? '#C5221F' : '#5F6368')
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private MachineRecentSessions(machine: HappyMachine) {
    Column({ space: 10 }) {
      Row() {
        Text('最近会话')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#202124')
          .layoutWeight(1)

        Text(`${this.getMachineRecentSessions(machine.id).length} 个`)
          .fontSize(12)
          .fontColor('#5F6368')
      }
      .width('100%')

      if (this.getMachineRecentSessions(machine.id).length === 0) {
        Text('暂无该终端的会话记录')
          .fontSize(13)
          .fontColor('#5F6368')
          .width('100%')
      } else {
        ForEach(this.getMachineRecentSessions(machine.id), (session: HappySession) => {
          Row({ space: 10 }) {
            Circle()
              .width(8)
              .height(8)
              .fill(session.active ? '#137333' : '#9AA0A6')

            Column({ space: 2 }) {
              Text(getSessionTitle(session))
                .fontSize(14)
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
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .backgroundColor('#F7F8FA')
          .borderRadius(8)
          .onClick(() => {
            this.openSessionDetail(session.id);
          })
        }, (session: HappySession) => this.getSessionRowKey(session))
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(8)
  }

  @Builder
  private SessionDetailScreen() {
    Column() {
      Row() {
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.arrow_left'))
            .fontSize(18)
            .fontColor(['#202124'])
        }
          .width(34)
          .height(34)
          .backgroundColor(Color.Transparent)
          .enabled(!this.isMessagesLoading)
          .onClick(() => {
            this.closeSessionDetail();
          })

        Column({ space: 2 }) {
          Text(this.getSelectedSessionTitle())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#202124')
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(this.getSelectedSessionSubtitle())
            .fontSize(11)
            .fontColor('#5F6368')
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1)

        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(18)
            .fontColor([this.isMessagesLoading ? '#9AA0A6' : '#202124'])
        }
          .width(34)
          .height(34)
          .backgroundColor(Color.Transparent)
          .enabled(!this.isMessagesLoading && this.isAuthenticated)
          .onClick(() => {
            this.refreshSelectedSessionMessages();
          })
      }
      .width('100%')
      .height(44)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .backgroundColor('#F7F8FA')

      Stack({ alignContent: Alignment.Bottom }) {
        Scroll(this.messageScroller) {
          Column({ space: 12 }) {
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
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        }
        .width('100%')
        .height('100%')
        .onDidScroll((_xOffset: number, _yOffset: number, _scrollState: ScrollState) => {
          this.handleMessageDidScroll();
        })
        .onReachEnd(() => {
          this.markMessagesAtLatest();
        })

        if (this.showJumpToLatestButton) {
          this.JumpToLatestButton()
        }
      }
      .layoutWeight(1)
      .width('100%')

      this.SessionComposer()
    }
    .height('100%')
    .width('100%')
    .backgroundColor('#F7F8FA')
  }

  @Builder
  private JumpToLatestButton() {
    Row() {
      Button({ type: ButtonType.Normal }) {
        SymbolGlyph($r('sys.symbol.arrow_down'))
          .fontSize(18)
          .fontColor(['#0B57D0'])
      }
        .width(38)
        .height(38)
        .borderRadius(19)
        .backgroundColor(Color.White)
        .borderWidth(1)
        .borderColor('#DADCE0')
        .onClick(() => {
          this.scrollMessagesToLatest(true);
        })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ bottom: 8 })
  }

  @Builder
  private SessionComposer() {
    Column({ space: 6 }) {
      if (this.showSessionSettingsPanel) {
        Scroll() {
          this.SessionSettingsPanel()
        }
        .width('100%')
        .height(156)
      }

      Row({ space: 6 }) {
        Text(this.getSelectedSessionActivityText())
          .fontSize(10)
          .fontColor('#5F6368')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.messageSendStatus.length > 0 ? this.messageSendStatus : ' ')
          .fontSize(10)
          .fontColor('#5F6368')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      Column({ space: 0 }) {
        TextArea({ text: this.messageDraft, placeholder: '输入消息' })
          .width('100%')
          .height(this.getComposerTextAreaHeight())
          .padding({ left: 12, right: 12, top: 6, bottom: 0 })
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .lineHeight(18)
          .maxLines(4)
          .onChange((value: string) => {
            this.messageDraft = value;
            if (this.retryMessageText.length > 0 && value.trim() !== this.retryMessageText) {
              this.clearRetryMessage();
            }
          })

        Row() {
          Button({ type: ButtonType.Normal }) {
            SymbolGlyph($r('sys.symbol.wrench_and_screwdriver'))
              .fontSize(17)
              .fontColor([this.showSessionSettingsPanel ? '#0B57D0' : '#5F6368'])
          }
            .width(32)
            .height(32)
            .borderRadius(16)
            .backgroundColor(this.showSessionSettingsPanel ? '#E8F0FE' : Color.White)
            .onClick(() => {
              this.showSessionSettingsPanel = !this.showSessionSettingsPanel;
            })

          Blank()
            .layoutWeight(1)

          Button({ type: ButtonType.Normal }) {
            if (this.isMessageSending) {
              Text('...')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
            } else {
              SymbolGlyph($r('sys.symbol.arrow_up'))
                .fontSize(19)
                .fontColor([Color.White])
            }
          }
            .width(34)
            .height(34)
            .borderRadius(17)
            .backgroundColor(this.canSendMessage() ? '#0B57D0' : '#9AA0A6')
            .enabled(this.canSendMessage())
            .onClick(() => {
              this.sendSelectedSessionMessage();
            })
        }
        .width('100%')
        .height(34)
        .padding({ left: 8, right: 8, bottom: 2 })
      }
      .width('100%')
      .constraintSize({ minHeight: 72, maxHeight: 132 })
      .backgroundColor('#F7F8FA')
      .borderRadius(14)
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 4, bottom: 5 })
    .backgroundColor(Color.White)
    .borderWidth({ top: 1 })
    .borderColor('#E5E7EB')
  }

  @Builder
  private SessionSettingsPanel() {
    Column({ space: 10 }) {
      this.ModeSection('权限模式', this.getPermissionOptionsForSelectedSession(), this.getSelectedPermissionMode(), 'permission')

      Row({ space: 8 }) {
        Column({ space: 8 }) {
          this.ModeSection('模型', this.getModelOptionsForSelectedSession(), this.getSelectedModelMode(), 'model')
        }
        .layoutWeight(1)

        Column({ space: 8 }) {
          this.ModeSection('智能', EFFORT_OPTIONS, this.getSelectedEffortLevel(), 'effort')
        }
        .layoutWeight(1)
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#F7F8FA')
    .borderRadius(12)
  }

  @Builder
  private ModeSection(title: string, options: SessionModeOption[], selectedKey: string, group: string) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor('#5F6368')
        .width('100%')

      ForEach(options, (option: SessionModeOption) => {
        Row({ space: 8 }) {
          Circle()
            .width(12)
            .height(12)
            .fill(option.key === selectedKey ? '#0B57D0' : '#DADCE0')

          Text(option.label)
            .fontSize(13)
            .fontColor(option.key === selectedKey ? '#0B57D0' : '#202124')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 7, bottom: 7 })
        .backgroundColor(option.key === selectedKey ? '#E8F0FE' : Color.White)
        .borderRadius(8)
        .onClick(() => {
          this.selectSessionMode(group, option.key);
        })
      }, (option: SessionModeOption) => option.key)
    }
    .width('100%')
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
  private TerminalAuthPanel() {
    Column({ space: 14 }) {
      Text('终端认证')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#202124')
        .width('100%')

      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.camera'))
            .fontSize(20)
            .fontColor([Color.White])

          Text(this.authAction === 'terminalScan' ? '扫码中...' : '扫描二维码认证')
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
        .enabled(!this.isBusy() && this.isAuthenticated)
        .onClick(() => {
          this.scanTerminalAuth();
        })

      Text('手动输入 URL 认证')
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
        .enabled(!this.isBusy() && this.isAuthenticated)
        .onClick(() => {
          this.approveTerminalAuth();
        })

      if (!this.isAuthenticated) {
        Text('请先创建或恢复账号，再认证终端')
          .fontSize(13)
          .fontColor('#5F6368')
          .width('100%')
      } else if (this.terminalAuthStatus.length > 0) {
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
      this.workspacePath = getWorkspacePath(context);
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
      this.activeTab = TAB_TERMINAL;
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
      this.activeTab = TAB_TERMINAL;
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
        this.activeTab = TAB_SETTINGS;
        this.refreshControlPlaneData();
      } else if (result.status === 'already_authorized') {
        this.terminalAuthStatus = `该终端已授权：${result.publicKeyPreview}`;
        this.status = '该终端已授权';
        this.activeTab = TAB_SETTINGS;
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
      const selectedSessionId = this.selectedSessionId;
      const snapshot: ControlPlaneSnapshot = await loadControlPlaneSnapshot(this.getAbilityContext(), serverUrl);
      if (!this.isCurrentSync(generation)) {
        return;
      }
      const previousMachines = this.machines;
      const previousSessions = this.sessions;
      const visibleSnapshotMachines = this.filterPendingDeletedMachines(snapshot.machines);
      this.reconcilePendingDeletedMachines(snapshot.machines);
      this.reconcilePendingArchivedSessions(snapshot.sessions);
      const nextMachines = this.mergeMachineSnapshotWithLocalMetadata(previousMachines, visibleSnapshotMachines);
      this.machines = nextMachines;
      const sessionsWithLocalMetadata = this.mergeSessionSnapshotWithLocalMetadata(previousSessions, snapshot.sessions);
      const nextSessions = this.mergeLocalSessionModes(previousSessions, sessionsWithLocalMetadata);
      this.sessions = nextSessions;
      this.dropSelectedSessionIfMissing();
      this.dropSelectedMachineIfMissing();
      this.syncStatus = snapshot.decodeWarningCount > 0 ? `同步完成，${snapshot.decodeWarningCount} 个字段解密失败` : '终端与会话已同步';
      if (this.pendingOpenSessionId.length > 0 && this.findSessionInList(nextSessions, this.pendingOpenSessionId)) {
        const pendingSessionId = this.pendingOpenSessionId;
        this.pendingOpenSessionId = '';
        this.isSpawningSession = false;
        this.attachingCodexThreadId = '';
        this.showNewSessionPanel = false;
        this.openSessionDetail(pendingSessionId);
        return;
      }
      if (this.pendingOpenSessionId.length > 0) {
        if (this.hasQueuedSyncRefresh) {
          this.newSessionStatus = '会话已创建，继续同步...';
        } else {
          this.pendingOpenSessionId = '';
          this.isSpawningSession = false;
          this.attachingCodexThreadId = '';
          this.newSessionStatus = '会话已创建，暂未同步到列表，请稍后刷新';
        }
      }
      if (this.shouldRefreshSelectedSessionMessagesAfterSync(previousSessions, nextSessions, selectedSessionId)) {
        this.messageStatus = '会话状态已更新，正在读取消息...';
        this.refreshSelectedSessionMessages();
      }
    } catch (error) {
      if (!this.isCurrentSync(generation)) {
        return;
      }
      console.error(`同步终端和会话失败：${error}`);
      if (this.pendingOpenSessionId.length > 0 && !this.hasQueuedSyncRefresh) {
        this.pendingOpenSessionId = '';
        this.isSpawningSession = false;
        this.attachingCodexThreadId = '';
      }
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
    this.closeMachineDetail();
    this.showNewSessionPanel = false;
    this.selectedMachineId = '';
    this.selectedNewSessionAgent = '';
    this.newSessionStatus = '';
    this.clearNewSessionDirectoryApproval();
    this.closeDirectoryPicker();
    this.isSpawningSession = false;
    this.clearMachineRename();
    this.clearSessionRename();
    this.isStoppingMachineDaemon = false;
    this.machineDaemonActionStatus = '';
    this.invalidateMachineStopConfirmation();
    this.isDeletingMachine = false;
    this.invalidateMachineDeleteConfirmation();
    this.machineDeleteStatus = '';
    this.machineDetailShowAllPaths = false;
    this.pendingDeletedMachineIds = [];
    this.pendingArchivedSessionIds = [];
    this.archivingSessionId = '';
    this.sessionArchiveStatus = '';
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
    if (this.isMachineDeletePending(event.id)) {
      return;
    }
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
        permissionMode: session.permissionMode ?? null,
        modelMode: session.modelMode ?? null,
        effortLevel: session.effortLevel ?? null,
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

  private getMachineRowKey(machine: HappyMachine): string {
    return `${machine.id}:${machine.active ? '1' : '0'}:${machine.activeAt}:${machine.metadataVersion}:${machine.daemonStateVersion}`;
  }

  private getSessionRowKey(session: HappySession): string {
    return `${session.id}:${session.active ? '1' : '0'}:${session.activeAt}:${session.thinking ? '1' : '0'}:${session.thinkingAt}:${session.metadataVersion}:${session.agentStateVersion}`;
  }

  private findMachineInList(machines: HappyMachine[], machineId: string): HappyMachine | null {
    for (const machine of machines) {
      if (machine.id === machineId) {
        return machine;
      }
    }
    return null;
  }

  private openMachineDetail(machineId: string): void {
    this.selectedSessionId = '';
    this.selectedMachineDetailId = machineId;
    this.resetCodexThreadState();
    const machine = this.findMachineInList(this.machines, machineId);
    if (machine) {
      const shouldResetDirectory = this.selectedMachineId !== machine.id || this.newSessionPath.trim().length === 0;
      this.selectedMachineId = machine.id;
      this.ensureSelectedNewSessionAgent(machine);
      if (shouldResetDirectory) {
        this.newSessionPath = this.getMachineDefaultDirectory(machine);
        this.clearNewSessionDirectoryApproval();
        this.closeDirectoryPicker();
      }
      if (machine.active && this.isMachineCodexAvailable(machine)) {
        this.refreshCodexThreads(machine);
      }
    }
    this.messages = [];
    this.permissions = [];
    this.messageStatus = '';
    this.messageDraft = '';
    this.messageSendStatus = '';
    this.permissionActionStatus = '';
    this.activePermissionActionId = '';
    this.showSessionSettingsPanel = false;
    this.showNewSessionPanel = false;
    this.machineDaemonActionStatus = '';
    this.invalidateMachineStopConfirmation();
    this.invalidateMachineDeleteConfirmation();
    this.machineDeleteStatus = '';
    this.isDeletingMachine = false;
    this.machineDetailShowAllPaths = false;
    this.clearSessionRename();
    this.clearMachineRename();
  }

  private closeMachineDetail(): void {
    const closingMachineId = this.selectedMachineDetailId;
    this.selectedMachineDetailId = '';
    this.machineDaemonActionStatus = '';
    this.invalidateMachineStopConfirmation();
    this.invalidateMachineDeleteConfirmation();
    this.machineDeleteStatus = '';
    this.isDeletingMachine = false;
    this.machineDetailShowAllPaths = false;
    this.resetCodexThreadState();
    this.closeDirectoryPicker();
    if (this.editingMachineId === closingMachineId) {
      this.clearMachineRename();
    }
  }

  private openSessionDetail(sessionId: string): void {
    this.selectedMachineDetailId = '';
    this.selectedSessionId = sessionId;
    this.messages = [];
    this.permissions = [];
    this.messageStatus = '正在读取消息...';
    this.messageDraft = '';
    this.messageSendStatus = '';
    this.permissionActionStatus = '';
    this.activePermissionActionId = '';
    this.showSessionSettingsPanel = false;
    this.clearSessionRename();
    this.isMessageSending = false;
    this.isPermissionSubmitting = false;
    this.messageSendGeneration += 1;
    this.pendingMessages = [];
    this.clearRetryMessage();
    this.resetMessageScrollState();
    this.refreshSelectedSessionMessages();
  }

  private closeSessionDetail(): void {
    const closingSessionId = this.selectedSessionId;
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
    this.showSessionSettingsPanel = false;
    if (this.editingSessionId === closingSessionId) {
      this.clearSessionRename();
    }
    this.isMessagesLoading = false;
    this.isMessageSending = false;
    this.isPermissionSubmitting = false;
    this.pendingMessages = [];
    this.clearRetryMessage();
    this.resetMessageScrollState();
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
      this.resetMessageScrollState();
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
      const shouldHoldScrollPosition = this.showJumpToLatestButton;
      this.messages = this.mergePendingMessages(snapshot.messages);
      this.permissions = snapshot.permissions;
      this.messageStatus = snapshot.decodeWarningCount > 0
        ? `消息读取完成，${snapshot.decodeWarningCount} 条解密失败`
        : `消息读取完成，${snapshot.messages.length} 条`;
      if (this.pendingMessages.length === 0 && this.messageSendStatus === '发送成功，正在同步...') {
        this.messageSendStatus = '发送成功';
      }
      if (this.messages.length === 0) {
        this.resetMessageScrollState();
      } else if (shouldHoldScrollPosition) {
        this.showJumpToLatestButton = true;
      } else {
        this.scrollMessagesToLatest(false);
      }
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

  private handleMessageDidScroll(): void {
    if (this.messages.length === 0) {
      return;
    }
    const currentOffsetY = this.readMessageScrollOffsetY();
    if (currentOffsetY === null) {
      return;
    }
    if (!this.hasMessageScrollOffset) {
      this.lastMessageScrollOffsetY = currentOffsetY;
      this.hasMessageScrollOffset = true;
      return;
    }
    const scrollDeltaY = currentOffsetY - this.lastMessageScrollOffsetY;
    this.lastMessageScrollOffsetY = currentOffsetY;
    if (scrollDeltaY < 0) {
      this.messageScrollAwayDistance += Math.abs(scrollDeltaY);
    }
    if (this.messageScrollAwayDistance > 4) {
      this.showJumpToLatestButton = true;
    }
  }

  private markMessagesAtLatest(): void {
    this.showJumpToLatestButton = false;
    this.messageScrollAwayDistance = 0;
    const currentOffsetY = this.readMessageScrollOffsetY();
    if (currentOffsetY !== null) {
      this.lastMessageScrollOffsetY = currentOffsetY;
      this.hasMessageScrollOffset = true;
    }
  }

  private resetMessageScrollState(): void {
    this.showJumpToLatestButton = false;
    this.hasMessageScrollOffset = false;
    this.lastMessageScrollOffsetY = 0;
    this.messageScrollAwayDistance = 0;
  }

  private scrollMessagesToLatest(animated: boolean = false): void {
    const sessionId = this.selectedSessionId;
    if (sessionId.length === 0) {
      return;
    }
    setTimeout(() => {
      if (this.selectedSessionId !== sessionId) {
        return;
      }
      try {
        if (animated) {
          this.messageScroller.scrollEdge(Edge.Bottom, { velocity: 1800 });
        } else {
          this.messageScroller.scrollEdge(Edge.Bottom);
        }
        this.markMessagesAtLatest();
      } catch (error) {
        console.error(`滚动到最新消息失败：${error}`);
      }
    }, 30);
  }

  private readMessageScrollOffsetY(): number | null {
    try {
      return this.messageScroller.currentOffset().yOffset;
    } catch (error) {
      return null;
    }
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
    this.scrollMessagesToLatest(true);
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
      if (result.responseMessages.length > 0) {
        this.schedulePostSendMessageRefreshes(sendGeneration, session.id);
      }
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

  private schedulePostSendMessageRefreshes(sendGeneration: number, sessionId: string): void {
    const delays: number[] = [2500, 8000, 15000];
    for (const delay of delays) {
      setTimeout((): void => {
        if (!this.isCurrentMessageSend(sendGeneration, sessionId)) {
          return;
        }
        this.refreshSelectedSessionMessages();
      }, delay);
    }
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

  private toggleNewSessionPanel(): void {
    this.showNewSessionPanel = !this.showNewSessionPanel;
    if (!this.showNewSessionPanel) {
      this.closeDirectoryPicker();
      return;
    }
    const machine = this.getSelectedNewSessionMachine() ?? this.getFirstOnlineMachine();
    if (machine) {
      this.selectedMachineId = machine.id;
      this.ensureSelectedNewSessionAgent(machine);
      this.newSessionPath = this.getMachineDefaultDirectory(machine);
      this.clearNewSessionDirectoryApproval();
      if (this.getSelectedNewSessionAgentKeyForMachine(machine) === 'codex') {
        this.refreshCodexThreads(machine);
      }
    }
  }

  private isDirectoryPickerOpenForMachine(machine: HappyMachine, purpose: string = DIRECTORY_PICKER_NEW_SESSION): boolean {
    return this.showDirectoryPicker
      && this.directoryPickerMachineId === machine.id
      && this.directoryPickerPurpose === purpose;
  }

  private isDirectoryPickerOpenForAnyPurpose(machine: HappyMachine): boolean {
    return this.showDirectoryPicker && this.directoryPickerMachineId === machine.id;
  }

  private toggleDirectoryPicker(machine: HappyMachine): void {
    if (this.isDirectoryPickerOpenForMachine(machine)) {
      this.closeDirectoryPicker();
      return;
    }
    this.selectedMachineId = machine.id;
    if (this.newSessionPath.trim().length === 0) {
      this.newSessionPath = this.getMachineDefaultDirectory(machine);
    }
    this.showDirectoryPicker = true;
    this.directoryPickerPurpose = DIRECTORY_PICKER_NEW_SESSION;
    this.directoryPickerMachineId = machine.id;
    this.directoryPickerShowHidden = false;
    const startPath = this.resolveMachineSpawnPath(this.newSessionPath, machine);
    this.loadDirectoryPickerPath(machine, startPath.length > 0 ? startPath : this.getMachineDefaultDirectory(machine));
  }

  private toggleWorkspaceDirectoryPicker(machine: HappyMachine): void {
    if (this.isDirectoryPickerOpenForMachine(machine, DIRECTORY_PICKER_WORKSPACE)) {
      this.closeDirectoryPicker();
      return;
    }
    this.workspaceMachineId = machine.id;
    this.showDirectoryPicker = true;
    this.directoryPickerPurpose = DIRECTORY_PICKER_WORKSPACE;
    this.directoryPickerMachineId = machine.id;
    this.directoryPickerShowHidden = false;
    const startPath = this.resolveMachineSpawnPath(
      this.workspacePath.trim().length > 0 ? this.workspacePath : this.getMachineDefaultDirectory(machine),
      machine,
    );
    this.loadDirectoryPickerPath(machine, startPath.length > 0 ? startPath : this.getMachineDefaultDirectory(machine));
  }

  private closeDirectoryPicker(): void {
    this.directoryPickerGeneration += 1;
    this.showDirectoryPicker = false;
    this.directoryPickerPurpose = '';
    this.directoryPickerMachineId = '';
    this.directoryPickerPath = '';
    this.directoryPickerParentPath = '';
    this.directoryPickerEntries = [];
    this.directoryPickerStatus = '';
    this.isDirectoryPickerLoading = false;
    this.directoryPickerShowHidden = false;
  }

  private toggleDirectoryPickerHidden(machine: HappyMachine): void {
    if (!this.isDirectoryPickerOpenForAnyPurpose(machine)) {
      return;
    }
    this.directoryPickerShowHidden = !this.directoryPickerShowHidden;
    const inputPath = this.directoryPickerPurpose === DIRECTORY_PICKER_WORKSPACE ? this.workspacePath : this.newSessionPath;
    const path = this.directoryPickerPath.length > 0 ? this.directoryPickerPath : this.resolveMachineSpawnPath(inputPath, machine);
    this.loadDirectoryPickerPath(machine, path);
  }

  private openDirectoryPickerPath(machine: HappyMachine, path: string): void {
    if (!this.isDirectoryPickerOpenForAnyPurpose(machine) || path.length === 0) {
      return;
    }
    this.loadDirectoryPickerPath(machine, path);
  }

  private useDirectoryPickerCurrent(machine: HappyMachine): void {
    if (!this.isDirectoryPickerOpenForAnyPurpose(machine) || this.directoryPickerPath.length === 0) {
      return;
    }
    const purpose = this.directoryPickerPurpose;
    if (purpose === DIRECTORY_PICKER_WORKSPACE) {
      this.workspaceMachineId = machine.id;
      this.workspacePath = this.formatMachinePathForInput(this.directoryPickerPath, machine);
      this.workspaceStatus = '已选择目录，点击保存后作为默认工作空间';
    } else {
      this.selectedMachineId = machine.id;
      this.newSessionPath = this.formatMachinePathForInput(this.directoryPickerPath, machine);
      this.clearNewSessionDirectoryApproval();
    }
    this.closeDirectoryPicker();
    if (purpose !== DIRECTORY_PICKER_WORKSPACE && this.getSelectedNewSessionAgentKeyForMachine(machine) === 'codex') {
      this.refreshCodexThreads(machine);
    }
  }

  private loadDirectoryPickerPath(machine: HappyMachine, path: string): void {
    if (!this.isAuthenticated || !machine.active) {
      this.directoryPickerStatus = '终端离线，无法读取目录';
      return;
    }
    const generation = this.directoryPickerGeneration + 1;
    this.directoryPickerGeneration = generation;
    this.directoryPickerMachineId = machine.id;
    this.directoryPickerPath = path;
    this.directoryPickerParentPath = '';
    this.directoryPickerEntries = [];
    this.directoryPickerStatus = '正在读取目录...';
    this.isDirectoryPickerLoading = true;
    this.loadDirectoryPickerPathAsync(generation, machine, path, this.directoryPickerShowHidden);
  }

  private getWorkspaceMachineId(): string {
    if (this.workspaceMachineId.length > 0) {
      const machine = this.findMachineInList(this.machines, this.workspaceMachineId);
      if (machine && machine.active) {
        return machine.id;
      }
    }
    const firstOnline = this.getFirstOnlineMachine();
    return firstOnline ? firstOnline.id : '';
  }

  private getWorkspacePickerMachine(): HappyMachine | null {
    const machineId = this.getWorkspaceMachineId();
    if (machineId.length === 0) {
      return null;
    }
    const machine = this.findMachineInList(this.machines, machineId);
    return machine && machine.active ? machine : null;
  }

  private isWorkspaceDirectoryPickerOpen(): boolean {
    const machine = this.getWorkspacePickerMachine();
    return machine !== null && this.isDirectoryPickerOpenForMachine(machine, DIRECTORY_PICKER_WORKSPACE);
  }

  private saveWorkspacePath(): void {
    if (this.isSavingWorkspace) {
      return;
    }
    this.isSavingWorkspace = true;
    this.workspaceStatus = '正在保存工作空间...';
    this.saveWorkspacePathAsync(this.workspacePath);
  }

  private async saveWorkspacePathAsync(path: string): Promise<void> {
    try {
      await setWorkspacePath(this.getAbilityContext(), path);
      this.workspacePath = getWorkspacePath(this.getAbilityContext());
      this.workspaceStatus = this.workspacePath.length > 0 ? '工作空间已保存，后续新建会话会默认使用该目录' : '已清除默认工作空间';
      const machine = this.getSelectedNewSessionMachine();
      if (this.showNewSessionPanel && machine) {
        this.newSessionPath = this.getMachineDefaultDirectory(machine);
        this.clearNewSessionDirectoryApproval();
        if (this.getSelectedNewSessionAgentKeyForMachine(machine) === 'codex') {
          this.refreshCodexThreads(machine);
        }
      }
    } catch (error) {
      console.error(`保存工作空间失败：${error}`);
      this.workspaceStatus = `保存失败：${this.toUserError(error, '请稍后重试')}`;
    } finally {
      this.isSavingWorkspace = false;
    }
  }

  private clearWorkspacePath(): void {
    if (this.isSavingWorkspace) {
      return;
    }
    this.workspacePath = '';
    this.closeDirectoryPicker();
    this.saveWorkspacePath();
  }

  private async loadDirectoryPickerPathAsync(
    generation: number,
    machine: HappyMachine,
    path: string,
    showHidden: boolean,
  ): Promise<void> {
    try {
      const result: DirectoryListResult = await listMachineDirectories(this.getAbilityContext(), this.serverUrl, machine, {
        path,
        showHidden,
        limit: 100,
      });
      if (!this.isCurrentDirectoryPicker(generation, machine)) {
        return;
      }
      this.directoryPickerPath = result.path;
      this.directoryPickerParentPath = result.parentPath ?? '';
      this.directoryPickerEntries = result.entries;
      this.directoryPickerStatus = result.truncated
        ? `已显示前 ${result.entries.length} 个目录`
        : `已读取 ${result.entries.length} 个目录`;
    } catch (error) {
      if (!this.isCurrentDirectoryPicker(generation, machine)) {
        return;
      }
      console.error(`读取目录失败：${error}`);
      this.directoryPickerEntries = [];
      this.directoryPickerStatus = `读取失败：${this.toUserError(error, '请检查目录权限或手动输入路径')}`;
    } finally {
      if (this.isCurrentDirectoryPicker(generation, machine)) {
        this.isDirectoryPickerLoading = false;
      }
    }
  }

  private isCurrentDirectoryPicker(generation: number, machine: HappyMachine): boolean {
    return this.showDirectoryPicker
      && this.directoryPickerMachineId === machine.id
      && this.directoryPickerGeneration === generation;
  }

  private getOnlineMachines(): HappyMachine[] {
    const online: HappyMachine[] = [];
    for (const machine of this.machines) {
      if (machine.active) {
        online.push(machine);
      }
    }
    return online;
  }

  private getOnlineMachineCount(): number {
    let count = 0;
    for (const machine of this.machines) {
      if (machine.active) {
        count += 1;
      }
    }
    return count;
  }

  private getFirstOnlineMachine(): HappyMachine | null {
    for (const machine of this.machines) {
      if (machine.active) {
        return machine;
      }
    }
    return null;
  }

  private getSelectedNewSessionMachine(): HappyMachine | null {
    for (const machine of this.machines) {
      if (machine.id === this.selectedMachineId && machine.active) {
        return machine;
      }
    }
    return null;
  }

  private getMachineDefaultDirectory(machine: HappyMachine): string {
    const workspace = this.workspacePath.trim();
    if (workspace.length > 0 && this.canResolveMachinePath(workspace, machine)) {
      return workspace;
    }
    const homeDir = this.getMachinePathHomeDir(machine);
    if (homeDir.length > 0) {
      return homeDir;
    }
    const happyHomeDir = this.normalizeOptionalText(machine.metadata?.happyHomeDir);
    if (happyHomeDir.length > 0) {
      return happyHomeDir;
    }
    return '/';
  }

  private getNewSessionAgentOptions(): SessionModeOption[] {
    const machine = this.getSelectedNewSessionMachine();
    if (!machine) {
      return [];
    }
    return this.getNewSessionAgentOptionsForMachine(machine);
  }

  private getNewSessionAgentOptionsForMachine(machine: HappyMachine): SessionModeOption[] {
    const availability = machine.metadata?.cliAvailability;
    if (!availability) {
      return NEW_SESSION_AGENT_OPTIONS;
    }
    const agents: SessionModeOption[] = [];
    for (const agent of NEW_SESSION_AGENT_OPTIONS) {
      if (this.isAgentAvailable(availability, agent.key)) {
        agents.push(agent);
      }
    }
    return agents;
  }

  private isAgentAvailable(availability: MachineAvailability, agent: string): boolean {
    if (agent === 'claude') {
      return availability.claude === true;
    }
    if (agent === 'codex') {
      return availability.codex === true;
    }
    if (agent === 'openclaw') {
      return availability.openclaw === true;
    }
    if (agent === 'gemini') {
      return availability.gemini === true;
    }
    return false;
  }

  private getSelectedNewSessionAgentKey(): string {
    const machine = this.getSelectedNewSessionMachine();
    if (!machine) {
      return '';
    }
    return this.getSelectedNewSessionAgentKeyForMachine(machine);
  }

  private getSelectedNewSessionAgentKeyForMachine(machine: HappyMachine): string {
    const agents = this.getNewSessionAgentOptionsForMachine(machine);
    if (this.isAgentKeyInOptions(this.selectedNewSessionAgent, agents)) {
      return this.selectedNewSessionAgent;
    }
    return this.choosePreferredNewSessionAgent(agents);
  }

  private ensureSelectedNewSessionAgent(machine: HappyMachine): void {
    const agents = this.getNewSessionAgentOptionsForMachine(machine);
    if (this.isAgentKeyInOptions(this.selectedNewSessionAgent, agents)) {
      return;
    }
    this.selectedNewSessionAgent = this.choosePreferredNewSessionAgent(agents);
  }

  private choosePreferredNewSessionAgent(agents: SessionModeOption[]): string {
    for (const agent of agents) {
      if (agent.key === 'codex') {
        return 'codex';
      }
    }
    return agents.length > 0 ? agents[0].key : '';
  }

  private isAgentKeyInOptions(agentKey: string, agents: SessionModeOption[]): boolean {
    if (agentKey.length === 0) {
      return false;
    }
    for (const agent of agents) {
      if (agent.key === agentKey) {
        return true;
      }
    }
    return false;
  }

  private clearNewSessionDirectoryApproval(): void {
    this.newSessionApprovalDirectory = '';
    this.newSessionApprovalMachineId = '';
  }

  private canSpawnSession(): boolean {
    const machine = this.getSelectedNewSessionMachine();
    return this.isAuthenticated
      && !this.isSpawningSession
      && this.pendingOpenSessionId.length === 0
      && machine !== null
      && this.getSelectedNewSessionAgentKey().length > 0
      && this.newSessionPath.trim().length > 0;
  }

  private canSpawnSessionForMachine(machine: HappyMachine): boolean {
    return this.isAuthenticated
      && machine.active
      && !this.isSpawningSession
      && this.pendingOpenSessionId.length === 0
      && this.getSelectedNewSessionAgentKeyForMachine(machine).length > 0
      && this.newSessionPath.trim().length > 0
      && (this.selectedMachineId.length === 0 || this.selectedMachineId === machine.id);
  }

  private spawnNewSessionFromPanel(): void {
    if (!this.canSpawnSession()) {
      if (this.getSelectedNewSessionMachine() === null) {
        this.newSessionStatus = '请选择在线终端';
      } else if (this.getSelectedNewSessionAgentKey().length === 0) {
        this.newSessionStatus = '当前终端未检测到可用 Agent';
      } else if (this.newSessionPath.trim().length === 0) {
        this.newSessionStatus = '请输入工作目录';
      }
      return;
    }
    const machine = this.getSelectedNewSessionMachine();
    if (!machine) {
      this.newSessionStatus = '请选择在线终端';
      return;
    }
    if (!this.canResolveMachinePath(this.newSessionPath, machine)) {
      this.newSessionStatus = '当前终端缺少主目录信息，请使用绝对路径';
      return;
    }
    const directory = this.resolveMachineSpawnPath(this.newSessionPath, machine);
    const approvedNewDirectoryCreation = this.newSessionApprovalDirectory.length > 0
      && this.newSessionApprovalDirectory === directory
      && this.newSessionApprovalMachineId === machine.id;
    this.isSpawningSession = true;
    this.newSessionStatus = approvedNewDirectoryCreation ? '正在确认创建目录...' : '正在创建会话...';
    this.spawnNewSessionFromPanelAsync(machine, directory, approvedNewDirectoryCreation);
  }

  private async spawnNewSessionFromPanelAsync(
    machine: HappyMachine,
    directory: string,
    approvedNewDirectoryCreation: boolean,
  ): Promise<void> {
    let keepSpawningUntilSync = false;
    try {
      const result: SpawnMachineSessionResult = await spawnMachineSession(this.getAbilityContext(), this.serverUrl, machine, {
        directory,
        approvedNewDirectoryCreation,
        agent: this.getSelectedNewSessionAgentKey(),
      });
      if (result.type === 'success' && result.sessionId && result.sessionId.length > 0) {
        keepSpawningUntilSync = true;
        this.pendingOpenSessionId = result.sessionId;
        this.clearNewSessionDirectoryApproval();
        this.newSessionStatus = '会话已创建，正在同步...';
        this.refreshControlPlaneData();
      } else if (result.type === 'requestToApproveDirectoryCreation') {
        this.newSessionApprovalDirectory = result.directory && result.directory.length > 0 ? result.directory : directory;
        this.newSessionApprovalMachineId = machine.id;
        this.newSessionPath = this.newSessionApprovalDirectory;
        this.newSessionStatus = `目录不存在，再次确认将创建：${this.newSessionApprovalDirectory}`;
      } else {
        this.newSessionStatus = result.errorMessage && result.errorMessage.length > 0 ? result.errorMessage : '创建会话失败';
      }
    } catch (error) {
      console.error(`创建会话失败：${error}`);
      this.newSessionStatus = `创建会话失败：${this.toUserError(error, '请检查终端在线状态和工作目录')}`;
    } finally {
      if (!keepSpawningUntilSync) {
        this.isSpawningSession = false;
      }
    }
  }

  private resetCodexThreadState(): void {
    this.codexThreadGeneration += 1;
    this.codexThreads = [];
    this.codexThreadStatus = '';
    this.codexThreadMachineId = '';
    this.codexThreadCwd = '';
    this.isLoadingCodexThreads = false;
    this.attachingCodexThreadId = '';
  }

  private isMachineCodexAvailable(machine: HappyMachine): boolean {
    return machine.metadata?.cliAvailability?.codex === true;
  }

  private shouldShowNewSessionCodexThreads(machine: HappyMachine | null): boolean {
    return machine !== null
      && this.getSelectedNewSessionAgentKeyForMachine(machine) === 'codex'
      && this.isMachineCodexAvailable(machine);
  }

  private getCodexThreadListCwd(machine: HappyMachine): string {
    const inputPath = this.newSessionPath.trim().length > 0 ? this.newSessionPath : this.getMachineDefaultDirectory(machine);
    const resolved = this.resolveMachineSpawnPath(inputPath, machine).trim();
    return resolved.length > 0 ? resolved : this.getMachineDefaultDirectory(machine);
  }

  private isCodexThreadStateForCurrentPath(machine: HappyMachine): boolean {
    return this.codexThreadMachineId === machine.id && this.codexThreadCwd === this.getCodexThreadListCwd(machine);
  }

  private getCodexThreadsForCurrentPath(machine: HappyMachine): CodexThreadSummary[] {
    return this.isCodexThreadStateForCurrentPath(machine) ? this.codexThreads : [];
  }

  private hasCodexThreadsForCurrentPath(machine: HappyMachine): boolean {
    return this.getCodexThreadsForCurrentPath(machine).length > 0;
  }

  private canRefreshCodexThreads(machine: HappyMachine): boolean {
    return this.isAuthenticated
      && machine.active
      && this.isMachineCodexAvailable(machine)
      && !this.isLoadingCodexThreads
      && this.attachingCodexThreadId.length === 0;
  }

  private refreshCodexThreads(machine: HappyMachine): void {
    if (!this.canRefreshCodexThreads(machine)) {
      return;
    }
    const cwd = this.getCodexThreadListCwd(machine);
    const generation = this.codexThreadGeneration + 1;
    this.codexThreadGeneration = generation;
    this.codexThreadMachineId = machine.id;
    this.codexThreadCwd = cwd;
    this.isLoadingCodexThreads = true;
    this.codexThreads = [];
    this.codexThreadStatus = '正在读取当前目录 Codex 会话...';
    this.refreshCodexThreadsAsync(generation, machine, cwd);
  }

  private async refreshCodexThreadsAsync(generation: number, machine: HappyMachine, cwd: string): Promise<void> {
    try {
      const result: CodexThreadListResult = await listCodexThreads(this.getAbilityContext(), this.serverUrl, machine, {
        limit: 20,
        cwd,
        archived: false,
      });
      if (!this.isCurrentCodexThreadLoad(generation, machine, cwd)) {
        return;
      }
      this.codexThreads = result.threads;
      this.codexThreadStatus = result.threads.length > 0
        ? `已读取 ${result.threads.length} 个当前目录 Codex 会话`
        : '当前目录未读取到 Codex 会话';
    } catch (error) {
      if (!this.isCurrentCodexThreadLoad(generation, machine, cwd)) {
        return;
      }
      console.error(`读取 Codex 会话失败：${error}`);
      this.codexThreadStatus = `失败：${this.toUserError(error, '请确认电脑端 Codex 可用且 daemon 在线')}`;
    } finally {
      if (this.isCurrentCodexThreadLoad(generation, machine, cwd)) {
        this.isLoadingCodexThreads = false;
      }
    }
  }

  private isCurrentCodexThreadLoad(generation: number, machine: HappyMachine, cwd: string): boolean {
    return this.codexThreadGeneration === generation
      && this.codexThreadMachineId === machine.id
      && this.codexThreadCwd === cwd;
  }

  private canAttachCodexThread(machine: HappyMachine, thread: CodexThreadSummary): boolean {
    return this.isAuthenticated
      && machine.active
      && this.isMachineCodexAvailable(machine)
      && thread.id.length > 0
      && this.attachingCodexThreadId.length === 0
      && this.pendingOpenSessionId.length === 0;
  }

  private attachCodexThreadFromList(machine: HappyMachine, thread: CodexThreadSummary): void {
    if (!this.canAttachCodexThread(machine, thread)) {
      return;
    }
    this.attachingCodexThreadId = thread.id;
    this.codexThreadStatus = '正在接入 Codex 会话...';
    this.attachCodexThreadFromListAsync(machine, thread);
  }

  private async attachCodexThreadFromListAsync(machine: HappyMachine, thread: CodexThreadSummary): Promise<void> {
    let keepAttachingUntilSync = false;
    try {
      const result: SpawnMachineSessionResult = await attachCodexThread(this.getAbilityContext(), this.serverUrl, machine, thread);
      if (result.type === 'success' && result.sessionId && result.sessionId.length > 0) {
        keepAttachingUntilSync = true;
        this.pendingOpenSessionId = result.sessionId;
        this.codexThreadStatus = '已接入 Codex，会话正在同步...';
        this.refreshControlPlaneData();
      } else {
        this.codexThreadStatus = result.errorMessage && result.errorMessage.length > 0 ? `接入失败：${result.errorMessage}` : '接入失败';
      }
    } catch (error) {
      console.error(`接入 Codex 会话失败：${error}`);
      this.codexThreadStatus = `接入失败：${this.toUserError(error, '请确认 Codex thread 仍存在')}`;
    } finally {
      if (!keepAttachingUntilSync) {
        this.attachingCodexThreadId = '';
      }
    }
  }

  private getCodexThreadTitle(thread: CodexThreadSummary): string {
    if (thread.name.length > 0) {
      return thread.name;
    }
    if (thread.preview.length > 0) {
      return thread.preview;
    }
    return this.trimIdentifier(thread.id);
  }

  private getCodexThreadSubtitle(thread: CodexThreadSummary, machine: HappyMachine): string {
    const parts: string[] = [];
    if (thread.cwd.length > 0) {
      parts.push(this.formatMachinePathForDisplay(thread.cwd, machine));
    }
    if (thread.updatedAt > 0) {
      parts.push(this.formatRelativeTime(thread.updatedAt * 1000));
    }
    if (thread.modelProvider.length > 0) {
      parts.push(thread.modelProvider);
    }
    return parts.length > 0 ? parts.join(' · ') : this.trimIdentifier(thread.id);
  }

  private startMachineRename(machine: HappyMachine): void {
    if (this.isRenamingMachine) {
      return;
    }
    this.editingMachineId = machine.id;
    this.machineRenameDraft = this.normalizeOptionalText(machine.metadata?.displayName);
    this.machineRenameStatus = '';
  }

  private clearMachineRename(): void {
    this.editingMachineId = '';
    this.machineRenameDraft = '';
    this.machineRenameStatus = '';
    this.isRenamingMachine = false;
  }

  private canSubmitMachineRename(machine: HappyMachine): boolean {
    return this.isAuthenticated
      && !this.isRenamingMachine
      && this.editingMachineId === machine.id;
  }

  private submitMachineRename(machine: HappyMachine): void {
    if (!this.canSubmitMachineRename(machine)) {
      return;
    }
    this.isRenamingMachine = true;
    this.machineRenameStatus = '正在保存终端名称...';
    this.submitMachineRenameAsync(machine, this.machineRenameDraft);
  }

  private async submitMachineRenameAsync(machine: HappyMachine, displayName: string): Promise<void> {
    try {
      const result: MachineRenameResult = await renameMachine(
        this.getAbilityContext(),
        this.serverUrl,
        machine,
        displayName,
      );
      this.applyMachineMetadata(machine.id, result.metadata, result.version);
      this.syncStatus = '终端名称已更新，正在同步...';
      this.clearMachineRename();
      this.refreshControlPlaneData();
    } catch (error) {
      if (this.editingMachineId !== machine.id) {
        return;
      }
      console.error(`终端重命名失败：${error}`);
      this.machineRenameStatus = `保存失败：${this.toUserError(error, '请同步后重试')}`;
    } finally {
      if (this.editingMachineId === machine.id) {
        this.isRenamingMachine = false;
      }
    }
  }

  private applyMachineMetadata(machineId: string, metadata: MachineMetadata, version: number): void {
    const machines = this.machines.map((machine: HappyMachine): HappyMachine => {
      if (machine.id !== machineId) {
        return machine;
      }
      return {
        id: machine.id,
        seq: machine.seq,
        createdAt: machine.createdAt,
        updatedAt: machine.updatedAt,
        active: machine.active,
        activeAt: machine.activeAt,
        metadata: metadata,
        metadataVersion: version,
        daemonState: machine.daemonState,
        daemonStateVersion: machine.daemonStateVersion,
        dataEncryptionKey: machine.dataEncryptionKey,
      };
    });
    this.machines = machines;
  }

  private startSessionRename(session: HappySession): void {
    if (this.isRenamingSession) {
      return;
    }
    this.editingSessionId = session.id;
    this.sessionRenameDraft = getSessionTitle(session);
    this.sessionRenameStatus = '';
  }

  private clearSessionRename(): void {
    this.editingSessionId = '';
    this.sessionRenameDraft = '';
    this.sessionRenameStatus = '';
    this.isRenamingSession = false;
  }

  private canSubmitSessionRename(session: HappySession): boolean {
    return this.isAuthenticated
      && !this.isRenamingSession
      && this.editingSessionId === session.id;
  }

  private submitSessionRename(session: HappySession): void {
    if (!this.canSubmitSessionRename(session)) {
      return;
    }
    this.isRenamingSession = true;
    this.sessionRenameStatus = '正在保存会话名称...';
    this.submitSessionRenameAsync(session, this.sessionRenameDraft);
  }

  private async submitSessionRenameAsync(session: HappySession, name: string): Promise<void> {
    try {
      const result: SessionRenameResult = await renameSession(
        this.getAbilityContext(),
        this.serverUrl,
        session,
        name,
      );
      this.applySessionMetadata(session.id, result.metadata, result.version);
      this.syncStatus = '会话名称已更新，正在同步...';
      this.clearSessionRename();
      this.refreshControlPlaneData();
    } catch (error) {
      if (this.editingSessionId !== session.id) {
        return;
      }
      console.error(`会话重命名失败：${error}`);
      this.sessionRenameStatus = `保存失败：${this.toUserError(error, '请同步后重试')}`;
    } finally {
      if (this.editingSessionId === session.id) {
        this.isRenamingSession = false;
      }
    }
  }

  private canArchiveSession(session: HappySession): boolean {
    return this.isAuthenticated
      && this.archivingSessionId.length === 0
      && !this.shouldHideSessionFromList(session);
  }

  private submitSessionArchive(session: HappySession): void {
    if (!this.canArchiveSession(session)) {
      return;
    }
    this.archivingSessionId = session.id;
    this.sessionArchiveStatus = '正在归档会话...';
    this.submitSessionArchiveAsync(session);
  }

  private async submitSessionArchiveAsync(session: HappySession): Promise<void> {
    try {
      const result: SessionArchiveResult = await archiveSession(
        this.getAbilityContext(),
        this.serverUrl,
        session,
      );
      this.markSessionArchivePending(session.id);
      this.applySessionMetadata(session.id, result.metadata, result.version);
      if (this.editingSessionId === session.id) {
        this.clearSessionRename();
      }
      if (this.selectedSessionId === session.id) {
        this.closeSessionDetail();
      }
      this.sessionArchiveStatus = result.message && result.message.length > 0 ? result.message : '会话已归档';
      this.syncStatus = '会话已归档，正在同步...';
      this.refreshControlPlaneData();
    } catch (error) {
      if (this.archivingSessionId !== session.id) {
        return;
      }
      console.error(`会话归档失败：${error}`);
      this.sessionArchiveStatus = `归档失败：${this.toUserError(error, '请同步后重试')}`;
    } finally {
      if (this.archivingSessionId === session.id) {
        this.archivingSessionId = '';
      }
    }
  }

  private applySessionMetadata(sessionId: string, metadata: SessionMetadata, version: number): void {
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
        metadata: metadata,
        metadataVersion: version,
        agentState: session.agentState,
        agentStateVersion: session.agentStateVersion,
        dataEncryptionKey: session.dataEncryptionKey,
        permissionMode: session.permissionMode ?? null,
        modelMode: session.modelMode ?? null,
        effortLevel: session.effortLevel ?? null,
      };
    });
    this.sessions = sessions;
  }

  private getVisibleSessions(): HappySession[] {
    return this.sessions.filter((session: HappySession): boolean => !this.shouldHideSessionFromList(session));
  }

  private getVisibleSessionCount(): number {
    return this.getVisibleSessions().length;
  }

  private shouldHideSessionFromList(session: HappySession): boolean {
    return this.isSessionArchivePending(session.id) || isSessionArchived(session);
  }

  private mergeMachineSnapshotWithLocalMetadata(previousMachines: HappyMachine[], nextMachines: HappyMachine[]): HappyMachine[] {
    return nextMachines.map((machine: HappyMachine): HappyMachine => {
      const previous = this.findMachineInList(previousMachines, machine.id);
      if (!previous || previous.metadataVersion <= machine.metadataVersion) {
        return machine;
      }
      return {
        id: machine.id,
        seq: machine.seq,
        createdAt: machine.createdAt,
        updatedAt: machine.updatedAt,
        active: machine.active,
        activeAt: machine.activeAt,
        metadata: previous.metadata,
        metadataVersion: previous.metadataVersion,
        daemonState: machine.daemonState,
        daemonStateVersion: machine.daemonStateVersion,
        dataEncryptionKey: machine.dataEncryptionKey,
      };
    });
  }

  private mergeSessionSnapshotWithLocalMetadata(previousSessions: HappySession[], nextSessions: HappySession[]): HappySession[] {
    return nextSessions.map((session: HappySession): HappySession => {
      const previous = this.findSessionInList(previousSessions, session.id);
      if (!previous || previous.metadataVersion <= session.metadataVersion) {
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
        metadata: previous.metadata,
        metadataVersion: previous.metadataVersion,
        agentState: session.agentState,
        agentStateVersion: session.agentStateVersion,
        dataEncryptionKey: session.dataEncryptionKey,
        permissionMode: session.permissionMode ?? null,
        modelMode: session.modelMode ?? null,
        effortLevel: session.effortLevel ?? null,
      };
    });
  }

  private filterPendingDeletedMachines(machines: HappyMachine[]): HappyMachine[] {
    if (this.pendingDeletedMachineIds.length === 0) {
      return machines;
    }
    return machines.filter((machine: HappyMachine): boolean => !this.isMachineDeletePending(machine.id));
  }

  private reconcilePendingDeletedMachines(snapshotMachines: HappyMachine[]): void {
    if (this.pendingDeletedMachineIds.length === 0) {
      return;
    }
    const remaining: string[] = [];
    for (const machineId of this.pendingDeletedMachineIds) {
      if (this.findMachineInList(snapshotMachines, machineId)) {
        remaining.push(machineId);
      }
    }
    this.pendingDeletedMachineIds = remaining;
  }

  private reconcilePendingArchivedSessions(snapshotSessions: HappySession[]): void {
    if (this.pendingArchivedSessionIds.length === 0) {
      return;
    }
    const remaining: string[] = [];
    for (const sessionId of this.pendingArchivedSessionIds) {
      const snapshotSession = this.findSessionInList(snapshotSessions, sessionId);
      if (snapshotSession && !isSessionArchived(snapshotSession)) {
        remaining.push(sessionId);
      }
    }
    this.pendingArchivedSessionIds = remaining;
  }

  private markMachineDeletePending(machineId: string): void {
    if (!this.isMachineDeletePending(machineId)) {
      this.pendingDeletedMachineIds.push(machineId);
    }
  }

  private clearMachineDeletePending(machineId: string): void {
    this.pendingDeletedMachineIds = this.pendingDeletedMachineIds.filter((id: string): boolean => id !== machineId);
  }

  private isMachineDeletePending(machineId: string): boolean {
    return this.pendingDeletedMachineIds.includes(machineId);
  }

  private markSessionArchivePending(sessionId: string): void {
    if (!this.isSessionArchivePending(sessionId)) {
      this.pendingArchivedSessionIds.push(sessionId);
    }
  }

  private isSessionArchivePending(sessionId: string): boolean {
    return this.pendingArchivedSessionIds.includes(sessionId);
  }

  private mergeLocalSessionModes(previousSessions: HappySession[], nextSessions: HappySession[]): HappySession[] {
    return nextSessions.map((session: HappySession): HappySession => {
      const previous = this.findSessionInList(previousSessions, session.id);
      if (!previous) {
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
        permissionMode: previous.permissionMode ?? session.permissionMode ?? null,
        modelMode: previous.modelMode ?? session.modelMode ?? null,
        effortLevel: previous.effortLevel ?? session.effortLevel ?? null,
      };
    });
  }

  private getPermissionOptionsForSelectedSession(): SessionModeOption[] {
    const flavor = this.getSelectedSessionFlavor();
    if (flavor === 'codex') {
      return CODEX_PERMISSION_OPTIONS;
    }
    if (flavor === 'gemini') {
      return GEMINI_PERMISSION_OPTIONS;
    }
    if (flavor === 'openclaw') {
      return [
        { key: 'default', label: '默认' },
        { key: 'bypassPermissions', label: '全部允许' },
      ];
    }
    return CLAUDE_PERMISSION_OPTIONS;
  }

  private getModelOptionsForSelectedSession(): SessionModeOption[] {
    const flavor = this.getSelectedSessionFlavor();
    if (flavor === 'codex') {
      return CODEX_MODEL_OPTIONS;
    }
    if (flavor === 'claude' || flavor.length === 0) {
      return CLAUDE_MODEL_OPTIONS;
    }
    return DEFAULT_MODEL_OPTIONS;
  }

  private getSelectedPermissionMode(): string {
    const session = this.getSelectedSession();
    const explicitMode = this.normalizeOptionalText(session?.permissionMode);
    if (explicitMode.length > 0) {
      return explicitMode;
    }
    const metadataMode = this.normalizeOptionalText(session?.metadata?.currentOperatingModeCode);
    return metadataMode.length > 0 ? metadataMode : 'default';
  }

  private getSelectedModelMode(): string {
    const session = this.getSelectedSession();
    const explicitModel = this.normalizeOptionalText(session?.modelMode);
    if (explicitModel.length > 0) {
      return explicitModel;
    }
    const metadataModel = this.normalizeOptionalText(session?.metadata?.currentModelCode);
    return metadataModel.length > 0 ? metadataModel : 'default';
  }

  private getSelectedEffortLevel(): string {
    const session = this.getSelectedSession();
    const effortLevel = this.normalizeOptionalText(session?.effortLevel);
    return effortLevel.length > 0 ? effortLevel : 'xhigh';
  }

  private getSelectedSessionFlavor(): string {
    const session = this.getSelectedSession();
    const flavor = this.normalizeOptionalText(session?.metadata?.flavor);
    return flavor.length > 0 ? flavor : 'claude';
  }

  private selectSessionMode(group: string, key: string): void {
    const session = this.getSelectedSession();
    if (!session) {
      return;
    }
    const sessions = this.sessions.map((item: HappySession): HappySession => {
      if (item.id !== session.id) {
        return item;
      }
      return {
        id: item.id,
        seq: item.seq,
        createdAt: item.createdAt,
        updatedAt: item.updatedAt,
        active: item.active,
        activeAt: item.activeAt,
        thinking: item.thinking,
        thinkingAt: item.thinkingAt,
        metadata: item.metadata,
        metadataVersion: item.metadataVersion,
        agentState: item.agentState,
        agentStateVersion: item.agentStateVersion,
        dataEncryptionKey: item.dataEncryptionKey,
        permissionMode: group === 'permission' ? key : item.permissionMode ?? null,
        modelMode: group === 'model' ? key : item.modelMode ?? null,
        effortLevel: group === 'effort' ? key : item.effortLevel ?? null,
      };
    });
    this.sessions = sessions;
  }

  private getSelectedSessionActivityText(): string {
    const session = this.getSelectedSession();
    if (!session) {
      return '最后活跃：会话已不存在';
    }
    if (session.thinking) {
      return '最后活跃：正在思考';
    }
    return `最后活跃：${this.formatRelativeTime(session.activeAt)}`;
  }

  private formatRelativeTime(timestamp: number): string {
    if (timestamp <= 0) {
      return '暂无记录';
    }
    const diffMs = Math.max(0, Date.now() - timestamp);
    const diffMinutes = Math.floor(diffMs / 60000);
    if (diffMinutes < 1) {
      return '刚刚';
    }
    if (diffMinutes < 60) {
      return `${diffMinutes} 分钟前`;
    }
    const diffHours = Math.floor(diffMinutes / 60);
    if (diffHours < 24) {
      return `${diffHours} 小时前`;
    }
    const diffDays = Math.floor(diffHours / 24);
    return `${diffDays} 天前`;
  }

  private normalizeOptionalText(value: string | undefined | null): string {
    return value ? value.trim() : '';
  }

  private trimTrailingSlash(value: string): string {
    let result = value;
    while (result.length > 1 && result.endsWith('/')) {
      result = result.slice(0, result.length - 1);
    }
    return result;
  }

  private formatPathTail(path: string): string {
    const prefix = path.startsWith('~/') ? '~/' : path.startsWith('/') ? '/' : '';
    const body = prefix.length > 0 ? path.slice(prefix.length) : path;
    const parts = body.split('/').filter((part: string): boolean => part.length > 0);
    if (parts.length <= 3) {
      return path;
    }
    const tail = `${parts[parts.length - 2]}/${parts[parts.length - 1]}`;
    if (prefix === '~/') {
      return `~/.../${tail}`;
    }
    if (prefix === '/') {
      return `/.../${tail}`;
    }
    return `.../${tail}`;
  }

  private getSelectedMachineDetail(): HappyMachine | null {
    if (this.selectedMachineDetailId.length === 0) {
      return null;
    }
    return this.findMachineInList(this.machines, this.selectedMachineDetailId);
  }

  private getSelectedMachineTitle(): string {
    const machine = this.getSelectedMachineDetail();
    return machine ? getMachineTitle(machine) : '设备详情';
  }

  private getSelectedMachineSubtitle(): string {
    const machine = this.getSelectedMachineDetail();
    return machine ? getMachineSubtitle(machine) : '设备已不存在';
  }

  private dropSelectedMachineIfMissing(): void {
    if (this.selectedMachineDetailId.length === 0) {
      return;
    }
    if (!this.getSelectedMachineDetail()) {
      this.closeMachineDetail();
      this.syncStatus = '当前设备已删除，已返回设备列表';
    }
  }

  private prepareNewSessionForMachine(machine: HappyMachine): void {
    this.selectedMachineId = machine.id;
    this.ensureSelectedNewSessionAgent(machine);
    this.newSessionPath = this.getMachineDefaultDirectory(machine);
    this.newSessionStatus = '';
    this.clearNewSessionDirectoryApproval();
    this.closeDirectoryPicker();
    this.showNewSessionPanel = true;
    this.activeTab = TAB_TERMINAL;
    this.closeMachineDetail();
    if (this.getSelectedNewSessionAgentKeyForMachine(machine) === 'codex') {
      this.refreshCodexThreads(machine);
    }
  }

  private resolveMachineSpawnPath(path: string, machine: HappyMachine): string {
    const trimmed = path.trim();
    const homeDir = this.getMachinePathHomeDir(machine);
    if (homeDir.length === 0 || !trimmed.startsWith('~')) {
      return trimmed;
    }
    const normalizedHome = this.trimTrailingSlash(homeDir);
    if (trimmed === '~') {
      return normalizedHome;
    }
    if (trimmed.startsWith('~/')) {
      return `${normalizedHome}/${trimmed.slice(2)}`;
    }
    return trimmed;
  }

  private canResolveMachinePath(path: string, machine: HappyMachine): boolean {
    return !this.isHomeRelativePath(path) || this.getMachinePathHomeDir(machine).length > 0;
  }

  private isHomeRelativePath(path: string): boolean {
    const trimmed = path.trim();
    return trimmed === '~' || trimmed.startsWith('~/');
  }

  private getMachinePathHomeDir(machine: HappyMachine): string {
    const homeDir = this.trimTrailingSlash(this.normalizeOptionalText(machine.metadata?.homeDir));
    if (homeDir.length > 0) {
      return homeDir;
    }
    const happyHomeDir = this.trimTrailingSlash(this.normalizeOptionalText(machine.metadata?.happyHomeDir));
    if (happyHomeDir.endsWith('/.happy')) {
      return this.trimTrailingSlash(happyHomeDir.slice(0, happyHomeDir.length - '/.happy'.length));
    }
    return '';
  }

  private formatMachinePathForInput(path: string, machine: HappyMachine): string {
    const normalizedPath = this.normalizeOptionalText(path);
    const homeDir = this.getMachinePathHomeDir(machine);
    if (homeDir.length === 0) {
      return normalizedPath;
    }
    if (normalizedPath === homeDir) {
      return '~';
    }
    if (normalizedPath.startsWith(`${homeDir}/`)) {
      return `~/${normalizedPath.slice(homeDir.length + 1)}`;
    }
    return normalizedPath;
  }

  private formatMachinePathForDisplay(path: string, machine: HappyMachine): string {
    return this.formatPathTail(this.formatMachinePathForInput(path, machine));
  }

  private isNewSessionPathSelected(path: string, machine: HappyMachine): boolean {
    const selected = this.resolveMachineSpawnPath(this.newSessionPath, machine);
    const pathValue = this.resolveMachineSpawnPath(this.formatMachinePathForInput(path, machine), machine);
    return selected === pathValue;
  }

  private getMachineRecentPathCount(machineId: string): number {
    return this.getMachineRecentPaths(machineId, 0).length;
  }

  private getMachineRecentPathsToShow(machineId: string): string[] {
    return this.getMachineRecentPaths(machineId, this.machineDetailShowAllPaths ? 0 : 5);
  }

  private getMachineRecentPaths(machineId: string, limit: number): string[] {
    const sorted = this.sessions.slice().sort((a: HappySession, b: HappySession): number => b.updatedAt - a.updatedAt);
    const paths: string[] = [];
    for (const session of sorted) {
      if (session.metadata?.machineId !== machineId) {
        continue;
      }
      const path = this.normalizeOptionalText(session.metadata?.path);
      if (path.length === 0 || this.stringArrayContains(paths, path)) {
        continue;
      }
      paths.push(path);
      if (limit > 0 && paths.length >= limit) {
        break;
      }
    }
    return paths;
  }

  private stringArrayContains(values: string[], target: string): boolean {
    for (const value of values) {
      if (value === target) {
        return true;
      }
    }
    return false;
  }

  private getMachineConfirmLabel(machine: HappyMachine): string {
    const shortId = this.getMachineShortId(machine.id);
    const title = getMachineTitle(machine);
    if (title === machine.id || title === shortId) {
      return shortId;
    }
    return `${title}（${shortId}）`;
  }

  private getMachineShortId(machineId: string): string {
    if (machineId.length <= 8) {
      return machineId;
    }
    return machineId.slice(0, 8);
  }

  private trimIdentifier(value: string): string {
    if (value.length <= 12) {
      return value;
    }
    return `${value.slice(0, 8)}...${value.slice(value.length - 4)}`;
  }

  private canStopMachineDaemon(machine: HappyMachine): boolean {
    return this.isAuthenticated
      && !this.isStoppingMachineDaemon
      && this.getMachineDaemonStatus(machine) !== '已停止';
  }

  private getStopMachineDaemonButtonLabel(machine: HappyMachine): string {
    if (this.isStoppingMachineDaemon) {
      return '停止中';
    }
    if (this.isMachineStopConfirmPending(machine)) {
      return '确认停止守护进程';
    }
    return '停止守护进程';
  }

  private submitStopMachineDaemon(machine: HappyMachine): void {
    if (!this.canStopMachineDaemon(machine)) {
      return;
    }
    if (!this.isMachineStopConfirmPending(machine)) {
      this.requestMachineStopConfirmation(machine);
      return;
    }
    this.invalidateMachineStopConfirmation();
    this.isStoppingMachineDaemon = true;
    this.machineDaemonActionStatus = '正在发送停止守护进程请求...';
    this.submitStopMachineDaemonAsync(machine);
  }

  private async submitStopMachineDaemonAsync(machine: HappyMachine): Promise<void> {
    try {
      const result: StopMachineDaemonResult = await stopMachineDaemon(this.getAbilityContext(), this.serverUrl, machine);
      this.machineDaemonActionStatus = result.message.length > 0 ? result.message : '停止守护进程请求已发送';
      this.refreshControlPlaneData();
    } catch (error) {
      console.error(`停止守护进程失败：${error}`);
      this.machineDaemonActionStatus = `停止失败：${this.toUserError(error, '请确认终端在线后重试')}`;
    } finally {
      this.isStoppingMachineDaemon = false;
    }
  }

  private isMachineStopConfirmPending(machine: HappyMachine): boolean {
    return this.machineStopConfirmMachineId === machine.id;
  }

  private requestMachineStopConfirmation(machine: HappyMachine): void {
    const token = this.machineStopConfirmToken + 1;
    this.machineStopConfirmToken = token;
    this.machineStopConfirmMachineId = machine.id;
    this.machineDaemonActionStatus =
      `再次点击确认停止 ${this.getMachineConfirmLabel(machine)}。当前会话会保留，需要在电脑端重启 happy daemon 才能恢复。`;
    setTimeout((): void => {
      if (this.machineStopConfirmToken === token && this.machineStopConfirmMachineId === machine.id) {
        this.machineStopConfirmMachineId = '';
        if (this.machineDaemonActionStatus.startsWith('再次点击确认停止')) {
          this.machineDaemonActionStatus = '';
        }
      }
    }, 8000);
  }

  private invalidateMachineStopConfirmation(): void {
    this.machineStopConfirmToken += 1;
    this.machineStopConfirmMachineId = '';
  }

  private canDeleteMachine(machine: HappyMachine): boolean {
    return this.isAuthenticated
      && !this.isDeletingMachine
      && this.selectedMachineDetailId === machine.id;
  }

  private getMachineDeleteWarning(machine: HappyMachine): string {
    const base = '从账号中移除此设备。会话历史会保留，但重新连接守护进程前无法再在此设备启动新会话。';
    if (machine.active) {
      return `${base} 当前设备在线，删除后需要重新关联才能恢复。`;
    }
    return base;
  }

  private getDeleteMachineButtonLabel(machine: HappyMachine): string {
    if (this.isDeletingMachine) {
      return '删除中';
    }
    if (this.isMachineDeleteConfirmPending(machine)) {
      return '确认删除设备';
    }
    return '删除设备';
  }

  private isMachineDeleteConfirmPending(machine: HappyMachine): boolean {
    return this.machineDeleteConfirmMachineId === machine.id;
  }

  private requestMachineDeleteConfirmation(machine: HappyMachine): void {
    const token = this.machineDeleteConfirmToken + 1;
    this.machineDeleteConfirmToken = token;
    this.machineDeleteConfirmMachineId = machine.id;
    this.machineDeleteStatus =
      `${MACHINE_DELETE_CONFIRM_MESSAGE}：${this.getMachineConfirmLabel(machine)}。会话历史会保留。`;
    setTimeout((): void => {
      if (this.machineDeleteConfirmToken === token && this.machineDeleteConfirmMachineId === machine.id) {
        this.machineDeleteConfirmMachineId = '';
        this.machineDeleteStatus = '';
      }
    }, 8000);
  }

  private invalidateMachineDeleteConfirmation(): void {
    this.machineDeleteConfirmToken += 1;
    this.machineDeleteConfirmMachineId = '';
  }

  private submitDeleteMachine(machine: HappyMachine): void {
    if (!this.canDeleteMachine(machine)) {
      return;
    }
    if (!this.isMachineDeleteConfirmPending(machine)) {
      this.requestMachineDeleteConfirmation(machine);
      return;
    }
    this.invalidateMachineDeleteConfirmation();
    this.isDeletingMachine = true;
    this.machineDeleteStatus = '正在删除设备...';
    this.submitDeleteMachineAsync(machine);
  }

  private async submitDeleteMachineAsync(machine: HappyMachine): Promise<void> {
    try {
      const result: MachineDeleteResult = await deleteMachine(this.getAbilityContext(), this.serverUrl, machine);
      this.markMachineDeletePending(machine.id);
      this.machines = this.machines.filter((item: HappyMachine): boolean => item.id !== machine.id);
      this.machineDeleteStatus = result.message.length > 0 ? result.message : '设备已删除';
      this.closeMachineDetail();
      this.syncStatus = '设备已删除，正在同步...';
      this.refreshControlPlaneData();
    } catch (error) {
      this.clearMachineDeletePending(machine.id);
      if (this.selectedMachineDetailId !== machine.id) {
        return;
      }
      console.error(`删除设备失败：${error}`);
      this.machineDeleteStatus = `删除失败：${this.toUserError(error, '请同步后重试')}`;
    } finally {
      if (this.selectedMachineDetailId === machine.id) {
        this.isDeletingMachine = false;
      }
    }
  }

  private getMachineDaemonRows(machine: HappyMachine): DetailRow[] {
    const rows: DetailRow[] = [];
    const daemonState = this.asRecord(machine.daemonState);
    const daemonStatus = this.getMachineDaemonStatus(machine);
    this.pushDetailRow(rows, '状态', daemonStatus, daemonStatus === '运行中' ? '#137333' : '#B06000');
    this.pushOptionalDetailRow(rows, '最后 PID', this.readRecordValue(daemonState, 'pid'), '', true);
    this.pushOptionalDetailRow(rows, '最后 HTTP 端口', this.readRecordValue(daemonState, 'httpPort'), '', true);
    this.pushOptionalDetailRow(rows, '启动时间', this.formatDetailTimestamp(this.readRecordNumber(daemonState, 'startTime')));
    this.pushOptionalDetailRow(rows, 'CLI 版本', this.readRecordValue(daemonState, 'startedWithCliVersion'));
    this.pushDetailRow(rows, '守护进程状态版本', `${machine.daemonStateVersion}`, '', true);
    return rows;
  }

  private getMachineAvailabilityRows(machine: HappyMachine): DetailRow[] {
    const rows: DetailRow[] = [];
    const availability = machine.metadata?.cliAvailability;
    if (!availability) {
      return rows;
    }
    this.pushDetailRow(rows, 'Claude', this.getAvailabilityLabel(availability.claude), availability.claude ? '#137333' : '#5F6368');
    this.pushDetailRow(rows, 'Codex', this.getAvailabilityLabel(availability.codex), availability.codex ? '#137333' : '#5F6368');
    this.pushDetailRow(rows, 'Gemini', this.getAvailabilityLabel(availability.gemini), availability.gemini ? '#137333' : '#5F6368');
    this.pushDetailRow(rows, 'OpenClaw', this.getAvailabilityLabel(availability.openclaw), availability.openclaw ? '#137333' : '#5F6368');
    this.pushOptionalDetailRow(rows, '最后检测', this.formatDetailTimestamp(availability.detectedAt));
    return rows;
  }

  private getMachineInfoRows(machine: HappyMachine): DetailRow[] {
    const rows: DetailRow[] = [];
    const metadata = machine.metadata;
    this.pushOptionalDetailRow(rows, '显示名称', metadata?.displayName);
    this.pushOptionalDetailRow(rows, '主机', metadata?.host);
    this.pushDetailRow(rows, '终端 ID', machine.id, '', true);
    this.pushOptionalDetailRow(rows, '用户名', metadata?.username);
    this.pushOptionalDetailRow(rows, '主目录', metadata?.homeDir, '', true);
    this.pushOptionalDetailRow(rows, 'Happy 目录', metadata?.happyHomeDir, '', true);
    this.pushOptionalDetailRow(rows, '平台', metadata?.platform);
    this.pushOptionalDetailRow(rows, '架构', metadata?.arch);
    this.pushOptionalDetailRow(rows, 'Happy CLI', metadata?.happyCliVersion);
    this.pushOptionalDetailRow(rows, '最后在线', this.formatDetailTimestamp(machine.activeAt));
    this.pushDetailRow(rows, '元数据版本', `${machine.metadataVersion}`, '', true);
    this.pushOptionalDetailRow(rows, '创建时间', this.formatDetailTimestamp(machine.createdAt));
    this.pushOptionalDetailRow(rows, '更新时间', this.formatDetailTimestamp(machine.updatedAt));
    return rows;
  }

  private getMachineDaemonStatus(machine: HappyMachine): string {
    if (this.normalizeOptionalText(machine.metadata?.daemonLastKnownStatus) === 'shutting-down') {
      return '已停止';
    }
    return machine.active ? '运行中' : '已停止';
  }

  private getMachineRecentSessions(machineId: string): HappySession[] {
    const result: HappySession[] = [];
    for (const session of this.sessions) {
      if (session.metadata?.machineId === machineId && !this.shouldHideSessionFromList(session)) {
        result.push(session);
      }
    }
    result.sort((a: HappySession, b: HappySession): number => b.updatedAt - a.updatedAt);
    return result.slice(0, 5);
  }

  private pushDetailRow(rows: DetailRow[], label: string, value: string, tone: string = '', monospace: boolean = false): void {
    rows.push({ label, value, tone, monospace });
  }

  private pushOptionalDetailRow(
    rows: DetailRow[],
    label: string,
    value: string | undefined,
    tone: string = '',
    monospace: boolean = false,
  ): void {
    const normalized = this.normalizeOptionalText(value);
    if (normalized.length > 0) {
      this.pushDetailRow(rows, label, normalized, tone, monospace);
    }
  }

  private getAvailabilityLabel(value: boolean | undefined): string {
    return value === true ? '已安装' : '未检测到';
  }

  private asRecord(value: Object | null): Record<string, Object> | null {
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      return null;
    }
    return value as Record<string, Object>;
  }

  private readRecordValue(record: Record<string, Object> | null, key: string): string | undefined {
    if (!record) {
      return undefined;
    }
    const value = record[key];
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return `${value}`;
    }
    return undefined;
  }

  private readRecordNumber(record: Record<string, Object> | null, key: string): number | undefined {
    if (!record) {
      return undefined;
    }
    const value = record[key];
    return typeof value === 'number' ? value : undefined;
  }

  private formatDetailTimestamp(timestamp: number | undefined): string | undefined {
    if (!timestamp || timestamp <= 0) {
      return undefined;
    }
    return `${this.formatRelativeTime(timestamp)} · ${new Date(timestamp).toLocaleString()}`;
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
        effortLevel: session.effortLevel ?? null,
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
    const session = this.getSelectedSession();
    if (!session) {
      this.closeSessionDetail();
      this.syncStatus = '当前会话已删除，已返回会话列表';
      return;
    }
    if (this.shouldHideSessionFromList(session)) {
      this.closeSessionDetail();
      this.syncStatus = '当前会话已归档，已返回会话列表';
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
    return this.isLoadingState || this.isValidating || this.authAction.length > 0 || this.isSpawningSession;
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

  private shouldShowControlPlaneRefresh(): boolean {
    return this.activeTab === TAB_TERMINAL || this.activeTab === TAB_SETTINGS;
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

  private getHeaderStatusLabel(): string {
    if (this.isLoadingState) {
      return '连接中';
    }
    if (!this.isAuthenticated) {
      return '断开';
    }
    if (this.realtimeStatus.indexOf('已连接') >= 0) {
      return '已连接';
    }
    if (this.realtimeStatus.indexOf('连接中') >= 0 || this.realtimeStatus.indexOf('握手中') >= 0 || this.realtimeStatus.indexOf('重连') >= 0) {
      return '连接中';
    }
    return '断开';
  }

  private getHeaderStatusColor(): string {
    const label = this.getHeaderStatusLabel();
    if (label === '已连接') {
      return '#137333';
    }
    if (label === '连接中') {
      return '#B06000';
    }
    return '#5F6368';
  }

  private getHeaderStatusBackgroundColor(): string {
    const label = this.getHeaderStatusLabel();
    if (label === '已连接') {
      return '#E6F4EA';
    }
    if (label === '连接中') {
      return '#FFF7E6';
    }
    return '#EEF3F8';
  }

  private getComposerTextAreaHeight(): number {
    if (this.messageDraft.length === 0) {
      return 46;
    }

    const lines = this.messageDraft.split('\n');
    let visibleLines = 0;
    lines.forEach((line: string) => {
      visibleLines += Math.max(1, Math.ceil(line.length / 18));
    });

    return Math.min(88, 46 + Math.max(0, visibleLines - 2) * 18);
  }

  private getAbilityContext(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }
}
