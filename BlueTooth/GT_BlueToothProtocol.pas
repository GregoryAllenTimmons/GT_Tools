unit GT_BlueToothProtocol;

{===============================================================================
  GT_BlueToothProtocol - GTBT v2 wire format (pure logic, no Bluetooth)
  Author: Greg Timmons

  This unit knows how to BUILD frames and how to PARSE a byte stream back
  into frames. It never touches a socket, so it can be tested on Windows
  with plain byte arrays.

  Every message on the wire is one frame:

    offset  size  field
    0       4     magic 'G','T','B','T'
    4       1     protocol version
    5       1     frame type
    6       4     payload length (UInt32, little-endian)
    10      N     payload
    10+N    4     CRC32 of bytes 4 .. 10+N-1 (version, type, length, payload)

  The parser keeps its own buffer. Feed it whatever the socket returns
  (half a frame, three frames glued together, one byte) and it hands back
  whole frames only. Nothing is ever thrown away.

  All naming follows Greg's Law conventions.
===============================================================================}

interface

uses
  System.SysUtils, System.Classes;

const
  { Protocol identification }
  GTBT_PROTOCOL_VERSION     = $02;

  { Frame geometry }
  GTBT_FRAME_HEADER_SIZE    = 10;
  GTBT_FRAME_TRAILER_SIZE   = 4;
  GTBT_MAX_PAYLOAD_SIZE     = 1048576 + 64;   // 1 MB of data plus room for fields
  GTBT_HASH_SIZE            = 32;             // SHA-256
  GTBT_MAX_FILE_NAME_BYTES  = 1024;

  { Frame types - general }
  GTBT_FRAME_TEXT           = $10;   // payload: UTF-8 text
  GTBT_FRAME_PING           = $11;   // payload: any bytes, echoed back
  GTBT_FRAME_PONG           = $12;   // payload: the bytes from the ping

  { Frame types - file transfer }
  GTBT_FRAME_FILE_OFFER     = $20;   // payload: see TGTBTFileOffer
  GTBT_FRAME_FILE_ACCEPT    = $21;   // payload: none
  GTBT_FRAME_FILE_REJECT    = $22;   // payload: UTF-8 reason
  GTBT_FRAME_FILE_CHUNK     = $23;   // payload: chunk index (4) + data
  GTBT_FRAME_CHUNK_ACK      = $24;   // payload: chunk index (4)
  GTBT_FRAME_FILE_RESULT    = $25;   // payload: result code (1) + UTF-8 detail
  GTBT_FRAME_ABORT          = $2F;   // payload: UTF-8 reason

  { Result codes carried by GTBT_FRAME_FILE_RESULT }
  GTBT_RESULT_OK            = $00;
  GTBT_RESULT_HASH_MISMATCH = $01;
  GTBT_RESULT_WRITE_ERROR   = $02;

type
  EGTBTProtocolError = class(Exception);

  { One complete message }
  TGTBTFrame = record
    byFrameType: Byte;
    arrPayload: TBytes;
  end;

  { What TryReadFrame found in the buffer }
  TGTBTParseResult = (prNeedMoreData, prFrameReady, prCorruptStream);

  { What travels in GTBT_FRAME_FILE_OFFER }
  TGTBTFileOffer = record
    sFileName: string;
    i64FileSize: Int64;
    arrFileHash: TBytes;     // SHA-256 of the whole file, GTBT_HASH_SIZE bytes
    dwChunkSize: UInt32;     // largest chunk the sender will use
  end;

  { ========================================================================== }
  { TGTBTFrameParser - turns a raw byte stream back into frames                }
  { ========================================================================== }
  TGTBTFrameParser = class(TObject)
  private
    FarrBuffer: TBytes;
    FiBufferUsed: Integer;
    FsLastError: string;
    procedure DoDiscardBytes(const i_ByteCount: Integer);
  public
    procedure Reset;
    procedure Append(const arr_Data: TBytes);
    function TryReadFrame(out rec_Frame: TGTBTFrame): TGTBTParseResult;
    property BufferedByteCount: Integer read FiBufferUsed;
    property LastError: string read FsLastError;
  end;

