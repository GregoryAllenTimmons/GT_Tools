unit GT_BlueToothSession;

{===============================================================================
  GT_BlueToothSession - what travels over an open TGT_BlueToothLink
  Author: Greg Timmons

  Plain library class (not a component). Give it a link; it speaks GTBT v2
  over whatever connection the link currently has open.

  It can send and receive:
    - text         (SendText)
    - ping / pong  (SendPing - echo test with any payload size, timed)
    - files        (SendFile - streamed from disk, SHA-256 verified)

  File transfer flow:
    sender                                receiver
    FILE_OFFER (name, size, hash)  --->
                                   <---   FILE_ACCEPT  or  FILE_REJECT
    FILE_CHUNK 0                   --->
                                   <---   CHUNK_ACK 0
    FILE_CHUNK 1 ...               --->
                                   <---   CHUNK_ACK 1 ...
                                   <---   FILE_RESULT (ok / hash mismatch)

  AckWindow = 1 is stop-and-wait (wait for every ACK before the next chunk).
  AckWindow = N lets the sender run up to N chunks ahead of the last ACK.

  There is no RESEND. RFCOMM already delivers bytes reliably and in order;
  if a frame ever fails its CRC the stream is out of step and the only safe
  move is to close the link, so that is what happens.

  Files are never held in memory: the sender reads chunk by chunk, the
  receiver writes chunk by chunk into "<name>.part" and renames it only
  after the hash matches.

  Threading rules:
    - Create / Free / SendText / SendPing / SendFile / CancelTransfer :
      call from the MAIN thread.
    - All On... events fire on the MAIN thread.
    - Free the session AFTER calling Link.Disconnect and BEFORE freeing the link.

  All naming follows Greg's Law conventions.
===============================================================================}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.IOUtils,
  System.Hash, System.Diagnostics,
  GT_BlueToothProtocol, GT_BlueToothLink;

const
  DEFAULT_CHUNK_SIZE        = 16384;    // 16 KB per chunk
  DEFAULT_ACK_WINDOW        = 1;        // stop-and-wait
  DEFAULT_REPLY_TIMEOUT_MS  = 30000;    // how long to wait for the other side
  PROGRESS_INTERVAL_MS      = 200;      // do not flood the main thread
  MIN_CHUNK_SIZE            = 256;
  MAX_CHUNK_SIZE            = 1048576;  // 1 MB

