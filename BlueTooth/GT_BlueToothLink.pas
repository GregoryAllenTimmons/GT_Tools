unit GT_BlueToothLink;

{===============================================================================
  GT_BlueToothLink - one open Classic Bluetooth (RFCOMM) connection
  Author: Greg Timmons

  Plain library class (not a component). Create it in code, free it yourself.

  What it does:
    - lists paired devices
    - Listen  : publishes the GTBT service and waits for one incoming connection
    - Connect : connects to a paired device that is listening
    - keeps the socket OPEN and runs one worker thread that reads from it
    - SendBytes : thread-safe raw send
    - counts every ReceiveData call (how many, smallest, largest) so the
      undocumented read behaviour of each platform can be measured

  What it does NOT do: framing, files, protocol. That is GT_BlueToothSession.

  Threading rules:
    - Listen / Connect / Disconnect / Free : call from the MAIN thread only.
    - OnLog / OnStateChanged              : always fired on the MAIN thread.
    - ProcLinkOpened / ProcDataReceived / ProcLinkClosed
                                           : called on the WORKER thread.
    - RequestClose                        : safe from any thread (including
                                             from inside the Proc callbacks).

  All naming follows Greg's Law conventions.
===============================================================================}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Diagnostics,
  System.Bluetooth;

const
  { Service identification - both sides must use the same UUID }
  GTBT_SERVICE_NAME        = 'GTBT Link';
  GTBT_SERVICE_UUID_STRING = '{E8A4F7B2-3C61-4D8E-A729-5B1C6E4D3A20}';

  { Polling intervals }
  DEFAULT_READ_POLL_MS     = 500;    // how long one ReceiveData call may wait
  DEFAULT_ACCEPT_POLL_MS   = 1000;   // how long one Accept call may wait

  { "ReceiveData came back empty almost instantly" detection }
  FAST_EMPTY_READ_MS       = 20;     // faster than this counts as "instant"
  FAST_EMPTY_READ_LIMIT    = 50;     // this many in a row is worth reporting

type
  EGT_BlueToothLinkError = class(Exception);

  TGT_LinkState = (lsIdle, lsListening, lsConnecting, lsConnected);

  { Main-thread events }
  TGT_LinkLogEvent = procedure(Sender: TObject;
    const s_Message: string) of object;
  TGT_LinkStateEvent = procedure(Sender: TObject;
    const e_NewState: TGT_LinkState) of object;

  { Worker-thread callbacks }
  TGT_LinkBytesProc = reference to procedure(const arr_Data: TBytes);
  TGT_LinkNotifyProc = reference to procedure;

  { ========================================================================== }
  { TGT_BlueToothLink                                                          }
  { ========================================================================== }
  TGT_BlueToothLink = class(TObject)
  private
    { Bluetooth objects }
    FoManager: TBluetoothManager;             // singleton - not owned
    FoServerSocket: TBluetoothServerSocket;   // owned
    FoSocket: TBluetoothSocket;               // owned

    { Threading }
    FthrWorker: TThread;
    FcsSend: TCriticalSection;
    FbStopRequested: Boolean;
    FbDestroying: Boolean;

    { State }
    FeState: TGT_LinkState;
    FsPeerName: string;
    FguidServiceUUID: TGUID;

    { Configuration }
    FiReadPollMs: Integer;
    FiAcceptPollMs: Integer;
    FbSecureSockets: Boolean;
    FbLogEveryRead: Boolean;
    FbCloseOnFastEmptyReads: Boolean;

    { Statistics }
    FiReadCallCount: Integer;
    FiEmptyReadCount: Integer;
    FiSmallestRead: Integer;
    FiLargestRead: Integer;
    Fi64BytesReceived: Int64;
    Fi64BytesSent: Int64;

    { Worker-thread callbacks }
    FProcLinkOpened: TGT_LinkNotifyProc;
    FProcDataReceived: TGT_LinkBytesProc;
    FProcLinkClosed: TGT_LinkNotifyProc;

    { Main-thread events }
    FOnLog: TGT_LinkLogEvent;
    FOnStateChanged: TGT_LinkStateEvent;

    function EnsureManager: TBluetoothManager;
    procedure QueueDoLog(const s_Message: string);
    procedure DoSetState(const e_NewState: TGT_LinkState);

    procedure DoStartWorker(const o_Device: TBluetoothDevice);
    procedure DoStopWorker;
    procedure DoWorkerExecute(const o_Device: TBluetoothDevice);
    procedure DoAcceptLoop;
    procedure DoReadLoop;
    procedure DoCloseSockets;
    function DoSocketModeText: string;
  public
    constructor Create;
    destructor Destroy; override;

    { Adapter / devices }
    function IsBluetoothReady: Boolean;
    function LocalAdapterName: string;
    function GetPairedDevices: TBluetoothDeviceList;

    { Connection - main thread only }
    procedure Listen;
    procedure Connect(const o_Device: TBluetoothDevice);
    procedure Disconnect;

    { Safe from any thread }
    procedure RequestClose;
    procedure SendBytes(const arr_Data: TBytes);

    { Statistics }
    procedure ResetStatistics;
    function StatisticsText: string;

    class function StateName(const e_State: TGT_LinkState): string;

    property State: TGT_LinkState read FeState;
    property PeerName: string read FsPeerName;

    { Configuration - set while idle }
    property ReadPollMs: Integer read FiReadPollMs write FiReadPollMs;
    property AcceptPollMs: Integer read FiAcceptPollMs write FiAcceptPollMs;
    property SecureSockets: Boolean read FbSecureSockets write FbSecureSockets;
    property LogEveryRead: Boolean read FbLogEveryRead write FbLogEveryRead;
    property CloseOnFastEmptyReads: Boolean read FbCloseOnFastEmptyReads
      write FbCloseOnFastEmptyReads;

    { Worker-thread callbacks - assigned by the session layer }
    property ProcLinkOpened: TGT_LinkNotifyProc read FProcLinkOpened
      write FProcLinkOpened;
    property ProcDataReceived: TGT_LinkBytesProc read FProcDataReceived
      write FProcDataReceived;
    property ProcLinkClosed: TGT_LinkNotifyProc read FProcLinkClosed
      write FProcLinkClosed;

    { Main-thread events }
    property OnLog: TGT_LinkLogEvent read FOnLog write FOnLog;
    property OnStateChanged: TGT_LinkStateEvent read FOnStateChanged
      write FOnStateChanged;
  end;