{ Frame building }
function GTBTBuildFrame(const by_FrameType: Byte;
  const arr_Payload: TBytes): TBytes;
function GTBTFrameTypeName(const by_FrameType: Byte): string;

{ Payload building / parsing }
function GTBTBuildFileOfferPayload(const rec_Offer: TGTBTFileOffer): TBytes;
function GTBTParseFileOfferPayload(const arr_Payload: TBytes;
  out rec_Offer: TGTBTFileOffer): Boolean;

function GTBTBuildChunkPayload(const dw_ChunkIndex: UInt32;
  const arr_Data: TBytes; const i_DataLength: Integer): TBytes;
function GTBTParseChunkPayload(const arr_Payload: TBytes;
  out dw_ChunkIndex: UInt32; out arr_Data: TBytes): Boolean;

function GTBTBuildUInt32Payload(const dw_Value: UInt32): TBytes;
function GTBTParseUInt32Payload(const arr_Payload: TBytes;
  out dw_Value: UInt32): Boolean;

function GTBTBuildResultPayload(const by_ResultCode: Byte;
  const s_Detail: string): TBytes;
function GTBTParseResultPayload(const arr_Payload: TBytes;
  out by_ResultCode: Byte; out s_Detail: string): Boolean;

function GTBTBuildTextPayload(const s_Text: string): TBytes;
function GTBTParseTextPayload(const arr_Payload: TBytes): string;

{ Helpers }
function GTBTCrc32(const arr_Data: TBytes; const i_Offset: Integer;
  const i_Count: Integer): UInt32;
function GTBTBuildPatternPayload(const i_Size: Integer): TBytes;
function GTBTBytesEqual(const arr_Left: TBytes; const arr_Right: TBytes): Boolean;
function GTBTSanitizeFileName(const s_FileName: string): string;

implementation

var
  arrCrcTable: array[0..255] of UInt32;

{ ============================================================================ }
{ CRC32                                                                        }
{ ============================================================================ }

procedure DoBuildCrcTable;
var
  dwEntry: UInt32;
  iTableIndex: Integer;
  iBitIndex: Integer;
begin
  for iTableIndex := 0 to 255 do
  begin
    dwEntry := UInt32(iTableIndex);
    for iBitIndex := 0 to 7 do
    begin
      if (dwEntry and 1) <> 0 then
        dwEntry := (dwEntry shr 1) xor $EDB88320
      else
        dwEntry := dwEntry shr 1;
    end;
    arrCrcTable[iTableIndex] := dwEntry;
  end;
end;

function GTBTCrc32(const arr_Data: TBytes; const i_Offset: Integer;
  const i_Count: Integer): UInt32;
var
  iIndex: Integer;
begin
  Result := $FFFFFFFF;
  for iIndex := i_Offset to i_Offset + i_Count - 1 do
    Result := arrCrcTable[(Result xor arr_Data[iIndex]) and $FF] xor (Result shr 8);
  Result := Result xor $FFFFFFFF;
end;

{ ============================================================================ }
{ PRIVATE READ HELPERS - bounds-checked cursor reads                           }
{ ============================================================================ }

function DoReadUInt32(const arr_Data: TBytes; var i_Offset: Integer;
  out dw_Value: UInt32): Boolean;
begin
  Result := False;
  dw_Value := 0;
  if i_Offset + 4 > Length(arr_Data) then
    Exit;
  Move(arr_Data[i_Offset], dw_Value, 4);
  Inc(i_Offset, 4);
  Result := True;
end;

function DoReadInt64(const arr_Data: TBytes; var i_Offset: Integer;
  out i64_Value: Int64): Boolean;
begin
  Result := False;
  i64_Value := 0;
  if i_Offset + 8 > Length(arr_Data) then
    Exit;
  Move(arr_Data[i_Offset], i64_Value, 8);
  Inc(i_Offset, 8);
  Result := True;