type
  EGT_BlueToothSessionError = class(Exception);

  TGT_TransferDirection = (tdSending, tdReceiving);

  { Main-thread events }
  TGT_SessionLogEvent = procedure(Sender: TObject;
    const s_Message: string) of object;

  TGT_SessionTextEvent = procedure(Sender: TObject;
    const s_Text: string) of object;

  TGT_SessionPingEvent = procedure(Sender: TObject;
    const i_PayloadSize: Integer; const i64_RoundTripMs: Int64;
    const b_PayloadIntact: Boolean) of object;

  TGT_SessionProgressEvent = procedure(Sender: TObject;
    const e_Direction: TGT_TransferDirection;
    const i64_BytesDone: Int64; const i64_BytesTotal: Int64) of object;

  TGT_SessionFinishedEvent = procedure(Sender: TObject;
    const e_Direction: TGT_TransferDirection; const s_FilePath: string;
    const b_Success: Boolean; const s_Detail: string) of object;

  { ========================================================================== }
  { TGT_BlueToothSession                                                       }
  { ========================================================================== }
  TGT_BlueToothSession = class(TObject)
  private
    FoLink: TGT_BlueToothLink;      // not owned
    FoParser: TGTBTFrameParser;     // owned - used on the link worker thread only

    { Configuration }
    FsReceiveFolder: string;
    FiChunkSize: Integer;
    FiAckWindow: Integer;
    FiReplyTimeoutMs: Integer;

    { Lifetime / control }
    FbDestroying: Boolean;
    FbCancelRequested: Boolean;

    { Sender side }
    FthrSend: TThread;
    FbSending: Boolean;
    FcsReply: TCriticalSection;     // guards the reply fields below
    FevtReply: TEvent;              // signalled whenever a reply field changes
    FbOfferAnswered: Boolean;
    FbOfferAccepted: Boolean;
    FsRejectReason: string;
    Fi64LastAckedChunk: Int64;      // -1 = nothing acknowledged yet
    FbResultReceived: Boolean;
    FbyResultCode: Byte;
    FsResultDetail: string;
    FbAbortReceived: Boolean;
    FsAbortReason: string;

    { Ping }
    FbPingSending: Boolean;
    FbPingPending: Boolean;
    FiPingSize: Integer;
    FrecPingWatch: TStopwatch;

    { Receiver side - touched on the link worker thread only }
    FbReceiving: Boolean;
    FrecIncomingOffer: TGTBTFileOffer;
    FsIncomingFileName: string;
    FsIncomingPartPath: string;
    FstmFileIncoming: TFileStream;
    FrecIncomingHash: THashSHA2;
    Fi64IncomingBytes: Int64;
    FdwNextChunkIndex: UInt32;
    FrecIncomingWatch: TStopwatch;
    FrecIncomingProgressWatch: TStopwatch;

    { Events }
    FOnLog: TGT_SessionLogEvent;
    FOnTextReceived: TGT_SessionTextEvent;
    FOnPingResult: TGT_SessionPingEvent;
    FOnTransferProgress: TGT_SessionProgressEvent;
    FOnTransferFinished: TGT_SessionFinishedEvent;

    { Main-thread notification }
    procedure QueueDoLog(const s_Message: string);
    procedure QueueDoTextReceived(const s_Text: string);
    procedure QueueDoPingResult(const i_PayloadSize: Integer;
      const i64_RoundTripMs: Int64; const b_PayloadIntact: Boolean);
    procedure QueueDoProgress(const e_Direction: TGT_TransferDirection;
      const i64_BytesDone: Int64; const i64_BytesTotal: Int64);
    procedure QueueDoFinished(const e_Direction: TGT_TransferDirection;
      const s_FilePath: string; const b_Success: Boolean; const s_Detail: string);

    { Link callbacks - run on the link worker thread }
    procedure DoLinkOpened;
    procedure DoLinkData(const arr_Data: TBytes);
    procedure DoLinkClosed;

    { Frame handling - link worker thread }
    procedure DoHandleFrame(const rec_Frame: TGTBTFrame);
    procedure DoHandlePong(const arr_Payload: TBytes);
    procedure DoHandleOffer(const arr_Payload: TBytes);
    procedure DoHandleChunk(const arr_Payload: TBytes);
    procedure DoFinishIncoming;
    procedure DoAbortIncoming(const s_Reason: string; const b_NotifyPeer: Boolean);
    function DoUniqueReceivePath(const s_FileName: string): string;

    { Sender side }
    procedure DoSendFrame(const by_FrameType: Byte; const arr_Payload: TBytes);
    procedure DoResetReplyState;
    procedure DoWaitUntil(const proc_Condition: TFunc<Boolean>;
      const s_WaitingFor: string);
    procedure DoSendFileExecute(const s_FilePath: string);

    procedure SetChunkSize(const i_Value: Integer);
    procedure SetAckWindow(const i_Value: Integer);

    class function DoThroughputText(const i64_Bytes: Int64;
      const i64_ElapsedMs: Int64): string;
  public
    constructor Create(const o_Link: TGT_BlueToothLink);
    destructor Destroy; override;

    procedure SendText(const s_Text: string);
    procedure SendPing(const i_PayloadSize: Integer);
    procedure SendFile(const s_FilePath: string);
    procedure CancelTransfer;

    property IsSending: Boolean read FbSending;
    property IsReceiving: Boolean read FbReceiving;

    { Configuration }
    property ReceiveFolder: string read FsReceiveFolder write FsReceiveFolder;
    property ChunkSize: Integer read FiChunkSize write SetChunkSize;
    property AckWindow: Integer read FiAckWindow write SetAckWindow;
    property ReplyTimeoutMs: Integer read FiReplyTimeoutMs write FiReplyTimeoutMs;

    { Events - main thread }
    property OnLog: TGT_SessionLogEvent read FOnLog write FOnLog;
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

constructor TGT_BlueToothSession.Create(const o_Link: TGT_BlueToothLink);
begin
  inherited Create;

  if not Assigned(o_Link) then
    raise EGT_BlueToothSessionError.Create('A session needs a link');

  Self.FoLink := o_Link;
  Self.FoParser := TGTBTFrameParser.Create;
  Self.FcsReply := TCriticalSection.Create;
  Self.FevtReply := TEvent.Create(nil, False, False, '');   // auto-reset

  Self.FiChunkSize := DEFAULT_CHUNK_SIZE;
  Self.FiAckWindow := DEFAULT_ACK_WINDOW;
  Self.FiReplyTimeoutMs := DEFAULT_REPLY_TIMEOUT_MS;

  // Android: the shared Download folder, so received files show up in the
  // Files app and over USB. On Android 11+ an app may create its own files
  // there without a storage permission. If the folder cannot be written,
  // the incoming file is rejected and the reason appears in the log; set
  // ReceiveFolder to TPath.GetPublicPath to go back to the app-private folder.
  {$IFDEF ANDROID}
  Self.FsReceiveFolder := TPath.Combine(TPath.GetSharedDownloadsPath, 'GTBTReceived');
  {$ELSE}
  Self.FsReceiveFolder := TPath.Combine(TPath.GetDocumentsPath, 'GTBTReceived');
  {$ENDIF}

  Self.FbDestroying := False;
  Self.FbCancelRequested := False;
  Self.FthrSend := nil;
  Self.FbSending := False;
  Self.FbPingSending := False;
  Self.FbPingPending := False;
  Self.FiPingSize := 0;
  Self.FbReceiving := False;
  Self.FstmFileIncoming := nil;

  Self.DoResetReplyState;

  // Hook into the link. These run on the link's worker thread.
  Self.FoLink.ProcLinkOpened :=
    procedure
    begin
      Self.DoLinkOpened;
    end;

  Self.FoLink.ProcDataReceived :=
    procedure(const arr_Data: TBytes)
    begin
      Self.DoLinkData(arr_Data);
    end;

  Self.FoLink.ProcLinkClosed :=
    procedure
    begin
      Self.DoLinkClosed;
    end;
