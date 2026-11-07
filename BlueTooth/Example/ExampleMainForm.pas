unit ExampleMainForm;

{===============================================================================
  GT BlueTooth Example - step-by-step test bench using the TGT_BlueTooth component
  Author: Greg Timmons

  Same app on both devices (Windows and Android). One side taps Listen,
  the other picks the paired device and taps Connect. After that either
  side can send text, pings of any size, or files, and everything that
  happens lands in the log with a timestamp.

  Drop a TGT_BlueTooth (palette tab "GT Tools") on the form, keep its default
  name GT_BlueTooth1, and wire its six events in the Object Inspector to the
  GT_BlueTooth1_On... handlers below. Its declaration is commented out here so the
  IDE's own declaration does not clash with it.

  All naming follows Greg's Law conventions.
===============================================================================}

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  System.IOUtils, System.Permissions, System.Bluetooth,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs,
  FMX.StdCtrls, FMX.Edit, FMX.ListBox, FMX.Memo, FMX.Memo.Types,
  FMX.Layouts, FMX.ScrollBox, FMX.Controls.Presentation,
  GT_BlueToothLink, GT_BlueToothSession, GT_BlueTooth;

const
  DEFAULT_PING_SIZE = 1024;
  DEFAULT_TEST_KB   = 256;

type
  TfrmMain = class(TForm)
    { Rows }
    layPermissions: TLayout;
    layDevices: TLayout;
    layConnect: TLayout;
    layOptions: TLayout;
    layText: TLayout;
    layPing: TLayout;
    layKnobs: TLayout;
    layTestFile: TLayout;
    layFilePath: TLayout;
    laySend: TLayout;
    layProgress: TLayout;
    layStatus: TLayout;
    layLogButtons: TLayout;

    { Controls }
    btnPermissions: TButton;
    btnListPaired: TButton;
    cmbDevices: TComboBox;
    btnListen: TButton;
    btnConnect: TButton;
    btnDisconnect: TButton;
    chkSecure: TCheckBox;
    chkLogReads: TCheckBox;
    btnSendText: TButton;
    edtText: TEdit;
    btnPing: TButton;
    edtPingSize: TEdit;
    lblChunkSize: TLabel;
    edtChunkSize: TEdit;
    lblAckWindow: TLabel;
    edtAckWindow: TEdit;
    btnMakeTestFile: TButton;
    edtTestFileKB: TEdit;
    btnBrowse: TButton;
    edtFilePath: TEdit;
    btnSendFile: TButton;
    btnCancel: TButton;
    btnStatistics: TButton;
    prgTransfer: TProgressBar;
    lblStatus: TLabel;
    btnSaveLog: TButton;
    btnClearLog: TButton;
    memLog: TMemo;

    { The component - drop it on the form, keep the default name }
    // GT_BlueTooth1: TGT_BlueTooth;

    { Form events }
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);

    { Button handlers - wired in the .fmx }
    procedure btnPermissions_OnClick(Sender: TObject);
    procedure btnListPaired_OnClick(Sender: TObject);
    procedure btnListen_OnClick(Sender: TObject);
    procedure btnConnect_OnClick(Sender: TObject);
    procedure btnDisconnect_OnClick(Sender: TObject);
    procedure btnSendText_OnClick(Sender: TObject);
    procedure btnPing_OnClick(Sender: TObject);
    procedure btnMakeTestFile_OnClick(Sender: TObject);
    procedure btnBrowse_OnClick(Sender: TObject);
    procedure btnSendFile_OnClick(Sender: TObject);
    procedure btnCancel_OnClick(Sender: TObject);
    procedure btnStatistics_OnClick(Sender: TObject);
    procedure btnSaveLog_OnClick(Sender: TObject);
    procedure btnClearLog_OnClick(Sender: TObject);

    { Component events - wire these to GT_BlueTooth1 in the Object Inspector }
    procedure GT_BlueTooth1_OnLog(Sender: TObject; const s_Message: string);
    procedure GT_BlueTooth1_OnStateChanged(Sender: TObject; const e_NewState: TGT_LinkState);
    procedure GT_BlueTooth1_OnTextReceived(Sender: TObject; const s_Text: string);
    procedure GT_BlueTooth1_OnPingResult(Sender: TObject; const i_PayloadSize: Integer;
      const i64_RoundTripMs: Int64; const b_PayloadIntact: Boolean);
    procedure GT_BlueTooth1_OnTransferProgress(Sender: TObject;
      const e_Direction: TGT_TransferDirection;
      const i64_BytesDone: Int64; const i64_BytesTotal: Int64);
    procedure GT_BlueTooth1_OnTransferFinished(Sender: TObject;
      const e_Direction: TGT_TransferDirection; const s_FilePath: string;
      const b_Success: Boolean; const s_Detail: string);
  private
    FobjlstPairedDevices: TBluetoothDeviceList;   // owned by the Bluetooth manager

    { Helpers }
    procedure DoLog(const s_Message: string);
    procedure DoLogError(const s_Where: string; const o_Error: Exception);
    procedure DoReportAdapter;
    procedure DoApplySettings;

  public
    { Public declarations }
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.fmx}