end;

function DoReadBytes(const arr_Data: TBytes; var i_Offset: Integer;
  const i_Count: Integer; out arr_Value: TBytes): Boolean;
begin
  Result := False;
  arr_Value := nil;
  if (i_Count < 0) or (i_Offset + i_Count > Length(arr_Data)) then
    Exit;
  SetLength(arr_Value, i_Count);
  if i_Count > 0 then
    Move(arr_Data[i_Offset], arr_Value[0], i_Count);
  Inc(i_Offset, i_Count);
  Result := True;
end;

{ ============================================================================ }
{ FRAME BUILDING                                                               }
{ ============================================================================ }

function GTBTBuildFrame(const by_FrameType: Byte;
  const arr_Payload: TBytes): TBytes;
var
  dwPayloadLength: UInt32;
  dwCrc: UInt32;
  iPayloadLength: Integer;
  iTotalSize: Integer;
begin
  iPayloadLength := Length(arr_Payload);
  if iPayloadLength > GTBT_MAX_PAYLOAD_SIZE then
    raise EGTBTProtocolError.CreateFmt(
      'Payload of %d bytes exceeds the %d byte frame limit',
      [iPayloadLength, GTBT_MAX_PAYLOAD_SIZE]);

  dwPayloadLength := UInt32(iPayloadLength);
  iTotalSize := GTBT_FRAME_HEADER_SIZE + iPayloadLength + GTBT_FRAME_TRAILER_SIZE;
  SetLength(Result, iTotalSize);

  Result[0] := Ord('G');
  Result[1] := Ord('T');
  Result[2] := Ord('B');
  Result[3] := Ord('T');
  Result[4] := GTBT_PROTOCOL_VERSION;
  Result[5] := by_FrameType;
  Move(dwPayloadLength, Result[6], 4);

  if iPayloadLength > 0 then
    Move(arr_Payload[0], Result[GTBT_FRAME_HEADER_SIZE], iPayloadLength);

  // CRC covers version + type + length + payload (everything after the magic)
  dwCrc := GTBTCrc32(Result, 4, 6 + iPayloadLength);
  Move(dwCrc, Result[iTotalSize - GTBT_FRAME_TRAILER_SIZE], 4);
end;

function GTBTFrameTypeName(const by_FrameType: Byte): string;
begin
  case by_FrameType of
    GTBT_FRAME_TEXT:        Result := 'TEXT';
    GTBT_FRAME_PING:        Result := 'PING';
    GTBT_FRAME_PONG:        Result := 'PONG';
    GTBT_FRAME_FILE_OFFER:  Result := 'FILE_OFFER';
    GTBT_FRAME_FILE_ACCEPT: Result := 'FILE_ACCEPT';
    GTBT_FRAME_FILE_REJECT: Result := 'FILE_REJECT';
    GTBT_FRAME_FILE_CHUNK:  Result := 'FILE_CHUNK';
    GTBT_FRAME_CHUNK_ACK:   Result := 'CHUNK_ACK';
    GTBT_FRAME_FILE_RESULT: Result := 'FILE_RESULT';
    GTBT_FRAME_ABORT:       Result := 'ABORT';
  else
    Result := Format('UNKNOWN($%.2x)', [by_FrameType]);
  end;
end;

{ ============================================================================ }
{ TGTBTFrameParser                                                             }
{ ============================================================================ }

procedure TGTBTFrameParser.Reset;
begin
  Self.FiBufferUsed := 0;
  Self.FsLastError := '';
end;

procedure TGTBTFrameParser.Append(const arr_Data: TBytes);
var
  iIncoming: Integer;
  iNeeded: Integer;
  iNewCapacity: Integer;