end;

destructor TGT_BlueToothSession.Destroy;
var
  iWaitCount: Integer;
begin
  // From here on every queued event becomes a no-op
  Self.FbDestroying := True;

  // Stop the sender thread if one is running
  Self.FbCancelRequested := True;
  Self.FevtReply.SetEvent;
  if Assigned(Self.FthrSend) then
  begin
    Self.FthrSend.WaitFor;
    FreeAndNil(Self.FthrSend);
  end;

  // Give a ping that is still being written a moment to finish
  iWaitCount := 0;
  while Self.FbPingSending and (iWaitCount < 300) do
  begin
    Sleep(10);
    Inc(iWaitCount);
  end;

  // Unhook from the link
  Self.FoLink.ProcLinkOpened := nil;
  Self.FoLink.ProcDataReceived := nil;
  Self.FoLink.ProcLinkClosed := nil;

  // Should already be clean if Link.Disconnect was called first
  if Self.FbReceiving then
    Self.DoAbortIncoming('session destroyed', False);

  // Flush anything queued for the main thread while this object is alive
  if TThread.CurrentThread.ThreadID = MainThreadID then
    CheckSynchronize;

  FreeAndNil(Self.FoParser);
  FreeAndNil(Self.FevtReply);
  FreeAndNil(Self.FcsReply);

  inherited Destroy;
end;

{ ============================================================================ }
{ PROPERTY SETTERS                                                             }
{ ============================================================================ }

procedure TGT_BlueToothSession.SetChunkSize(const i_Value: Integer);
begin
  if i_Value < MIN_CHUNK_SIZE then
    Self.FiChunkSize := MIN_CHUNK_SIZE
  else if i_Value > MAX_CHUNK_SIZE then
    Self.FiChunkSize := MAX_CHUNK_SIZE
  else
    Self.FiChunkSize := i_Value;
end;

procedure TGT_BlueToothSession.SetAckWindow(const i_Value: Integer);
begin
  if i_Value < 1 then
    Self.FiAckWindow := 1
  else
    Self.FiAckWindow := i_Value;
end;

{ ============================================================================ }
{ MAIN-THREAD NOTIFICATION                                                     }
{ ============================================================================ }

procedure TGT_BlueToothSession.QueueDoLog(const s_Message: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      if (not Self.FbDestroying) and Assigned(Self.FOnLog) then
        Self.FOnLog(Self, s_Message);
    end);
end;

procedure TGT_BlueToothSession.QueueDoTextReceived(const s_Text: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      if (not Self.FbDestroying) and Assigned(Self.FOnTextReceived) then
        Self.FOnTextReceived(Self, s_Text);
    end);
end;

procedure TGT_BlueToothSession.QueueDoPingResult(const i_PayloadSize: Integer;
  const i64_RoundTripMs: Int64; const b_PayloadIntact: Boolean);
begin
  TThread.Queue(nil,
    procedure
    begin
      if (not Self.FbDestroying) and Assigned(Self.FOnPingResult) then
        Self.FOnPingResult(Self, i_PayloadSize, i64_RoundTripMs, b_PayloadIntact);
    end);
end;

procedure TGT_BlueToothSession.QueueDoProgress(
  const e_Direction: TGT_TransferDirection;
  const i64_BytesDone: Int64; const i64_BytesTotal: Int64);
begin
  TThread.Queue(nil,
    procedure
    begin
      if (not Self.FbDestroying) and Assigned(Self.FOnTransferProgress) then
        Self.FOnTransferProgress(Self, e_Direction, i64_BytesDone, i64_BytesTotal);
    end);
end;

procedure TGT_BlueToothSession.QueueDoFinished(
  const e_Direction: TGT_TransferDirection; const s_FilePath: string;
  const b_Success: Boolean; const s_Detail: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      if (not Self.FbDestroying) and Assigned(Self.FOnTransferFinished) then
        Self.FOnTransferFinished(Self, e_Direction, s_FilePath, b_Success, s_Detail);
    end);
end;

class function TGT_BlueToothSession.DoThroughputText(const i64_Bytes: Int64;
  const i64_ElapsedMs: Int64): string;
var
  i64SafeMs: Int64;
begin
  i64SafeMs := i64_ElapsedMs;
  if i64SafeMs < 1 then
    i64SafeMs := 1;

  Result := Format('%d bytes in %d ms (%.1f KB/s)',
    [i64_Bytes, i64_ElapsedMs, (i64_Bytes / 1024) / (i64SafeMs / 1000)]);
end;

{ ============================================================================ }
{ LINK CALLBACKS - LINK WORKER THREAD                                          }
{ ============================================================================ }