{ ============================================================================ }
{ FORM LIFETIME                                                                }
{ ============================================================================ }

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  Self.FobjlstPairedDevices := nil;

  // No file dialog on Android: type a path or use the test file button.
  // Picking files is the job of whatever app uses the library.
  {$IFNDEF MSWINDOWS}
  Self.btnBrowse.Visible := False;
  {$ENDIF}

  Self.DoLog('GT BlueTooth Example ready. Platform: ' + TOSVersion.ToString);
  Self.DoLog('Received files and saved logs go to: ' + Self.GT_BlueTooth1.Session.ReceiveFolder);
  Self.DoLog('Start with step 1 (Permissions).');
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  // The component disconnects and cleans up in its own destructor
end;

{ ============================================================================ }
{ HELPERS                                                                      }
{ ============================================================================ }

procedure TfrmMain.DoLog(const s_Message: string);
begin
  Self.memLog.Lines.Add(FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + s_Message);
  Self.memLog.GoToTextEnd;
end;

procedure TfrmMain.DoLogError(const s_Where: string; const o_Error: Exception);
begin
  Self.DoLog('ERROR in ' + s_Where + ': ' + o_Error.ClassName + ': ' +
    o_Error.Message);
end;

procedure TfrmMain.DoReportAdapter;
begin
  if Self.GT_BlueTooth1.IsBluetoothReady then
    Self.DoLog('Bluetooth is on. Local adapter: "' + Self.GT_BlueTooth1.LocalAdapterName + '"')
  else
    Self.DoLog('Bluetooth is NOT ready (off, missing, or permission refused).');
end;

procedure TfrmMain.DoApplySettings;
begin
  // Pull the knobs from the screen into the component before each action
  Self.GT_BlueTooth1.SecureSocket := Self.chkSecure.IsChecked;
  Self.GT_BlueTooth1.LogEveryRead := Self.chkLogReads.IsChecked;
  Self.GT_BlueTooth1.ChunkSize := StrToIntDef(Trim(Self.edtChunkSize.Text), DEFAULT_CHUNK_SIZE);
  Self.GT_BlueTooth1.AckWindow := StrToIntDef(Trim(Self.edtAckWindow.Text), DEFAULT_ACK_WINDOW);

  // Show what was actually accepted after clamping
  Self.edtChunkSize.Text := IntToStr(Self.GT_BlueTooth1.ChunkSize);
  Self.edtAckWindow.Text := IntToStr(Self.GT_BlueTooth1.AckWindow);
end;

{ ============================================================================ }
{ STEP 1 - PERMISSIONS                                                         }
{ ============================================================================ }

procedure TfrmMain.btnPermissions_OnClick(Sender: TObject);
var
  arrPermissions: TArray<string>;