begin
  iIncoming := Length(arr_Data);
  if iIncoming = 0 then
    Exit;

  iNeeded := Self.FiBufferUsed + iIncoming;
  if iNeeded > Length(Self.FarrBuffer) then
  begin
    iNewCapacity := Length(Self.FarrBuffer) * 2;
    if iNewCapacity < 65536 then
      iNewCapacity := 65536;
    while iNewCapacity < iNeeded do
      iNewCapacity := iNewCapacity * 2;
    SetLength(Self.FarrBuffer, iNewCapacity);
  end;

  Move(arr_Data[0], Self.FarrBuffer[Self.FiBufferUsed], iIncoming);
  Inc(Self.FiBufferUsed, iIncoming);
end;

procedure TGTBTFrameParser.DoDiscardBytes(const i_ByteCount: Integer);
var
  iRemaining: Integer;
begin
  iRemaining := Self.FiBufferUsed - i_ByteCount;
  if iRemaining > 0 then
    Move(Self.FarrBuffer[i_ByteCount], Self.FarrBuffer[0], iRemaining);
  Self.FiBufferUsed := iRemaining;
end;

function TGTBTFrameParser.TryReadFrame(out rec_Frame: TGTBTFrame): TGTBTParseResult;
var
  dwPayloadLength: UInt32;
  dwStoredCrc: UInt32;
  dwComputedCrc: UInt32;
  iPayloadLength: Integer;
  iFrameSize: Integer;
begin
  Result := prNeedMoreData;
  rec_Frame.byFrameType := 0;
  rec_Frame.arrPayload := nil;

  // Not even a full header yet
  if Self.FiBufferUsed < GTBT_FRAME_HEADER_SIZE then
    Exit;

  if (Self.FarrBuffer[0] <> Ord('G')) or (Self.FarrBuffer[1] <> Ord('T')) or
     (Self.FarrBuffer[2] <> Ord('B')) or (Self.FarrBuffer[3] <> Ord('T')) then
  begin
    Self.FsLastError := 'Frame does not start with GTBT magic';
    Result := prCorruptStream;
    Exit;
  end;

  if Self.FarrBuffer[4] <> GTBT_PROTOCOL_VERSION then
  begin
    Self.FsLastError := Format('Protocol version %d received, version %d expected',
      [Self.FarrBuffer[4], GTBT_PROTOCOL_VERSION]);
    Result := prCorruptStream;
    Exit;
  end;

  dwPayloadLength := 0;
  Move(Self.FarrBuffer[6], dwPayloadLength, 4);
  if dwPayloadLength > GTBT_MAX_PAYLOAD_SIZE then
  begin
    Self.FsLastError := Format('Frame claims a %u byte payload (limit %d)',
      [dwPayloadLength, GTBT_MAX_PAYLOAD_SIZE]);
    Result := prCorruptStream;
    Exit;
  end;

  iPayloadLength := Integer(dwPayloadLength);
  iFrameSize := GTBT_FRAME_HEADER_SIZE + iPayloadLength + GTBT_FRAME_TRAILER_SIZE;

  // Header is here but the rest of the frame has not arrived yet
  if Self.FiBufferUsed < iFrameSize then
    Exit;

  dwStoredCrc := 0;
  Move(Self.FarrBuffer[iFrameSize - GTBT_FRAME_TRAILER_SIZE], dwStoredCrc, 4);
  dwComputedCrc := GTBTCrc32(Self.FarrBuffer, 4, 6 + iPayloadLength);
  if dwStoredCrc <> dwComputedCrc then
  begin
    Self.FsLastError := Format('CRC mismatch on %s frame',
      [GTBTFrameTypeName(Self.FarrBuffer[5])]);
    Result := prCorruptStream;
    Exit;
  end;

  rec_Frame.byFrameType := Self.FarrBuffer[5];
  SetLength(rec_Frame.arrPayload, iPayloadLength);
  if iPayloadLength > 0 then
    Move(Self.FarrBuffer[GTBT_FRAME_HEADER_SIZE], rec_Frame.arrPayload[0],
      iPayloadLength);

  // Remove this frame; anything after it stays in the buffer for the next call
  Self.DoDiscardBytes(iFrameSize);
  Result := prFrameReady;
end;