procedure TGT_BlueToothSession.DoLinkOpened;
begin
  // New connection: forget any half frame from the previous one
  Self.FoParser.Reset;
  Self.FbPingPending := False;
  Self.DoResetReplyState;
end;

procedure TGT_BlueToothSession.DoLinkData(const arr_Data: TBytes);
var
  recFrame: TGTBTFrame;
  eParseResult: TGTBTParseResult;
begin
  // The socket may hand over half a frame or several frames at once.
  // The parser keeps whatever is left over for the next call.
  Self.FoParser.Append(arr_Data);

  repeat
    eParseResult := Self.FoParser.TryReadFrame(recFrame);

    if eParseResult = prFrameReady then
    begin
      try
        Self.DoHandleFrame(recFrame);
      except
        on oError: Exception do
        begin
          Self.QueueDoLog('Error handling ' +
            GTBTFrameTypeName(recFrame.byFrameType) + ' frame: ' + oError.Message);
          if Self.FbReceiving then
            Self.DoAbortIncoming(oError.Message, True);
        end;
      end;
    end
    else if eParseResult = prCorruptStream then
    begin
      // Out of step with the sender. There is no way to find the next frame
      // boundary reliably, so close the link.
      Self.QueueDoLog('Stream corrupt: ' + Self.FoParser.LastError +
        ' - closing the link.');
      Self.FoParser.Reset;
      Self.FoLink.RequestClose;
    end;
  until eParseResult <> prFrameReady;
end;

procedure TGT_BlueToothSession.DoLinkClosed;
begin
  if Self.FbReceiving then
    Self.DoAbortIncoming('link closed', False);

  // Wake a sender that is waiting for a reply that will never come
  Self.FcsReply.Enter;
  try
    Self.FbAbortReceived := True;
    Self.FsAbortReason := 'link closed';
  finally
    Self.FcsReply.Leave;
  end;
  Self.FevtReply.SetEvent;
end;

{ ============================================================================ }
{ FRAME HANDLING - LINK WORKER THREAD                                          }
{ ============================================================================ }

procedure TGT_BlueToothSession.DoHandleFrame(const rec_Frame: TGTBTFrame);
var
  dwChunkIndex: UInt32;
  byResultCode: Byte;
  sDetail: string;
begin
  case rec_Frame.byFrameType of

    GTBT_FRAME_TEXT:
      Self.QueueDoTextReceived(GTBTParseTextPayload(rec_Frame.arrPayload));

    GTBT_FRAME_PING:
      // Echo the payload straight back
      Self.DoSendFrame(GTBT_FRAME_PONG, rec_Frame.arrPayload);

    GTBT_FRAME_PONG:
      Self.DoHandlePong(rec_Frame.arrPayload);

    GTBT_FRAME_FILE_OFFER:
      Self.DoHandleOffer(rec_Frame.arrPayload);

    GTBT_FRAME_FILE_CHUNK:
      Self.DoHandleChunk(rec_Frame.arrPayload);

    GTBT_FRAME_FILE_ACCEPT:
      begin
        Self.FcsReply.Enter;
        try
          Self.FbOfferAnswered := True;
          Self.FbOfferAccepted := True;
        finally
          Self.FcsReply.Leave;
        end;
        Self.FevtReply.SetEvent;
      end;

    GTBT_FRAME_FILE_REJECT:
      begin
        Self.FcsReply.Enter;
        try
          Self.FbOfferAnswered := True;
          Self.FbOfferAccepted := False;
          Self.FsRejectReason := GTBTParseTextPayload(rec_Frame.arrPayload);
        finally
          Self.FcsReply.Leave;
        end;
        Self.FevtReply.SetEvent;
      end;

    GTBT_FRAME_CHUNK_ACK:
      begin
        if GTBTParseUInt32Payload(rec_Frame.arrPayload, dwChunkIndex) then
        begin
          Self.FcsReply.Enter;
          try
            Self.Fi64LastAckedChunk := Int64(dwChunkIndex);
          finally
            Self.FcsReply.Leave;
          end;
          Self.FevtReply.SetEvent;
        end;
      end;

    GTBT_FRAME_FILE_RESULT:
      begin
        if GTBTParseResultPayload(rec_Frame.arrPayload, byResultCode, sDetail) then
        begin
          Self.FcsReply.Enter;
          try
            Self.FbResultReceived := True;
            Self.FbyResultCode := byResultCode;
            Self.FsResultDetail := sDetail;
          finally
            Self.FcsReply.Leave;
          end;
          Self.FevtReply.SetEvent;
        end;
      end;

    GTBT_FRAME_ABORT:
      begin
        sDetail := GTBTParseTextPayload(rec_Frame.arrPayload);

        if Self.FbReceiving then
          Self.DoAbortIncoming('sender aborted: ' + sDetail, False);

        Self.FcsReply.Enter;
        try
          Self.FbAbortReceived := True;
          Self.FsAbortReason := sDetail;
        finally
          Self.FcsReply.Leave;
        end;
        Self.FevtReply.SetEvent;
      end;

  else
    Self.QueueDoLog('Ignored ' + GTBTFrameTypeName(rec_Frame.byFrameType) + ' frame');
  end;
