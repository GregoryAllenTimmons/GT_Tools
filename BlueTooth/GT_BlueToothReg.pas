unit GT_BlueToothReg;

{===============================================================================
  GT_BlueToothReg - registers TGT_BlueTooth on the "GT Tools" palette tab
  Author: Greg Timmons

  Add this unit to the design-time package only (not to applications).
===============================================================================}

interface

procedure Register;

implementation

uses
  System.Classes,
  GT_BlueTooth;

procedure Register;
begin
  RegisterComponents('GT Tools', [TGT_BlueTooth]);
end;

end.