{ ============================================================================ }
{ PAYLOADS                                                                     }
{ ============================================================================ }

function GTBTBuildFileOfferPayload(const rec_Offer: TGTBTFileOffer): TBytes;
var
  arrNameBytes: TBytes;
  dwNameLength: UInt32;
  iNameLength: Integer;
  iOffset: Integer;
begin
  if Length(rec_Offer.arrFileHash) <> GTBT_HASH_SIZE then
    raise EGTBTProtocolError.Create('File offer needs a 32 byte SHA-256 hash');

  arrNameBytes := TEncoding.UTF8.GetBytes(rec_Offer.sFileName);
  iNameLength := Length(arrNameBytes);
  if (iNameLength = 0) or (iNameLength > GTBT_MAX_FILE_NAME_BYTES) then
    raise EGTBTProtocolError.Create('File name is empty or too long');

  dwNameLength := UInt32(iNameLength);

  // name length (4) + name (N) + file size (8) + hash (32) + chunk size (4)
  SetLength(Result, 4 + iNameLength + 8 + GTBT_HASH_SIZE + 4);
  iOffset := 0;

  Move(dwNameLength, Result[iOffset], 4);
  Inc(iOffset, 4);

  Move(arrNameBytes[0], Result[iOffset], iNameLength);
  Inc(iOffset, iNameLength);

  Move(rec_Offer.i64FileSize, Result[iOffset], 8);
  Inc(iOffset, 8);

  Move(rec_Offer.arrFileHash[0], Result[iOffset], GTBT_HASH_SIZE);
  Inc(iOffset, GTBT_HASH_SIZE);

  Move(rec_Offer.dwChunkSize, Result[iOffset], 4);
end;

function GTBTParseFileOfferPayload(const arr_Payload: TBytes;
  out rec_Offer: TGTBTFileOffer): Boolean;
var
  arrNameBytes: TBytes;
  dwNameLength: UInt32;
  iOffset: Integer;
begin
  Result := False;
  rec_Offer.sFileName := '';
  rec_Offer.i64FileSize := 0;
  rec_Offer.arrFileHash := nil;
  rec_Offer.dwChunkSize := 0;
  iOffset := 0;

  if not DoReadUInt32(arr_Payload, iOffset, dwNameLength) then
    Exit;
  if (dwNameLength = 0) or (dwNameLength > GTBT_MAX_FILE_NAME_BYTES) then
    Exit;
  if not DoReadBytes(arr_Payload, iOffset, Integer(dwNameLength), arrNameBytes) then
    Exit;
  rec_Offer.sFileName := TEncoding.UTF8.GetString(arrNameBytes);

  if not DoReadInt64(arr_Payload, iOffset, rec_Offer.i64FileSize) then
    Exit;
  if not DoReadBytes(arr_Payload, iOffset, GTBT_HASH_SIZE, rec_Offer.arrFileHash) then
    Exit;
  if not DoReadUInt32(arr_Payload, iOffset, rec_Offer.dwChunkSize) then
    Exit;

  // Exactly consumed - no trailing junk allowed
  Result := (iOffset = Length(arr_Payload));
end;

function GTBTBuildChunkPayload(const dw_ChunkIndex: UInt32;
  const arr_Data: TBytes; const i_DataLength: Integer): TBytes;
begin
  if (i_DataLength < 0) or (i_DataLength > Length(arr_Data)) then
    raise EGTBTProtocolError.Create('Chunk length is outside the data buffer');

  SetLength(Result, 4 + i_DataLength);
  Move(dw_ChunkIndex, Result[0], 4);
  if i_DataLength > 0 then
    Move(arr_Data[0], Result[4], i_DataLength);
end;

function GTBTParseChunkPayload(const arr_Payload: TBytes;
  out dw_ChunkIndex: UInt32; out arr_Data: TBytes): Boolean;
var
  iOffset: Integer;