end;

procedure TGT_BlueToothSession.DoHandlePong(const arr_Payload: TBytes);
var
  i64RoundTripMs: Int64;
  bIntact: Boolean;
begin
  if not Self.FbPingPending then
  begin
    Self.QueueDoLog('Unexpected PONG ignored');
    Exit;
  end;

  Self.FrecPingWatch.Stop;
  i64RoundTripMs := Self.FrecPingWatch.ElapsedMilliseconds;
  Self.FbPingPending := False;

  bIntact := GTBTBytesEqual(arr_Payload, GTBTBuildPatternPayload(Self.FiPingSize));
  Self.QueueDoPingResult(Length(arr_Payload), i64RoundTripMs, bIntact);
end;

procedure TGT_BlueToothSession.DoHandleOffer(const arr_Payload: TBytes);
var
  recOffer: TGTBTFileOffer;
  sRejectReason: string;
begin
  sRejectReason := '';

  if not GTBTParseFileOfferPayload(arr_Payload, recOffer) then
    sRejectReason := 'file offer could not be read'
  else if Self.FbReceiving or Self.FbSending then
    sRejectReason := 'another transfer is already running'
  else if recOffer.i64FileSize < 0 then
    sRejectReason := 'negative file size'
  else if (recOffer.dwChunkSize = 0) or (recOffer.dwChunkSize > MAX_CHUNK_SIZE) then
    sRejectReason := 'unsupported chunk size';

  if sRejectReason = '' then
  begin
    try
      Self.FsIncomingFileName := GTBTSanitizeFileName(recOffer.sFileName);
      ForceDirectories(Self.FsReceiveFolder);
      Self.FsIncomingPartPath := TPath.Combine(Self.FsReceiveFolder,
        Self.FsIncomingFileName + '.part');

      Self.FstmFileIncoming := TFileStream.Create(Self.FsIncomingPartPath, fmCreate);
    except
      on oError: Exception do
      begin
        FreeAndNil(Self.FstmFileIncoming);
        sRejectReason := 'cannot create file: ' + oError.Message;
      end;
    end;
  end;

  if sRejectReason <> '' then
  begin
    Self.QueueDoLog('Rejected incoming file: ' + sRejectReason);
    Self.DoSendFrame(GTBT_FRAME_FILE_REJECT, GTBTBuildTextPayload(sRejectReason));
    Exit;
  end;

  Self.FrecIncomingOffer := recOffer;
  Self.FrecIncomingHash := THashSHA2.Create(THashSHA2.TSHA2Version.SHA256);
  Self.Fi64IncomingBytes := 0;
  Self.FdwNextChunkIndex := 0;
  Self.FrecIncomingWatch := TStopwatch.StartNew;
  Self.FrecIncomingProgressWatch := TStopwatch.StartNew;
  Self.FbCancelRequested := False;
  Self.FbReceiving := True;

  Self.QueueDoLog(Format('Incoming file "%s", %d bytes, chunk size %u - accepted',
    [Self.FsIncomingFileName, recOffer.i64FileSize, recOffer.dwChunkSize]));
  Self.QueueDoProgress(tdReceiving, 0, recOffer.i64FileSize);

  Self.DoSendFrame(GTBT_FRAME_FILE_ACCEPT, nil);

  // An empty file has no chunks - finish straight away
  if recOffer.i64FileSize = 0 then
    Self.DoFinishIncoming;
end;

procedure TGT_BlueToothSession.DoHandleChunk(const arr_Payload: TBytes);
var
  dwChunkIndex: UInt32;
  arrData: TBytes;
  iDataLength: Integer;
begin
  if not Self.FbReceiving then
  begin
    Self.QueueDoLog('Chunk received with no transfer running - ignored');
    Exit;
  end;

  if Self.FbCancelRequested then
  begin
    Self.DoAbortIncoming('cancelled by receiver', True);
    Exit;
  end;

  if not GTBTParseChunkPayload(arr_Payload, dwChunkIndex, arrData) then
  begin
    Self.DoAbortIncoming('chunk could not be read', True);
    Exit;
  end;

  if dwChunkIndex <> Self.FdwNextChunkIndex then
  begin
    Self.DoAbortIncoming(Format('chunk %u arrived, chunk %u expected',
      [dwChunkIndex, Self.FdwNextChunkIndex]), True);
    Exit;
  end;

  iDataLength := Length(arrData);
  if (iDataLength = 0) or
     (Self.Fi64IncomingBytes + iDataLength > Self.FrecIncomingOffer.i64FileSize) then
  begin
    Self.DoAbortIncoming('chunk does not fit the declared file size', True);
    Exit;
  end;

  // Straight to disk and into the running hash - nothing is kept in memory
  Self.FstmFileIncoming.WriteBuffer(arrData[0], iDataLength);
  Self.FrecIncomingHash.Update(arrData[0], Cardinal(iDataLength));

  Inc(Self.Fi64IncomingBytes, iDataLength);
  Inc(Self.FdwNextChunkIndex);

  Self.DoSendFrame(GTBT_FRAME_CHUNK_ACK, GTBTBuildUInt32Payload(dwChunkIndex));

  if Self.FrecIncomingProgressWatch.ElapsedMilliseconds >= PROGRESS_INTERVAL_MS then
  begin
    Self.FrecIncomingProgressWatch := TStopwatch.StartNew;
    Self.QueueDoProgress(tdReceiving, Self.Fi64IncomingBytes,
      Self.FrecIncomingOffer.i64FileSize);
  end;

  if Self.Fi64IncomingBytes = Self.FrecIncomingOffer.i64FileSize then
    Self.DoFinishIncoming;