begin
  try
    if TOSVersion.Platform <> TOSVersion.TPlatform.pfAndroid then
    begin
      Self.DoLog('Not Android - no runtime permissions to ask for.');
      Self.DoReportAdapter;
      Exit;
    end;

    // Android 12+ uses the new Bluetooth permissions; older versions need location
    if TOSVersion.Check(12) then
      arrPermissions := ['android.permission.BLUETOOTH_CONNECT',
                         'android.permission.BLUETOOTH_SCAN']
    else
      arrPermissions := ['android.permission.ACCESS_FINE_LOCATION'];

    Self.DoLog('Requesting Android permissions ...');

    // COMPILE HOTSPOT: if the callback signature differs in your Delphi build,
    // Ctrl+Click RequestPermissions in System.Permissions and match it.
    PermissionsService.RequestPermissions(arrPermissions,
      procedure(const arr_Permissions: TClassicStringDynArray;
        const arr_GrantResults: TClassicPermissionStatusDynArray)
      var
        iIndex: Integer;
        bAllGranted: Boolean;
      begin
        bAllGranted := True;
        for iIndex := 0 to Length(arr_GrantResults) - 1 do
        begin
          if arr_GrantResults[iIndex] = TPermissionStatus.Granted then
            Self.DoLog('  granted: ' + arr_Permissions[iIndex])
          else
          begin
            bAllGranted := False;
            Self.DoLog('  REFUSED: ' + arr_Permissions[iIndex]);
          end;
        end;

        if bAllGranted then
          Self.DoReportAdapter
        else
          Self.DoLog('Bluetooth cannot be used until the permissions are granted.');
      end);
  except
    on oError: Exception do
      Self.DoLogError('Permissions', oError);
  end;
end;

{ ============================================================================ }
{ STEP 2 - PAIRED DEVICES                                                      }
{ ============================================================================ }

procedure TfrmMain.btnListPaired_OnClick(Sender: TObject);
var
  iIndex: Integer;
  oDevice: TBluetoothDevice;
begin
  try
    // Asking again can rebuild the manager's list, which would pull the
    // device out from under a connect attempt that is in progress.
    if Self.GT_BlueTooth1.State <> lsIdle then
    begin
      Self.DoLog('List paired devices only while the link is idle.');
      Exit;
    end;

    Self.cmbDevices.Clear;
    Self.FobjlstPairedDevices := Self.GT_BlueTooth1.GetPairedDevices;

    if (not Assigned(Self.FobjlstPairedDevices)) or
       (Self.FobjlstPairedDevices.Count = 0) then
    begin
      Self.DoLog('No paired devices. Pair the two devices in the system ' +
        'Bluetooth settings first.');
      Exit;
    end;

    for iIndex := 0 to Self.FobjlstPairedDevices.Count - 1 do
    begin
      oDevice := Self.FobjlstPairedDevices[iIndex];
      Self.cmbDevices.Items.Add(Format('%s  [%s]',
        [oDevice.DeviceName, oDevice.Address]));
      Self.DoLog(Format('  paired: %s  [%s]', [oDevice.DeviceName, oDevice.Address]));
    end;

    Self.cmbDevices.ItemIndex := 0;
    Self.DoLog(Format('%d paired device(s) found.', [Self.FobjlstPairedDevices.Count]));
  except
    on oError: Exception do
      Self.DoLogError('List paired', oError);
  end;
end;

{ ============================================================================ }
{ STEP 3 - LISTEN / CONNECT / DISCONNECT                                       }
{ ============================================================================ }

procedure TfrmMain.btnListen_OnClick(Sender: TObject);
begin
  try
    Self.DoApplySettings;
    Self.GT_BlueTooth1.Listen;
  except
    on oError: Exception do
      Self.DoLogError('Listen', oError);
  end;
end;

procedure TfrmMain.btnConnect_OnClick(Sender: TObject);
var
  iSelected: Integer;
begin
  try
    iSelected := Self.cmbDevices.ItemIndex;
    if (not Assigned(Self.FobjlstPairedDevices)) or (iSelected < 0) or
       (iSelected >= Self.FobjlstPairedDevices.Count) then
    begin
      Self.DoLog('Pick a device first (step 2).');
      Exit;
    end;

    Self.DoApplySettings;
    Self.GT_BlueTooth1.Connect(Self.FobjlstPairedDevices[iSelected]);
  except
    on oError: Exception do
      Self.DoLogError('Connect', oError);
  end;
end;