begin
  Result := False;
  arr_Data := nil;
  iOffset := 0;

  if not DoReadUInt32(arr_Payload, iOffset, dw_ChunkIndex) then
    Exit;

  Result := DoReadBytes(arr_Payload, iOffset, Length(arr_Payload) - iOffset, arr_Data);
end;

function GTBTBuildUInt32Payload(const dw_Value: UInt32): TBytes;
begin
  SetLength(Result, 4);
  Move(dw_Value, Result[0], 4);
end;

function GTBTParseUInt32Payload(const arr_Payload: TBytes;
  out dw_Value: UInt32): Boolean;
var
  iOffset: Integer;
begin
  iOffset := 0;
  Result := DoReadUInt32(arr_Payload, iOffset, dw_Value) and
    (iOffset = Length(arr_Payload));
end;

function GTBTBuildResultPayload(const by_ResultCode: Byte;
  const s_Detail: string): TBytes;
var
  arrDetailBytes: TBytes;
begin
  arrDetailBytes := TEncoding.UTF8.GetBytes(s_Detail);
  SetLength(Result, 1 + Length(arrDetailBytes));
  Result[0] := by_ResultCode;
  if Length(arrDetailBytes) > 0 then
    Move(arrDetailBytes[0], Result[1], Length(arrDetailBytes));
end;

function GTBTParseResultPayload(const arr_Payload: TBytes;
  out by_ResultCode: Byte; out s_Detail: string): Boolean;
var
  arrDetailBytes: TBytes;
  iOffset: Integer;
begin
  Result := False;
  by_ResultCode := 0;
  s_Detail := '';

  if Length(arr_Payload) < 1 then
    Exit;

  by_ResultCode := arr_Payload[0];
  iOffset := 1;
  if not DoReadBytes(arr_Payload, iOffset, Length(arr_Payload) - 1, arrDetailBytes) then
    Exit;

  s_Detail := GTBTParseTextPayload(arrDetailBytes);
  Result := True;
end;

function GTBTBuildTextPayload(const s_Text: string): TBytes;
begin
  Result := TEncoding.UTF8.GetBytes(s_Text);
end;

function GTBTParseTextPayload(const arr_Payload: TBytes): string;
begin
  if Length(arr_Payload) = 0 then
    Result := ''
  else
    Result := TEncoding.UTF8.GetString(arr_Payload);
end;

{ ============================================================================ }
{ HELPERS                                                                      }
{ ============================================================================ }

function GTBTBuildPatternPayload(const i_Size: Integer): TBytes;
var
  iIndex: Integer;
begin
  // Predictable, non-repeating-on-256 pattern so a shifted or dropped byte shows up
  SetLength(Result, i_Size);
  for iIndex := 0 to i_Size - 1 do
    Result[iIndex] := Byte(iIndex mod 251);
end;

function GTBTBytesEqual(const arr_Left: TBytes; const arr_Right: TBytes): Boolean;
var
  iIndex: Integer;
begin
  Result := False;
  if Length(arr_Left) <> Length(arr_Right) then
    Exit;

  for iIndex := 0 to Length(arr_Left) - 1 do
  begin
    if arr_Left[iIndex] <> arr_Right[iIndex] then
      Exit;
  end;

  Result := True;
end;

function GTBTSanitizeFileName(const s_FileName: string): string;
var
  iIndex: Integer;
  iLastDelimiter: Integer;
  chCurrent: Char;
begin
  // Keep only what follows the last path separator, whichever platform sent it,
  // so a name like ..\..\evil.exe can never leave the receive folder.
  iLastDelimiter := LastDelimiter('\/:', s_FileName);
  Result := Trim(Copy(s_FileName, iLastDelimiter + 1, MaxInt));

  for iIndex := 1 to Length(Result) do
  begin
    chCurrent := Result[iIndex];
    if (chCurrent < ' ') or CharInSet(chCurrent, ['<', '>', '"', '|', '?', '*']) then
      Result[iIndex] := '_';
  end;

  if (Result = '') or (Result = '.') or (Result = '..') then
    Result := 'received.bin';
end;

initialization
  DoBuildCrcTable;

end.