end;

procedure TGT_BlueToothSession.DoFinishIncoming;
var
  arrComputedHash: TBytes;
  sFinalPath: string;
  sDetail: string;
  i64ElapsedMs: Int64;
begin
  FreeAndNil(Self.FstmFileIncoming);
  Self.FbReceiving := False;

  i64ElapsedMs := Self.FrecIncomingWatch.ElapsedMilliseconds;
  arrComputedHash := Self.FrecIncomingHash.HashAsBytes;

  Self.QueueDoProgress(tdReceiving, Self.Fi64IncomingBytes,
    Self.FrecIncomingOffer.i64FileSize);

  if not GTBTBytesEqual(arrComputedHash, Self.FrecIncomingOffer.arrFileHash) then
  begin
    // A file that fails verification is never kept
    if TFile.Exists(Self.FsIncomingPartPath) then
      TFile.Delete(Self.FsIncomingPartPath);

    Self.DoSendFrame(GTBT_FRAME_FILE_RESULT,
      GTBTBuildResultPayload(GTBT_RESULT_HASH_MISMATCH, 'SHA-256 mismatch'));
    Self.QueueDoFinished(tdReceiving, Self.FsIncomingFileName, False,
      'SHA-256 mismatch - file discarded');
    Exit;
  end;

  try
    sFinalPath := Self.DoUniqueReceivePath(Self.FsIncomingFileName);
    TFile.Move(Self.FsIncomingPartPath, sFinalPath);
  except
    on oError: Exception do
    begin
      Self.DoSendFrame(GTBT_FRAME_FILE_RESULT,
        GTBTBuildResultPayload(GTBT_RESULT_WRITE_ERROR, oError.Message));
      Self.QueueDoFinished(tdReceiving, Self.FsIncomingPartPath, False,
        'Verified, but could not rename the file: ' + oError.Message);
      Exit;
    end;
  end;

  sDetail := 'SHA-256 verified. ' +
    DoThroughputText(Self.Fi64IncomingBytes, i64ElapsedMs);

  Self.DoSendFrame(GTBT_FRAME_FILE_RESULT,
    GTBTBuildResultPayload(GTBT_RESULT_OK, sDetail));
  Self.QueueDoFinished(tdReceiving, sFinalPath, True, sDetail);
end;

procedure TGT_BlueToothSession.DoAbortIncoming(const s_Reason: string;
  const b_NotifyPeer: Boolean);
begin
  FreeAndNil(Self.FstmFileIncoming);
  Self.FbReceiving := False;

  try
    if TFile.Exists(Self.FsIncomingPartPath) then
      TFile.Delete(Self.FsIncomingPartPath);
  except
    // A leftover .part file is harmless
  end;

  if b_NotifyPeer then
  begin
    try
      Self.DoSendFrame(GTBT_FRAME_ABORT, GTBTBuildTextPayload(s_Reason));
    except
      // The link may already be gone
    end;
  end;

  Self.QueueDoFinished(tdReceiving, Self.FsIncomingFileName, False,
    'Receive aborted: ' + s_Reason);
end;

function TGT_BlueToothSession.DoUniqueReceivePath(const s_FileName: string): string;
begin
  Result := TPath.Combine(Self.FsReceiveFolder, s_FileName);

  // Never overwrite - add a timestamp when the name is taken
  if TFile.Exists(Result) then
    Result := TPath.Combine(Self.FsReceiveFolder,
      TPath.GetFileNameWithoutExtension(s_FileName) + '_' +
      FormatDateTime('yyyymmdd_hhnnss', Now) + TPath.GetExtension(s_FileName));
end;

{ ============================================================================ }
{ SEND - GENERAL                                                               }
{ ============================================================================ }

procedure TGT_BlueToothSession.DoSendFrame(const by_FrameType: Byte;
  const arr_Payload: TBytes);
begin
  // One frame = one SendBytes call. The link serialises senders, so frames
  // from different threads can never interleave.
  Self.FoLink.SendBytes(GTBTBuildFrame(by_FrameType, arr_Payload));
end;

procedure TGT_BlueToothSession.SendText(const s_Text: string);
begin
  Self.DoSendFrame(GTBT_FRAME_TEXT, GTBTBuildTextPayload(s_Text));
end;

procedure TGT_BlueToothSession.SendPing(const i_PayloadSize: Integer);
var
  arrPattern: TBytes;
  iSize: Integer;