procedure TfrmMain.btnDisconnect_OnClick(Sender: TObject);
begin
  try
    Self.DoLog('Disconnecting ...');
    Self.GT_BlueTooth1.Disconnect;
  except
    on oError: Exception do
      Self.DoLogError('Disconnect', oError);
  end;
end;

{ ============================================================================ }
{ STEP 4 - TEXT                                                                }
{ ============================================================================ }

procedure TfrmMain.btnSendText_OnClick(Sender: TObject);
begin
  try
    Self.GT_BlueTooth1.SendText(Self.edtText.Text);
    Self.DoLog('Sent text: ' + Self.edtText.Text);
  except
    on oError: Exception do
      Self.DoLogError('Send text', oError);
  end;
end;

{ ============================================================================ }
{ STEP 5 - PING                                                                }
{ ============================================================================ }

procedure TfrmMain.btnPing_OnClick(Sender: TObject);
var
  iSize: Integer;
begin
  try
    Self.DoApplySettings;
    iSize := StrToIntDef(Trim(Self.edtPingSize.Text), DEFAULT_PING_SIZE);
    Self.GT_BlueTooth1.ResetStatistics;
    Self.GT_BlueTooth1.SendPing(iSize);
    Self.DoLog(Format('Ping sent with a %d byte payload ...', [iSize]));
  except
    on oError: Exception do
      Self.DoLogError('Ping', oError);
  end;
end;

{ ============================================================================ }
{ STEP 6 - FILES                                                               }
{ ============================================================================ }

procedure TfrmMain.btnMakeTestFile_OnClick(Sender: TObject);
var
  stmFile: TFileStream;
  arrBlock: TBytes;
  iSizeKB: Integer;
  iBlockIndex: Integer;
  iByteIndex: Integer;
  sPath: string;
begin
  try
    iSizeKB := StrToIntDef(Trim(Self.edtTestFileKB.Text), DEFAULT_TEST_KB);
    if iSizeKB < 0 then
      iSizeKB := 0;

    sPath := TPath.Combine(TPath.GetTempPath, Format('gtbt_test_%dKB.bin', [iSizeKB]));
    SetLength(arrBlock, 1024);

    // Random content so compression or repetition cannot hide a problem
    stmFile := TFileStream.Create(sPath, fmCreate);
    try
      for iBlockIndex := 1 to iSizeKB do
      begin
        for iByteIndex := 0 to Length(arrBlock) - 1 do
          arrBlock[iByteIndex] := Byte(Random(256));
        stmFile.WriteBuffer(arrBlock[0], Length(arrBlock));
      end;
    finally
      stmFile.Free;
    end;

    Self.edtFilePath.Text := sPath;
    Self.DoLog(Format('Test file created: %s (%d KB)', [sPath, iSizeKB]));
  except
    on oError: Exception do
      Self.DoLogError('Make test file', oError);
  end;
end;

procedure TfrmMain.btnBrowse_OnClick(Sender: TObject);
var
  dlgPick: TOpenDialog;
begin
  // Windows only (the button is hidden elsewhere)
  try
    dlgPick := TOpenDialog.Create(Self);
    try
      if dlgPick.Execute then
      begin
        Self.edtFilePath.Text := dlgPick.FileName;
        Self.DoLog('Browse picked: ' + dlgPick.FileName);
      end;
    finally
      dlgPick.Free;
    end;
  except
    on oError: Exception do
      Self.DoLogError('Browse', oError);
  end;
end;

procedure TfrmMain.btnSendFile_OnClick(Sender: TObject);
begin
  try
    Self.DoApplySettings;
    Self.GT_BlueTooth1.ResetStatistics;
    Self.prgTransfer.Value := 0;
    Self.GT_BlueTooth1.SendFile(Trim(Self.edtFilePath.Text));
  except
    on oError: Exception do
      Self.DoLogError('Send file', oError);
  end;
end;

procedure TfrmMain.btnCancel_OnClick(Sender: TObject);
begin
  Self.GT_BlueTooth1.CancelTransfer;
  Self.DoLog('Cancel requested.');
end;