implementation

{ ============================================================================ }
{ CONSTRUCTOR / DESTRUCTOR                                                     }
{ ============================================================================ }

constructor TGT_BlueToothLink.Create;
begin
  inherited Create;

  // The Bluetooth manager is NOT touched here. On Android 12+ it must not be
  // used until the runtime permissions have been granted.
  Self.FoManager := nil;
  Self.FoServerSocket := nil;
  Self.FoSocket := nil;
  Self.FthrWorker := nil;

  Self.FcsSend := TCriticalSection.Create;
  Self.FguidServiceUUID := StringToGUID(GTBT_SERVICE_UUID_STRING);

  Self.FeState := lsIdle;
  Self.FsPeerName := '';
  Self.FbStopRequested := False;
  Self.FbDestroying := False;

  Self.FiReadPollMs := DEFAULT_READ_POLL_MS;
  Self.FiAcceptPollMs := DEFAULT_ACCEPT_POLL_MS;
  Self.FbSecureSockets := False;
  Self.FbLogEveryRead := False;
  Self.FbCloseOnFastEmptyReads := False;

  Self.ResetStatistics;
end;

destructor TGT_BlueToothLink.Destroy;
begin
  // From here on every queued event becomes a no-op
  Self.FbDestroying := True;

  Self.DoStopWorker;
  Self.DoCloseSockets;

  // Flush anything the worker queued for the main thread while this object
  // is still alive, so no queued closure can run against freed memory.
  if TThread.CurrentThread.ThreadID = MainThreadID then
    CheckSynchronize;

  FreeAndNil(Self.FcsSend);

  // Do NOT free FoManager - it is a singleton
  inherited Destroy;
end;

{ ============================================================================ }
{ MAIN-THREAD NOTIFICATION                                                     }
{ ============================================================================ }

procedure TGT_BlueToothLink.QueueDoLog(const s_Message: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      if (not Self.FbDestroying) and Assigned(Self.FOnLog) then
        Self.FOnLog(Self, s_Message);
    end);
end;

