unit FastLocks;

interface

uses
  AuxTypes;

const
  DefaultWaitSpinCount = 1500; // around 100us (microseconds) on C2D T7100 @1.8GHz

type
  TFLWaitMethod = Function(Reserved: Boolean): Boolean of object;
  TFLReserveMethod = procedure of object;

  TFLWaitResult = (wrAcquired,wrTimeOut,wrError);

  TFastLock = class(TObject)
  protected
    fMainFlag:      Integer;
    fWaitSpinCount: UInt32;
    fPerfCntFreq:   Int64;
    Function SpinOn(SpinCount: UInt32; WaitMethod: TFLWaitMethod; Reserve: TFLReserveMethod = nil; Unreserve: TFLReserveMethod = nil): TFLWaitResult; virtual;
    Function WaitOn(TimeOut: UInt32; WaitMethod: TFLWaitMethod; WaitSpin: Boolean = True; Reserve: TFLReserveMethod = nil; Unreserve: TFLReserveMethod = nil): TFLWaitResult; virtual;
  public
    constructor Create(WaitSpinCount: UInt32 = DefaultWaitSpinCount); virtual;
  published
    property WaitSpinCount: UInt32 read fWaitSpinCount;
  end;

  TFastCriticalSection = class(TFastLock)
  protected
    Function Acquire(Reserved: Boolean): Boolean; virtual;
    procedure Release; virtual;
    procedure Reserve; virtual;
    procedure Unreserve; virtual;
  public
    Function Enter: Boolean; virtual;
    procedure Leave; virtual;
    Function SpinToEnter(SpinCount: UInt32; Reservation: Boolean = True): TFLWaitResult; virtual;
    Function WaitToEnter(Timeout: UInt32; WaitSpin: Boolean = True; Reservation: Boolean = True): TFLWaitResult; virtual;
  end;

implementation

uses
  Windows, SysUtils;

const
  FASTLOCK_UNLOCKED = Integer(0);

  FASTLOCK_CS_RESERVEDELTA = Integer($100);

//==============================================================================

Function TFastLock.SpinOn(SpinCount: UInt32; WaitMethod: TFLWaitMethod; Reserve: TFLReserveMethod = nil; Unreserve: TFLReserveMethod = nil): TFLWaitResult;

  Function Spin: Boolean;
  begin
    If SpinCount <> INFINITE then
      Dec(SpinCount);
    Result := SpinCount > 0;
  end;

  Function InternalSpin(Reserved: Boolean): TFLWaitResult;
  begin
    while not WaitMethod(Reserved) do
      If not Spin then
        begin
          Result := wrTimeout;
          Exit;
        end;
    Result := wrAcquired;
  end;

begin
try
  If Assigned(Reserve) and Assigned(Unreserve) then
    begin
      Reserve;
      try
        Result := InternalSpin(True);
      finally
        Unreserve;
      end;
    end
  else Result := InternalSpin(False);
except
  Result := wrError;
end;
end;

//------------------------------------------------------------------------------

Function TFastLock.WaitOn(TimeOut: UInt32; WaitMethod: TFLWaitMethod; WaitSpin: Boolean = True; Reserve: TFLReserveMethod = nil; Unreserve: TFLReserveMethod = nil): TFLWaitResult;
var
  StartCount: Int64;

  Function GetElapsedMillis: UInt32;
  var
    CurrentCount: Int64;
  begin
    QueryPerformanceCounter(CurrentCount);
    If CurrentCount < StartCount then
      Result := ((High(Int64) - StartCount + CurrentCount) * 1000) div fPerfCntFreq
    else
      Result := ((CurrentCount - StartCount) * 1000) div fPerfCntFreq;
  end;

  Function InternalWait(Reserved: Boolean): TFLWaitResult;
  begin
    while not WaitMethod(Reserved) do
      If GetElapsedMillis >= TimeOut then
        begin
          Result := wrTimeout;
          Exit;
        end
      else
        begin
          If WaitSpin then
            If SpinOn(fWaitSpinCount,WaitMethod,Reserve,Unreserve) = wrAcquired then
              Break{while};
        end;
    Result := wrAcquired;
  end;

begin
If TimeOut = INFINITE then
  Result := SpinOn(INFINITE,WaitMethod,Reserve,Unreserve)
else
  begin
    If QueryPerformanceCounter(StartCount) then
      begin
        If Assigned(Reserve) and Assigned(Unreserve) then
          begin
            Reserve;
            try
              Result := InternalWait(True);
            finally
              Unreserve;
            end;
          end
        else Result := InternalWait(False);
      end
    else Result := wrError;
  end;
end;

//==============================================================================

constructor TFastLock.Create(WaitSpinCount: UInt32 = DefaultWaitSpinCount);
begin
inherited Create;
fMainFlag := FASTLOCK_UNLOCKED;
fWaitSpinCount := WaitSpinCount;
If not QueryPerformanceFrequency(fPerfCntFreq) then
  raise Exception.CreateFmt('TFastLock.Create: Cannot obtain performance counter frequency (0x%.8x).',[GetLastError]);
end;

//******************************************************************************

Function TFastCriticalSection.Acquire(Reserved: Boolean): Boolean;
var
  OldFlagValue: Integer;
begin
OldFlagValue := InterlockedExchangeAdd(fMainFlag,1);
If Reserved then
  Result := (OldFlagValue and $FF) = FASTLOCK_UNLOCKED
else
  Result := OldFlagValue = FASTLOCK_UNLOCKED;
If not Result then
  InterlockedDecrement(fMainFlag);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Release;
begin
InterlockedDecrement(fMainFlag);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Reserve;
begin
InterlockedExchangeAdd(fMainFlag,FASTLOCK_CS_RESERVEDELTA);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Unreserve;
begin
InterlockedExchangeAdd(fMainFlag,-FASTLOCK_CS_RESERVEDELTA);
end;

//==============================================================================

Function TFastCriticalSection.Enter: Boolean;
begin
Result := Acquire(False);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Leave;
begin
Release;
end;

//------------------------------------------------------------------------------

Function TFastCriticalSection.SpinToEnter(SpinCount: UInt32; Reservation: Boolean = True): TFLWaitResult;
begin
If Reservation then
  Result := SpinOn(SpinCount,Acquire,Reserve,Unreserve)
else
  Result := SpinOn(SpinCount,Acquire,nil,nil);
end;

//------------------------------------------------------------------------------

Function TFastCriticalSection.WaitToEnter(Timeout: UInt32; WaitSpin: Boolean = True; Reservation: Boolean = True): TFLWaitResult;
begin
If Reservation then
  Result := WaitOn(Timeout,Acquire,WaitSpin,Reserve,Unreserve)
else
  Result := WaitOn(Timeout,Acquire,WaitSpin,nil,nil);
end;

end.