procedure TfrmMain.btnStatistics_OnClick(Sender: TObject);
begin
  Self.DoLog('Statistics: ' + Self.GT_BlueTooth1.StatisticsText);
end;

{ ============================================================================ }
{ LOG BUTTONS                                                                  }
{ ============================================================================ }

procedure TfrmMain.btnSaveLog_OnClick(Sender: TObject);
var
  sPath: string;
begin
  try
    ForceDirectories(Self.GT_BlueTooth1.Session.ReceiveFolder);
    sPath := TPath.Combine(Self.GT_BlueTooth1.Session.ReceiveFolder,
      'gtbt_log_' + FormatDateTime('yyyymmdd_hhnnss', Now) + '.txt');
    Self.memLog.Lines.SaveToFile(sPath, TEncoding.UTF8);
    Self.DoLog('Log saved to ' + sPath);
  except
    on oError: Exception do
      Self.DoLogError('Save log', oError);
  end;
end;

procedure TfrmMain.btnClearLog_OnClick(Sender: TObject);
begin
  Self.memLog.Lines.Clear;
end;

{ ============================================================================ }
{ COMPONENT EVENTS - MAIN THREAD                                               }
{ ============================================================================ }

procedure TfrmMain.GT_BlueTooth1_OnLog(Sender: TObject; const s_Message: string);
begin
  Self.DoLog(s_Message);
end;

procedure TfrmMain.GT_BlueTooth1_OnStateChanged(Sender: TObject;
  const e_NewState: TGT_LinkState);
begin
  Self.lblStatus.Text := 'Link: ' + TGT_BlueTooth.StateName(e_NewState);
  Self.DoLog('[link] state -> ' + TGT_BlueTooth.StateName(e_NewState));
end;

procedure TfrmMain.GT_BlueTooth1_OnTextReceived(Sender: TObject; const s_Text: string);
begin
  Self.DoLog('Received text: ' + s_Text);
end;

procedure TfrmMain.GT_BlueTooth1_OnPingResult(Sender: TObject;
  const i_PayloadSize: Integer; const i64_RoundTripMs: Int64;
  const b_PayloadIntact: Boolean);
var
  sIntact: string;
begin
  if b_PayloadIntact then
    sIntact := 'payload intact'
  else
    sIntact := 'PAYLOAD DAMAGED';

  Self.DoLog(Format('Pong: %d bytes came back in %d ms, %s.',
    [i_PayloadSize, i64_RoundTripMs, sIntact]));
  Self.DoLog('Statistics: ' + Self.GT_BlueTooth1.StatisticsText);
end;

procedure TfrmMain.GT_BlueTooth1_OnTransferProgress(Sender: TObject;
  const e_Direction: TGT_TransferDirection;
  const i64_BytesDone: Int64; const i64_BytesTotal: Int64);
var
  sDirection: string;
begin
  if e_Direction = tdSending then
    sDirection := 'Sending'
  else
    sDirection := 'Receiving';

  if i64_BytesTotal > 0 then
    Self.prgTransfer.Value := (i64_BytesDone / i64_BytesTotal) * 100
  else
    Self.prgTransfer.Value := 100;

  Self.lblStatus.Text := Format('%s: %d of %d bytes',
    [sDirection, i64_BytesDone, i64_BytesTotal]);
end;

procedure TfrmMain.GT_BlueTooth1_OnTransferFinished(Sender: TObject;
  const e_Direction: TGT_TransferDirection; const s_FilePath: string;
  const b_Success: Boolean; const s_Detail: string);
var
  sDirection: string;
  sOutcome: string;
begin
  if e_Direction = tdSending then
    sDirection := 'SEND'
  else
    sDirection := 'RECEIVE';

  if b_Success then
    sOutcome := 'OK'
  else
    sOutcome := 'FAILED';

  Self.DoLog(Format('%s %s: %s', [sDirection, sOutcome, s_FilePath]));
  Self.DoLog('  ' + s_Detail);
  Self.DoLog('Statistics: ' + Self.GT_BlueTooth1.StatisticsText);
  Self.lblStatus.Text := 'Link: ' + TGT_BlueTooth.StateName(Self.GT_BlueTooth1.State);
end;

end.
