# GT_Tools

Set of Delphi components and libraries by Greg Timmons. FMX, Windows and Android, Delphi 13 (should work on 11/12). MIT licensed.

| Component | Folder | What it does |
|---|---|---|
| `TGT_BlueTooth` | `BlueTooth/` | Classic Bluetooth (RFCOMM) link between two devices: text, ping, and SHA-256 verified file transfer |

---

## GT_BlueTooth

Transfers files between two paired devices (phone to phone, or Windows to phone) over Classic Bluetooth, with no server, no network and no third-party code. Only `System.Bluetooth` and `System.Hash` from the RTL.

Tested on a Pixel 6 (Android 12) (using Android 32-bit) and a Pixel 9 (Android 17 Build CP3A.261005.005) (using Android 64-bit), both directions, and from Windows 11 in a VMware® Workstation 17 Pro (version 17.6.3 build-24583834) guest to a phone.

### Layout

```
BlueTooth/
  GT_BlueToothProtocol.pas   wire format (frames, CRC32) - no Bluetooth in it
  GT_BlueToothLink.pas       one open RFCOMM connection + its read thread
  GT_BlueToothSession.pas    text, ping and file transfer over a link
  GT_BlueTooth.pas           the TGT_BlueTooth component wrapping the above
  GT_BlueToothReg.pas        palette registration ("GT Tools" tab)
  Example/                   ExampleMainForm.pas/.fmx - step-by-step test app
```

No package file is included; make your own (below). The three library units can also be used on their own without the component.

### Installing the component

1. File > New > Package. Save it wherever you keep component packages.
2. Add the five units from `BlueTooth/` to it (`GT_BlueToothReg.pas` is the only one that is design-time only). Add `rtl` and `fmx` to Requires if the IDE does not.
3. Build for Win32, then right-click the package in the Project Manager > Install. `TGT_BlueTooth` appears on the **GT Tools** tab.
4. In any project that uses it, add the `BlueTooth` folder to the search path (Project > Options > Building > Delphi Compiler > Search path) for each target platform, so the Android and Win64 builds find the units.

### Using it

1. Drop `TGT_BlueTooth` on a form. Keep the default name `GT_BlueTooth1` or rename it; the example form uses `GT_BlueTooth1`.
2. Wire the events you want in the Object Inspector: `OnLog`, `OnStateChanged`, `OnTextReceived`, `OnPingResult`, `OnTransferProgress`, `OnTransferFinished`. All fire on the main thread.
3. On Android 12 or newer, request `BLUETOOTH_CONNECT` and `BLUETOOTH_SCAN` at runtime before touching the component (same rule as Delphi's own `TBluetooth`). The example form shows how.
4. Pair the two devices in the system Bluetooth settings first. The component only works with paired devices.

```pascal
// one side
GT_BlueTooth1.Listen;

// other side
lstDevices := GT_BlueTooth1.GetPairedDevices;
GT_BlueTooth1.Connect(lstDevices[iIndex]);

// either side, once OnStateChanged reports lsConnected
GT_BlueTooth1.SendText('hello');
GT_BlueTooth1.SendPing(4096);
GT_BlueTooth1.SendFile('C:\path\to\file.bin');
```

Received files land in `ReceiveFolder` (default: `Download\GTBTReceived` on Android, `Documents\GTBTReceived` on Windows). A file is written to `name.part` and only renamed when its SHA-256 matches; a failed transfer leaves nothing behind. `OnTransferFinished` reports success or the reason.

### Properties

| Property | Default | Notes |
|---|---|---|
| `ChunkSize` | 16384 | bytes per chunk, 256 to 1 MB |
| `AckWindow` | 1 | 1 = wait for every chunk's ACK; higher lets the sender run ahead |
| `ReplyTimeoutMs` | 30000 | how long to wait for the other side |
| `ReadPollMs` | 500 | socket read poll interval |
| `SecureSocket` | True | require an authenticated pairing; leave on |
| `LogEveryRead` | False | log the size of every socket read (for diagnostics) |
| `ReceiveFolder` | empty | empty = platform default above |

`Link` and `Session` expose the underlying library objects for anything the component does not wrap.

### Example app

`Example/` is the test bench used to develop the component: numbered buttons for permissions, paired devices, listen/connect, text, ping, and file transfer, with every event written to a timestamped log you can save. Build it for both devices, tap Listen on one and Connect on the other, then work down the buttons.

To set it up: new Multi-Device Application, replace the default form with `ExampleMainForm`, add the `BlueTooth` folder to the search path, drop a `TGT_BlueTooth` on the form (it will be named `GT_BlueTooth1`), and wire its six events to the `GT_BlueTooth1_On...` handlers already in the unit. Tick the Bluetooth, Bluetooth admin, Bluetooth connect, Bluetooth scan and Access fine location permissions for Android.

### Things to know

- **Secure socket is not encryption of your data.** It only requires a verified pairing. The radio link is encrypted by Bluetooth itself, but your app receives plain bytes. Encrypt sensitive files yourself before `SendFile`.
- **Android gives no file dialog.** Picking a file is the app's job; the component takes a path.
- **VMware shared Bluetooth** can connect out to a phone but cannot listen, so in a VM the phone must be the listening side.
- **Throughput** measured so far: about 96 KB/s phone to phone with the defaults. Larger `AckWindow` values should help; measure with the example app.
- **One connection at a time.** Listen stops advertising once a peer connects.

### Wire format (GTBT v2)

Every message is one frame: `GTBT` magic, version byte, type byte, 4-byte payload length, payload, CRC32. The parser buffers partial reads, so it does not matter how the socket splits or merges data (Android was observed returning 16 KB chunks in roughly 1 KB pieces). A CRC failure closes the link rather than retrying, since RFCOMM already guarantees ordered delivery.

---

## License

MIT. See `LICENSE`.