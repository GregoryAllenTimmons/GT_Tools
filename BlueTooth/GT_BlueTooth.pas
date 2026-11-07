unit GT_BlueTooth;

{===============================================================================
  GT_BlueTooth - non-visual component wrapping the GT BlueTooth library
  Author: Greg Timmons

  Drop a TGT_BlueTooth on a form (palette tab "GT Tools") and:

    1. request the Android Bluetooth permissions yourself (BLUETOOTH_CONNECT
       and BLUETOOTH_SCAN on Android 12+), exactly as with TBluetooth;
    2. GetPairedDevices, then Listen on one device and Connect on the other;
    3. SendText / SendPing / SendFile; watch the On... events.

  Everything underneath is the three library units (Protocol, Link,
  Session), which can still be used on their own without this component.

  All events fire on the main thread.
  All naming follows Greg's Law conventions.
===============================================================================}

interface

uses
  System.SysUtils, System.Classes, System.Bluetooth,
  GT_BlueToothLink, GT_BlueToothSession;

type
  { ========================================================================== }
  { TGT_BlueTooth                                                              }
  { ========================================================================== }
  TGT_BlueTooth = class(TComponent)
  private
    FoLink: TGT_BlueToothLink;          // owned
    FoSession: TGT_BlueToothSession;    // owned

    { Design-time settings - stored here, pushed into the library objects }
    FiChunkSize: Integer;
    FiAckWindow: Integer;
    FiReplyTimeoutMs: Integer;
    FiReadPollMs: Integer;
    FbSecureSocket: Boolean;
    FbLogEveryRead: Boolean;
    FsReceiveFolder: string;

    { Events }
    FOnLog: TGT_SessionLogEvent;
    FOnStateChanged: TGT_LinkStateEvent;
    FOnTextReceived: TGT_SessionTextEvent;
    FOnPingResult: TGT_SessionPingEvent;
    FOnTransferProgress: TGT_SessionProgressEvent;
    FOnTransferFinished: TGT_SessionFinishedEvent;

    { Handlers that forward the library events as this component's events }
    procedure Link_OnLog(Sender: TObject; const s_Message: string);
    procedure Link_OnStateChanged(Sender: TObject; const e_NewState: TGT_LinkState);
    procedure Session_OnLog(Sender: TObject; const s_Message: string);
    procedure Session_OnTextReceived(Sender: TObject; const s_Text: string);
    procedure Session_OnPingResult(Sender: TObject; const i_PayloadSize: Integer;
      const i64_RoundTripMs: Int64; const b_PayloadIntact: Boolean);
    procedure Session_OnTransferProgress(Sender: TObject;
      const e_Direction: TGT_TransferDirection;
      const i64_BytesDone: Int64; const i64_BytesTotal: Int64);
    procedure Session_OnTransferFinished(Sender: TObject;
      const e_Direction: TGT_TransferDirection; const s_FilePath: string;
      const b_Success: Boolean; const s_Detail: string);

    procedure DoApplySettings;

    { Property accessors }
    function GetState: TGT_LinkState;
    function GetPeerName: string;
    function GetIsSending: Boolean;
    function GetIsReceiving: Boolean;
    function GetReceiveFolder: string;
    procedure SetReceiveFolder(const s_Value: string);
    procedure SetChunkSize(const i_Value: Integer);
    procedure SetAckWindow(const i_Value: Integer);
    procedure SetReplyTimeoutMs(const i_Value: Integer);
    procedure SetReadPollMs(const i_Value: Integer);
    procedure SetSecureSocket(const b_Value: Boolean);
    procedure SetLogEveryRead(const b_Value: Boolean);
  public
    constructor Create(o_Owner: TComponent); override;
    destructor Destroy; override;

    { Adapter / devices }
    function IsBluetoothReady: Boolean;
    function LocalAdapterName: string;
    function GetPairedDevices: TBluetoothDeviceList;

    { Connection - main thread only }
    procedure Listen;
    procedure Connect(const o_Device: TBluetoothDevice);
    procedure Disconnect;

    { Sending - main thread only }
    procedure SendText(const s_Text: string);
    procedure SendPing(const i_PayloadSize: Integer);
    procedure SendFile(const s_FilePath: string);
    procedure CancelTransfer;

    { Statistics on the raw socket reads }
    procedure ResetStatistics;
    function StatisticsText: string;

    class function StateName(const e_State: TGT_LinkState): string;

    { Read-only state }
    property State: TGT_LinkState read GetState;
    property PeerName: string read GetPeerName;
    property IsSending: Boolean read GetIsSending;
    property IsReceiving: Boolean read GetIsReceiving;

    { The library objects, for anything the component does not expose }
    property Link: TGT_BlueToothLink read FoLink;
    property Session: TGT_BlueToothSession read FoSession;

  published
    { Transfer settings }
    property ChunkSize: Integer read FiChunkSize write SetChunkSize
      default DEFAULT_CHUNK_SIZE;
    property AckWindow: Integer read FiAckWindow write SetAckWindow
      default DEFAULT_ACK_WINDOW;
    property ReplyTimeoutMs: Integer read FiReplyTimeoutMs write SetReplyTimeoutMs
      default DEFAULT_REPLY_TIMEOUT_MS;
    property ReadPollMs: Integer read FiReadPollMs write SetReadPollMs
      default DEFAULT_READ_POLL_MS;
    property SecureSocket: Boolean read FbSecureSocket write SetSecureSocket
      default True;
    property LogEveryRead: Boolean read FbLogEveryRead write SetLogEveryRead
      default False;

    { Empty = platform default (Download\GTBTReceived on Android,
      Documents\GTBTReceived on Windows) }
    property ReceiveFolder: string read GetReceiveFolder write SetReceiveFolder;

    { Events - all on the main thread }
    property OnLog: TGT_SessionLogEvent read FOnLog write FOnLog;
    property OnStateChanged: TGT_LinkStateEvent read FOnStateChanged
      write FOnStateChanged;
    property OnTextReceived: TGT_SessionTextEvent read FOnTextReceived
      write FOnTextReceived;
    property OnPingResult: TGT_SessionPingEvent read FOnPingResult
      write FOnPingResult;
    property OnTransferProgress: TGT_SessionProgressEvent read FOnTransferProgress
      write FOnTransferProgress;
    property OnTransferFinished: TGT_SessionFinishedEvent read FOnTransferFinished
      write FOnTransferFinished;
  end;

implementation

{ ============================================================================ }
{ CONSTRUCTOR / DESTRUCTOR                                                     }
{ ============================================================================ }

constructor TGT_BlueTooth.Create(o_Owner: TComponent);
begin
  inherited Create(o_Owner);

  Self.FiChunkSize := DEFAULT_CHUNK_SIZE;
  Self.FiAckWindow := DEFAULT_ACK_WINDOW;
  Self.FiReplyTimeoutMs := DEFAULT_REPLY_TIMEOUT_MS;
  Self.FiReadPollMs := DEFAULT_READ_POLL_MS;
  Self.FbSecureSocket := True;
  Self.FbLogEveryRead := False;
  Self.FsReceiveFolder := '';

  // The library objects are created at design time too, but neither touches
  // the Bluetooth manager until Listen / Connect / GetPairedDevices is called,
  // so this is safe inside the IDE.
  Self.FoLink := TGT_BlueToothLink.Create;
  Self.FoLink.OnLog := Self.Link_OnLog;
  Self.FoLink.OnStateChanged := Self.Link_OnStateChanged;

  Self.FoSession := TGT_BlueToothSession.Create(Self.FoLink);
  Self.FoSession.OnLog := Self.Session_OnLog;
  Self.FoSession.OnTextReceived := Self.Session_OnTextReceived;
  Self.FoSession.OnPingResult := Self.Session_OnPingResult;
  Self.FoSession.OnTransferProgress := Self.Session_OnTransferProgress;
  Self.FoSession.OnTransferFinished := Self.Session_OnTransferFinished;

  Self.DoApplySettings;
end;

destructor TGT_BlueTooth.Destroy;
begin
  // Order matters: close the link, free the session, then free the link
  if Assigned(Self.FoLink) then
  begin
    try
      Self.FoLink.Disconnect;
    except
      // Shutting down anyway
    end;
  end;

  FreeAndNil(Self.FoSession);
  FreeAndNil(Self.FoLink);

  inherited Destroy;
end;

{ ============================================================================ }
{ SETTINGS                                                                     }
{ ============================================================================ }

procedure TGT_BlueTooth.DoApplySettings;
begin
  if not Assigned(Self.FoLink) then
    Exit;

  Self.FoLink.SecureSockets := Self.FbSecureSocket;
  Self.FoLink.LogEveryRead := Self.FbLogEveryRead;
  Self.FoLink.ReadPollMs := Self.FiReadPollMs;

  Self.FoSession.ChunkSize := Self.FiChunkSize;
  Self.FoSession.AckWindow := Self.FiAckWindow;
  Self.FoSession.ReplyTimeoutMs := Self.FiReplyTimeoutMs;

  if Self.FsReceiveFolder <> '' then
    Self.FoSession.ReceiveFolder := Self.FsReceiveFolder;

  // Read back the clamped values so the Object Inspector shows the truth
  Self.FiChunkSize := Self.FoSession.ChunkSize;
  Self.FiAckWindow := Self.FoSession.AckWindow;
end;

procedure TGT_BlueTooth.SetChunkSize(const i_Value: Integer);
begin
  Self.FiChunkSize := i_Value;
  Self.DoApplySettings;
end;

procedure TGT_BlueTooth.SetAckWindow(const i_Value: Integer);
begin
  Self.FiAckWindow := i_Value;
  Self.DoApplySettings;
end;

procedure TGT_BlueTooth.SetReplyTimeoutMs(const i_Value: Integer);
begin
  Self.FiReplyTimeoutMs := i_Value;
  Self.DoApplySettings;
end;

procedure TGT_BlueTooth.SetReadPollMs(const i_Value: Integer);
begin
  Self.FiReadPollMs := i_Value;
  Self.DoApplySettings;
end;

procedure TGT_BlueTooth.SetSecureSocket(const b_Value: Boolean);
begin
  Self.FbSecureSocket := b_Value;
  Self.DoApplySettings;
end;

procedure TGT_BlueTooth.SetLogEveryRead(const b_Value: Boolean);
begin
  Self.FbLogEveryRead := b_Value;
  Self.DoApplySettings;
end;

function TGT_BlueTooth.GetReceiveFolder: string;
begin
  // Published value: empty means "platform default". The real folder in use
  // is Session.ReceiveFolder.
  Result := Self.FsReceiveFolder;
end;

procedure TGT_BlueTooth.SetReceiveFolder(const s_Value: string);
begin
  Self.FsReceiveFolder := s_Value;
  Self.DoApplySettings;
end;

{ ============================================================================ }
{ STATE                                                                       }
{ ============================================================================ }

function TGT_BlueTooth.GetState: TGT_LinkState;
begin
  Result := Self.FoLink.State;
end;

function TGT_BlueTooth.GetPeerName: string;
begin
  Result := Self.FoLink.PeerName;
end;

function TGT_BlueTooth.GetIsSending: Boolean;
begin
  Result := Self.FoSession.IsSending;
end;

function TGT_BlueTooth.GetIsReceiving: Boolean;
begin
  Result := Self.FoSession.IsReceiving;
end;

class function TGT_BlueTooth.StateName(const e_State: TGT_LinkState): string;
begin
  Result := TGT_BlueToothLink.StateName(e_State);
end;

{ ============================================================================ }
{ ADAPTER / DEVICES                                                            }
{ ============================================================================ }

function TGT_BlueTooth.IsBluetoothReady: Boolean;
begin
  Result := Self.FoLink.IsBluetoothReady;
end;

function TGT_BlueTooth.LocalAdapterName: string;
begin
  Result := Self.FoLink.LocalAdapterName;
end;

function TGT_BlueTooth.GetPairedDevices: TBluetoothDeviceList;
begin
  Result := Self.FoLink.GetPairedDevices;
end;

{ ============================================================================ }
{ CONNECTION                                                                   }
{ ============================================================================ }

procedure TGT_BlueTooth.Listen;
begin
  Self.DoApplySettings;
  Self.FoLink.Listen;
end;

procedure TGT_BlueTooth.Connect(const o_Device: TBluetoothDevice);
begin
  Self.DoApplySettings;
  Self.FoLink.Connect(o_Device);
end;

procedure TGT_BlueTooth.Disconnect;
begin
  Self.FoLink.Disconnect;
end;

{ ============================================================================ }
{ SENDING                                                                      }
{ ============================================================================ }

procedure TGT_BlueTooth.SendText(const s_Text: string);
begin
  Self.FoSession.SendText(s_Text);
end;

procedure TGT_BlueTooth.SendPing(const i_PayloadSize: Integer);
begin
  Self.FoSession.SendPing(i_PayloadSize);
end;

procedure TGT_BlueTooth.SendFile(const s_FilePath: string);
begin
  Self.DoApplySettings;
  Self.FoSession.SendFile(s_FilePath);
end;

procedure TGT_BlueTooth.CancelTransfer;
begin
  Self.FoSession.CancelTransfer;
end;

{ ============================================================================ }
{ STATISTICS                                                                   }
{ ============================================================================ }

procedure TGT_BlueTooth.ResetStatistics;
begin
  Self.FoLink.ResetStatistics;
end;

function TGT_BlueTooth.StatisticsText: string;
begin
  Result := Self.FoLink.StatisticsText;
end;

{ ============================================================================ }
{ EVENT FORWARDING                                                             }
{ ============================================================================ }

procedure TGT_BlueTooth.Link_OnLog(Sender: TObject; const s_Message: string);
begin
  if Assigned(Self.FOnLog) then
    Self.FOnLog(Self, '[link] ' + s_Message);
end;

procedure TGT_BlueTooth.Link_OnStateChanged(Sender: TObject;
  const e_NewState: TGT_LinkState);
begin
  if Assigned(Self.FOnStateChanged) then
    Self.FOnStateChanged(Self, e_NewState);
end;

procedure TGT_BlueTooth.Session_OnLog(Sender: TObject; const s_Message: string);
begin
  if Assigned(Self.FOnLog) then
    Self.FOnLog(Self, '[session] ' + s_Message);
end;

procedure TGT_BlueTooth.Session_OnTextReceived(Sender: TObject;
  const s_Text: string);
begin
  if Assigned(Self.FOnTextReceived) then
    Self.FOnTextReceived(Self, s_Text);
end;

procedure TGT_BlueTooth.Session_OnPingResult(Sender: TObject;
  const i_PayloadSize: Integer; const i64_RoundTripMs: Int64;
  const b_PayloadIntact: Boolean);
begin
  if Assigned(Self.FOnPingResult) then
    Self.FOnPingResult(Self, i_PayloadSize, i64_RoundTripMs, b_PayloadIntact);
end;

procedure TGT_BlueTooth.Session_OnTransferProgress(Sender: TObject;
  const e_Direction: TGT_TransferDirection;
  const i64_BytesDone: Int64; const i64_BytesTotal: Int64);
begin
  if Assigned(Self.FOnTransferProgress) then
    Self.FOnTransferProgress(Self, e_Direction, i64_BytesDone, i64_BytesTotal);
end;

procedure TGT_BlueTooth.Session_OnTransferFinished(Sender: TObject;
  const e_Direction: TGT_TransferDirection; const s_FilePath: string;
  const b_Success: Boolean; const s_Detail: string);
begin
  if Assigned(Self.FOnTransferFinished) then
    Self.FOnTransferFinished(Self, e_Direction, s_FilePath, b_Success, s_Detail);
end;

end.