begin
  if Self.FoLink.State <> lsConnected then
    raise EGT_BlueToothSessionError.Create('Not connected');

  if Self.FbPingSending then
    raise EGT_BlueToothSessionError.Create('A ping is still being sent');

  // A ping whose reply never came stops blocking new pings after the timeout
  if Self.FbPingPending and
     (Self.FrecPingWatch.ElapsedMilliseconds < Self.FiReplyTimeoutMs) then
    raise EGT_BlueToothSessionError.Create('A ping is still waiting for its reply');

  iSize := i_PayloadSize;
  if iSize < 1 then
    iSize := 1;
  if iSize > 1048576 then
    iSize := 1048576;

  arrPattern := GTBTBuildPatternPayload(iSize);

  Self.FiPingSize := iSize;
  Self.FbPingPending := True;
  Self.FbPingSending := True;
  Self.FrecPingWatch := TStopwatch.StartNew;

  // Sent from its own thread so a large payload cannot freeze the UI
  TThread.CreateAnonymousThread(
    procedure
    begin
      try
        try
          Self.DoSendFrame(GTBT_FRAME_PING, arrPattern);
        except
          on oError: Exception do
          begin
            Self.FbPingPending := False;
            Self.QueueDoLog('Ping could not be sent: ' + oError.Message);
          end;
        end;
      finally
        Self.FbPingSending := False;
      end;
    end).Start;
end;

procedure TGT_BlueToothSession.CancelTransfer;
begin
  // The sender thread sees this on its next wait; the receiver on its next chunk
  Self.FbCancelRequested := True;
  Self.FevtReply.SetEvent;
end;

{ ============================================================================ }
{ SEND - FILE                                                                  }
{ ============================================================================ }

procedure TGT_BlueToothSession.DoResetReplyState;
begin
  Self.FcsReply.Enter;
  try
    Self.FbOfferAnswered := False;
    Self.FbOfferAccepted := False;
    Self.FsRejectReason := '';
    Self.Fi64LastAckedChunk := -1;
    Self.FbResultReceived := False;
    Self.FbyResultCode := 0;
    Self.FsResultDetail := '';
    Self.FbAbortReceived := False;
    Self.FsAbortReason := '';
  finally
    Self.FcsReply.Leave;
  end;
end;

procedure TGT_BlueToothSession.DoWaitUntil(const proc_Condition: TFunc<Boolean>;
  const s_WaitingFor: string);
var
  recWatch: TStopwatch;
  bSatisfied: Boolean;
  bAborted: Boolean;
  sAbortReason: string;
begin
  recWatch := TStopwatch.StartNew;

  while True do
  begin
    Self.FcsReply.Enter;
    try
      bSatisfied := proc_Condition();
      bAborted := Self.FbAbortReceived;
      sAbortReason := Self.FsAbortReason;
    finally
      Self.FcsReply.Leave;
    end;

    if bSatisfied then
      Exit;

    if bAborted then
      raise EGT_BlueToothSessionError.Create('Stopped by the other side: ' +
        sAbortReason);

    if Self.FbCancelRequested then
      raise EGT_BlueToothSessionError.Create('Cancelled');

    if recWatch.ElapsedMilliseconds > Self.FiReplyTimeoutMs then
      raise EGT_BlueToothSessionError.CreateFmt(
        'No %s from the other side within %d ms', [s_WaitingFor, Self.FiReplyTimeoutMs]);

    Self.FevtReply.WaitFor(100);
  end;
end;

procedure TGT_BlueToothSession.SendFile(const s_FilePath: string);
begin
  if Self.FoLink.State <> lsConnected then
    raise EGT_BlueToothSessionError.Create('Not connected');

  if Self.FbSending or Self.FbReceiving then
    raise EGT_BlueToothSessionError.Create('A transfer is already running');

  if not TFile.Exists(s_FilePath) then
    raise EGT_BlueToothSessionError.CreateFmt('File not found: %s', [s_FilePath]);

  // Reap the previous sender thread (it has already finished)
  if Assigned(Self.FthrSend) then
  begin
    Self.FthrSend.WaitFor;
    FreeAndNil(Self.FthrSend);
  end;

  Self.FbSending := True;
  Self.FbCancelRequested := False;

  Self.FthrSend := TThread.CreateAnonymousThread(
    procedure
    begin
      Self.DoSendFileExecute(s_FilePath);
    end);
  Self.FthrSend.FreeOnTerminate := False;
  Self.FthrSend.Start;
end;

procedure TGT_BlueToothSession.DoSendFileExecute(const s_FilePath: string);
var
  stmFile: TFileStream;
  recHash: THashSHA2;
  recOffer: TGTBTFileOffer;
  recWatch: TStopwatch;
  recProgressWatch: TStopwatch;
  arrBuffer: TBytes;
  iChunkSize: Integer;
  iAckWindow: Integer;
  iBytesRead: Integer;
  i64FileSize: Int64;
  i64BytesSent: Int64;
  i64ChunkIndex: Int64;
  bSuccess: Boolean;
  bOfferSent: Boolean;
  sDetail: string;