procedure TGT_BlueToothLink.DoSetState(const e_NewState: TGT_LinkState);
begin
  Self.FeState := e_NewState;

  TThread.Queue(nil,
    procedure
    begin
      if (not Self.FbDestroying) and Assigned(Self.FOnStateChanged) then
        Self.FOnStateChanged(Self, e_NewState);
    end);
end;

class function TGT_BlueToothLink.StateName(const e_State: TGT_LinkState): string;
begin
  case e_State of
    lsIdle:       Result := 'Idle';
    lsListening:  Result := 'Listening';
    lsConnecting: Result := 'Connecting';
    lsConnected:  Result := 'Connected';
  else
    Result := 'Unknown';
  end;
end;

function TGT_BlueToothLink.DoSocketModeText: string;
begin
  if Self.FbSecureSockets then
    Result := 'SECURE'
  else
    Result := 'insecure';
end;

{ ============================================================================ }
{ ADAPTER / DEVICES                                                            }
{ ============================================================================ }

function TGT_BlueToothLink.EnsureManager: TBluetoothManager;
begin
  if not Assigned(Self.FoManager) then
    Self.FoManager := TBluetoothManager.Current;
  Result := Self.FoManager;
end;

function TGT_BlueToothLink.IsBluetoothReady: Boolean;
begin
  Result := False;
  try
    Self.EnsureManager;
    if Assigned(Self.FoManager) then
      Result := (Self.FoManager.ConnectionState = TBluetoothConnectionState.Connected);
  except
    Result := False;
  end;
end;

function TGT_BlueToothLink.LocalAdapterName: string;
begin
  Result := '';
  try
    Self.EnsureManager;
    if Assigned(Self.FoManager) and Assigned(Self.FoManager.CurrentAdapter) then
      Result := Self.FoManager.CurrentAdapter.AdapterName;
  except
    Result := '';
  end;
end;

function TGT_BlueToothLink.GetPairedDevices: TBluetoothDeviceList;
begin
  // The returned list belongs to the Bluetooth manager - do not free it.
  // Asking again can rebuild the list, so do not keep device references
  // from an older call.
  Self.EnsureManager;
  if not Assigned(Self.FoManager) then
    raise EGT_BlueToothLinkError.Create('Bluetooth manager not available');
  Result := Self.FoManager.GetPairedDevices;
end;

{ ============================================================================ }
{ CONNECTION - MAIN THREAD                                                     }
{ ============================================================================ }

procedure TGT_BlueToothLink.Listen;
begin
  if Self.FeState <> lsIdle then
    raise EGT_BlueToothLinkError.CreateFmt(
      'Cannot listen while the link is %s', [StateName(Self.FeState)]);

  // Reap a worker that has already finished
  Self.DoStopWorker;

  if not Self.IsBluetoothReady then
    raise EGT_BlueToothLinkError.Create(
      'Bluetooth is not available or not switched on');

  Self.FoServerSocket := Self.FoManager.CreateServerSocket(
    GTBT_SERVICE_NAME, Self.FguidServiceUUID, Self.FbSecureSockets);

  if not Assigned(Self.FoServerSocket) then
    raise EGT_BlueToothLinkError.Create('Could not create the server socket');

  Self.DoSetState(lsListening);
  Self.DoStartWorker(nil);
end;

procedure TGT_BlueToothLink.Connect(const o_Device: TBluetoothDevice);
begin
  if not Assigned(o_Device) then
    raise EGT_BlueToothLinkError.Create('No device selected');

  if Self.FeState <> lsIdle then
    raise EGT_BlueToothLinkError.CreateFmt(
      'Cannot connect while the link is %s', [StateName(Self.FeState)]);

  Self.DoStopWorker;

  if not Self.IsBluetoothReady then
    raise EGT_BlueToothLinkError.Create(
      'Bluetooth is not available or not switched on');

  Self.DoSetState(lsConnecting);
  Self.DoStartWorker(o_Device);
end;

procedure TGT_BlueToothLink.Disconnect;
begin
  // Waits for the worker to notice the stop flag. That is at most one poll
  // interval, except during a connect attempt, which can take several seconds.
  Self.DoStopWorker;
end;

procedure TGT_BlueToothLink.RequestClose;
begin
  // Only raises the flag. The worker closes everything itself on its next loop.
  Self.FbStopRequested := True;