begin
  stmFile := nil;
  bSuccess := False;
  bOfferSent := False;
  sDetail := '';

  // Snapshot the settings so changing them mid-transfer cannot hurt
  iChunkSize := Self.FiChunkSize;
  iAckWindow := Self.FiAckWindow;

  try
    try
      stmFile := TFileStream.Create(s_FilePath, fmOpenRead or fmShareDenyWrite);
      i64FileSize := stmFile.Size;
      SetLength(arrBuffer, iChunkSize);

      // ---- Pass 1: SHA-256 of the whole file, read chunk by chunk ----
      Self.QueueDoLog('Hashing ' + TPath.GetFileName(s_FilePath) + ' ...');
      recHash := THashSHA2.Create(THashSHA2.TSHA2Version.SHA256);
      repeat
        if Self.FbCancelRequested then
          raise EGT_BlueToothSessionError.Create('Cancelled');

        iBytesRead := stmFile.Read(arrBuffer[0], iChunkSize);
        if iBytesRead > 0 then
          recHash.Update(arrBuffer[0], Cardinal(iBytesRead));
      until iBytesRead <= 0;
      stmFile.Position := 0;

      // ---- Offer ----
      recOffer.sFileName := TPath.GetFileName(s_FilePath);
      recOffer.i64FileSize := i64FileSize;
      recOffer.arrFileHash := recHash.HashAsBytes;
      recOffer.dwChunkSize := UInt32(iChunkSize);

      Self.DoResetReplyState;
      Self.QueueDoLog(Format('Offering "%s", %d bytes, chunk %d, ack window %d',
        [recOffer.sFileName, i64FileSize, iChunkSize, iAckWindow]));

      recWatch := TStopwatch.StartNew;
      recProgressWatch := TStopwatch.StartNew;
      Self.DoSendFrame(GTBT_FRAME_FILE_OFFER, GTBTBuildFileOfferPayload(recOffer));
      bOfferSent := True;

      Self.DoWaitUntil(
        function: Boolean
        begin
          Result := Self.FbOfferAnswered;
        end, 'answer to the file offer');

      if not Self.FbOfferAccepted then
      begin
        // The receiver already knows - no ABORT needed
        bOfferSent := False;
        raise EGT_BlueToothSessionError.Create('Receiver rejected the file: ' +
          Self.FsRejectReason);
      end;

      // ---- Chunks ----
      i64BytesSent := 0;
      i64ChunkIndex := 0;
      Self.QueueDoProgress(tdSending, 0, i64FileSize);

      while i64BytesSent < i64FileSize do
      begin
        // Hold back until the receiver is no more than iAckWindow chunks behind.
        // With a window of 1 this waits for every single ACK (stop-and-wait).
        Self.DoWaitUntil(
          function: Boolean
          begin
            Result := (i64ChunkIndex - Self.Fi64LastAckedChunk) <= iAckWindow;
          end, 'chunk acknowledgement');

        iBytesRead := stmFile.Read(arrBuffer[0], iChunkSize);
        if iBytesRead <= 0 then
          raise EGT_BlueToothSessionError.Create(
            'File ended earlier than its size said it would');

        Self.DoSendFrame(GTBT_FRAME_FILE_CHUNK,
          GTBTBuildChunkPayload(UInt32(i64ChunkIndex), arrBuffer, iBytesRead));

        Inc(i64BytesSent, iBytesRead);
        Inc(i64ChunkIndex);

        if recProgressWatch.ElapsedMilliseconds >= PROGRESS_INTERVAL_MS then
        begin
          recProgressWatch := TStopwatch.StartNew;
          Self.QueueDoProgress(tdSending, i64BytesSent, i64FileSize);
        end;
      end;

      Self.QueueDoProgress(tdSending, i64BytesSent, i64FileSize);

      // ---- Final verdict from the receiver ----
      Self.DoWaitUntil(
        function: Boolean
        begin
          Result := Self.FbResultReceived;
        end, 'final result');

      // The receiver has finished either way - no ABORT needed after this
      bOfferSent := False;

      if Self.FbyResultCode <> GTBT_RESULT_OK then
        raise EGT_BlueToothSessionError.Create('Receiver reported: ' +
          Self.FsResultDetail);

      bSuccess := True;
      sDetail := 'Receiver verified SHA-256. ' +
        DoThroughputText(i64BytesSent, recWatch.ElapsedMilliseconds);

    except
      on oError: Exception do
      begin
        sDetail := 'Send failed: ' + oError.Message;

        // Tell the receiver to stop waiting, if it is still expecting chunks
        if bOfferSent and (Self.FoLink.State = lsConnected) then
        begin
          try
            Self.DoSendFrame(GTBT_FRAME_ABORT, GTBTBuildTextPayload(oError.Message));
          except
            // The link may already be gone
          end;
        end;
      end;
    end;
  finally
    FreeAndNil(stmFile);
    Self.FbSending := False;
    Self.QueueDoFinished(tdSending, s_FilePath, bSuccess, sDetail);
  end;
end;

end.