end;

{ ============================================================================ }
{ WORKER THREAD                                                                }
{ ============================================================================ }

procedure TGT_BlueToothLink.DoStartWorker(const o_Device: TBluetoothDevice);
begin
  Self.FbStopRequested := False;
  Self.ResetStatistics;

  Self.FthrWorker := TThread.CreateAnonymousThread(
    procedure
    begin
      Self.DoWorkerExecute(o_Device);
    end);
  Self.FthrWorker.FreeOnTerminate := False;
  Self.FthrWorker.Start;
end;

procedure TGT_BlueToothLink.DoStopWorker;
begin
  if Assigned(Self.FthrWorker) then
  begin
    Self.FbStopRequested := True;
    Self.FthrWorker.WaitFor;
    FreeAndNil(Self.FthrWorker);
  end;
end;

procedure TGT_BlueToothLink.DoWorkerExecute(const o_Device: TBluetoothDevice);
var
  sCloseReason: string;
  bWasConnected: Boolean;
begin
  sCloseReason := 'closed locally';
  bWasConnected := False;

  try
    try
      if Assigned(o_Device) then
      begin
        // ---- Client side ----
        Self.QueueDoLog('Connecting to ' + o_Device.DeviceName + ' (' +
          Self.DoSocketModeText + ' socket) ...');
        Self.FoSocket := o_Device.CreateClientSocket(Self.FguidServiceUUID,
          Self.FbSecureSockets);

        if not Assigned(Self.FoSocket) then
          raise EGT_BlueToothLinkError.Create('CreateClientSocket returned nil');

        // CreateClientSocket only builds the socket. Connect opens it.
        Self.FoSocket.Connect;
        Self.FsPeerName := o_Device.DeviceName;
      end
      else
      begin
        // ---- Server side ----
        Self.QueueDoLog('Listening for an incoming connection (' +
          Self.DoSocketModeText + ' socket) ...');
        Self.DoAcceptLoop;
      end;

      if Assigned(Self.FoSocket) and (not Self.FbStopRequested) then
      begin
        bWasConnected := True;
        Self.DoSetState(lsConnected);
        Self.QueueDoLog('Connected to ' + Self.FsPeerName + ' using a ' +
          Self.DoSocketModeText + ' socket');

        if Assigned(Self.FProcLinkOpened) then
          Self.FProcLinkOpened();

        Self.DoReadLoop;
      end;

    except
      on oError: Exception do
        sCloseReason := oError.ClassName + ': ' + oError.Message;
    end;
  finally
    Self.DoCloseSockets;

    if bWasConnected and Assigned(Self.FProcLinkClosed) then
    begin
      try
        Self.FProcLinkClosed();
      except
        // The session layer must never take the worker down with it
      end;
    end;

    Self.FsPeerName := '';
    Self.DoSetState(lsIdle);

    if bWasConnected then
      Self.QueueDoLog('Link closed (' + sCloseReason + '). ' + Self.StatisticsText)
    else
      Self.QueueDoLog('Link not established (' + sCloseReason + ').');
  end;
end;

procedure TGT_BlueToothLink.DoAcceptLoop;
begin
  // Accept waits up to the poll time and returns nil when nobody connected,
  // which lets this loop notice a stop request.
  while (not Self.FbStopRequested) and (not Assigned(Self.FoSocket)) do
    Self.FoSocket := Self.FoServerSocket.Accept(Cardinal(Self.FiAcceptPollMs));

  if Assigned(Self.FoSocket) then
    Self.FsPeerName := 'incoming device';

  // One connection at a time - stop advertising the service once connected
  FreeAndNil(Self.FoServerSocket);
end;

procedure TGT_BlueToothLink.DoReadLoop;
var
  arrData: TBytes;
  iLength: Integer;
  iFastEmptyCount: Integer;
  bFastEmptyReported: Boolean;
  recWatch: TStopwatch;
begin
  iFastEmptyCount := 0;
  bFastEmptyReported := False;

  while not Self.FbStopRequested do
  begin
    recWatch := TStopwatch.StartNew;
    arrData := Self.FoSocket.ReceiveData(Cardinal(Self.FiReadPollMs));
    iLength := Length(arrData);

    Inc(Self.FiReadCallCount);

    if iLength > 0 then
    begin
      iFastEmptyCount := 0;

      Inc(Self.Fi64BytesReceived, iLength);
      if (Self.FiSmallestRead = 0) or (iLength < Self.FiSmallestRead) then
        Self.FiSmallestRead := iLength;
      if iLength > Self.FiLargestRead then
        Self.FiLargestRead := iLength;

      if Self.FbLogEveryRead then
        Self.QueueDoLog(Format('ReceiveData returned %d bytes', [iLength]));

      if Assigned(Self.FProcDataReceived) then
        Self.FProcDataReceived(arrData);
    end
    else
    begin
      Inc(Self.FiEmptyReadCount);

      // An empty result normally means "nothing arrived within the poll time".
      // If it comes back almost instantly, over and over, then either the peer
      // closed the connection or this platform ignores the timeout. Nobody has
      // documented which, so by default this is only reported.
      if recWatch.ElapsedMilliseconds < FAST_EMPTY_READ_MS then
      begin
        Inc(iFastEmptyCount);
        Sleep(10);   // never spin the CPU

        if iFastEmptyCount >= FAST_EMPTY_READ_LIMIT then
        begin
          if Self.FbCloseOnFastEmptyReads then
            raise EGT_BlueToothLinkError.Create(
              'ReceiveData keeps returning empty instantly - treating the peer as gone');

          if not bFastEmptyReported then
          begin
            bFastEmptyReported := True;
            Self.QueueDoLog(Format(
              'NOTE: ReceiveData returned empty instantly %d times in a row ' +
              '(peer closed, or the timeout is not honoured on this platform)',
              [iFastEmptyCount]));
          end;
        end;
      end
      else
        iFastEmptyCount := 0;
    end;
  end;
end;

procedure TGT_BlueToothLink.DoCloseSockets;
begin
  // Mark the link unusable first so new SendBytes calls fail fast
  Self.FeState := lsIdle;

  // Close without the send lock: this is what unblocks a SendData call
  // that is stuck on another thread.
  if Assigned(Self.FoSocket) then
  begin
    try
      Self.FoSocket.Close;
    except
      // Suppress cleanup errors
    end;
  end;

  // Free under the lock so no sender is still inside the socket
  Self.FcsSend.Enter;
  try
    FreeAndNil(Self.FoSocket);
  finally
    Self.FcsSend.Leave;
  end;

  FreeAndNil(Self.FoServerSocket);
end;

{ ============================================================================ }
{ SEND                                                                         }
{ ============================================================================ }

procedure TGT_BlueToothLink.SendBytes(const arr_Data: TBytes);
begin
  if Length(arr_Data) = 0 then
    Exit;

  Self.FcsSend.Enter;
  try
    if (Self.FeState <> lsConnected) or (not Assigned(Self.FoSocket)) then
      raise EGT_BlueToothLinkError.Create('Not connected');

    Self.FoSocket.SendData(arr_Data);
    Inc(Self.Fi64BytesSent, Length(arr_Data));
  finally
    Self.FcsSend.Leave;
  end;
end;

{ ============================================================================ }
{ STATISTICS                                                                   }
{ ============================================================================ }

procedure TGT_BlueToothLink.ResetStatistics;
begin
  Self.FiReadCallCount := 0;
  Self.FiEmptyReadCount := 0;
  Self.FiSmallestRead := 0;
  Self.FiLargestRead := 0;
  Self.Fi64BytesReceived := 0;
  Self.Fi64BytesSent := 0;
end;

function TGT_BlueToothLink.StatisticsText: string;
var
  iDataReads: Integer;
  iAverageRead: Integer;
begin
  iDataReads := Self.FiReadCallCount - Self.FiEmptyReadCount;
  if iDataReads > 0 then
    iAverageRead := Integer(Self.Fi64BytesReceived div iDataReads)
  else
    iAverageRead := 0;

  Result := Format(
    'Sent %d bytes. Received %d bytes in %d reads ' +
    '(smallest %d, largest %d, average %d). Empty reads: %d.',
    [Self.Fi64BytesSent, Self.Fi64BytesReceived, iDataReads,
     Self.FiSmallestRead, Self.FiLargestRead, iAverageRead,
     Self.FiEmptyReadCount]);
end;

end.
