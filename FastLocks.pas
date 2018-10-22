{-------------------------------------------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

-------------------------------------------------------------------------------}
{===============================================================================

  FastLocks

    Non-blocking synchronization objects based on interlocked functions
    operating on locking flag(s).

  ©František Milt 2018-10-21

  Version 1.0.1 alpha (needs extensive testing)

  Notes:
    - provided synchronizers are non-blocking - acquire operation returns
      immediatelly and its result signals whether the synchronizer was acquired
      or not
    - there is absolutely no deadlock prevention - be extremely carefull when
      trying to acquire synchronizer in more than one place in a single thread
      (trying to acquire synchronizer second time in the same thread will fail,
      with exception being MREW reading, which is given by concept of multiple
      readers access)
    - use provided wait methods only when necessary - synchronizers are intended
      to be used as non blocking
    - waiting is always active (spinning) - do not wait for prolonged time
      intervals as it might starve other threads; use infinite waiting only in
      extreme cases and only when really necessary
    - use synchronization by provided objects only on very short (in time,
      not code) routines - do not use to synchronize code that is executing
      longer than few milliseconds
    - every acquire of a synchronizer MUST be paired by a release, synhronizers
      are not automalically released

  Dependencies:
    AuxTypes   - github.com/ncs-sniper/Lib.AuxTypes
    AuxClasses - github.com/ncs-sniper/Lib.AuxClasses

--------------------------------------------------------------------------------

  Example on how to use non-blocking character of provided objects:

 -->  // some code
 |    If CritSect.Enter then
 |      try
 |        // synchronized code
 |      finally
 |        CritSect.Leave;
 |      end
 |    else
 |      begin
 |       // synchronization not possible, do other things that does not need
 |       // to be synchronized
 |      end;
 |    // some code
 --   // repeat from start and try synchronization again if needed

===============================================================================}
unit FastLocks;

{$IFDEF FPC}
  {$MODE Delphi}
  {$DEFINE FPC_DisableWarns}
  {$MACRO ON}
{$ENDIF}

interface

uses
  AuxTypes, AuxClasses;

const
  DefaultWaitSpinCount = 1500; // around 100us (microseconds) on C2D T7100 @1.8GHz

type
  TFLWaitMethod = Function(Reserved: Boolean): Boolean of object;
  TFLReserveMethod = procedure of object;

  TFLWaitResult = (wrAcquired,wrTimeOut,wrError);

{==============================================================================}
{------------------------------------------------------------------------------}
{                                   TFastLock                                  }
{------------------------------------------------------------------------------}
{==============================================================================}

  TFastLock = class(TCustomObject)
  protected
    fMainFlag:      Integer;
    fWaitSpinCount: UInt32;
    fPerfCntFreq:   Int64;
    Function SpinOn(SpinCount: UInt32; WaitMethod: TFLWaitMethod; Reserve: TFLReserveMethod = nil; Unreserve: TFLReserveMethod = nil): TFLWaitResult; virtual;
    Function WaitOn(TimeOut: UInt32; WaitMethod: TFLWaitMethod; WaitSpin: Boolean = True; Reserve: TFLReserveMethod = nil; Unreserve: TFLReserveMethod = nil): TFLWaitResult; virtual;
  public
    constructor Create(WaitSpinCount: UInt32 = DefaultWaitSpinCount); virtual;
    property WaitSpinCount: UInt32 read fWaitSpinCount;
  end;

{==============================================================================}
{------------------------------------------------------------------------------}
{                             TFastCriticalSection                             }
{------------------------------------------------------------------------------}
{==============================================================================}

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

{==============================================================================}
{------------------------------------------------------------------------------}
{                   TFastMultiReadExclusiveWriteSynchronizer                   }
{------------------------------------------------------------------------------}
{==============================================================================}

  TFastMultiReadExclusiveWriteSynchronizer = class(TFastLock)
  protected
    Function AcquireRead(Reserved: Boolean): Boolean; virtual;
    procedure ReleaseRead; virtual;
    Function AcquireWrite(Reserved: Boolean): Boolean; virtual;
    procedure ReleaseWrite; virtual;
    procedure ReserveWrite; virtual;
    procedure UnreserveWrite; virtual;
  public
    Function BeginRead: Boolean; virtual;
    procedure EndRead; virtual;
    Function BeginWrite: Boolean; virtual;
    procedure EndWrite; virtual;
    Function SpinToRead(SpinCount: UInt32): TFLWaitResult; virtual;
    Function WaitToRead(Timeout: UInt32; WaitSpin: Boolean = True): TFLWaitResult; virtual;
    Function SpinToWrite(SpinCount: UInt32; Reservation: Boolean = True): TFLWaitResult; virtual;
    Function WaitToWrite(Timeout: UInt32; WaitSpin: Boolean = True; Reservation: Boolean = True): TFLWaitResult; virtual;
  end;

  TFastMREW = TFastMultiReadExclusiveWriteSynchronizer;

implementation

uses
  Windows, SysUtils;

{$IFDEF FPC_DisableWarns}
  {$DEFINE FPCDWM}
  {$DEFINE W4055:={$WARN 4055 OFF}} // Conversion between ordinals and pointers is not portable
  {$DEFINE W5024:={$WARN 5024 OFF}} // Parameter "$1" not used
  {$DEFINE W5057:={$WARN 5057 OFF}} // Local variable "$1" does not seem to be initialized
{$ENDIF}

{==============================================================================}
{   Imlementation constants                                                    }
{==============================================================================}

const
  FASTLOCK_UNLOCKED = Integer(0);

{
  Meaning of bits in main flag word in TFastCriticaSection:

    bit 0..7  - acquire count
    bit 8..31 - reserve count
}
  FASTLOCK_CS_ACQUIREDELTA    = 1;
  FASTLOCK_CS_ACQUIREMASK     = Integer($000000FF);
  FASTLOCK_CS_ERRACQUIRECOUNT = 200;
  FASTLOCK_CS_RESERVEDELTA    = Integer($100);
  FASTLOCK_CS_RESERVEMAX      = 750000 {must be lower than $FFFFF (1048575)};
  FASTLOCK_CS_RESERVEMASK     = Integer($0FFFFF00);
  FASTLOCK_CS_RESERVEBITSHIFT = 8;

{
  Meaning of bits in main flag word in TFastMultiReadExclusiveWriteSynchronizer:

    bit 0..13   - read count
    bit 14..27  - write reservation count
    bit 28..31  - write count
}
  FASTLOCK_MREW_MAXREADERS           = 10000 {must be lower than $3FFF (16383)};
  FASTLOCK_MREW_READERDELTA          = 1;
  FASTLOCK_MREW_WRITERESERVEDELTA    = Integer($4000);
  FASTLOCK_MREW_WRITERESERVEMAX      = 10000 {must be lower than $3FFF (16383)};
  FASTLOCK_MREW_WRITERESERVEMASK     = Integer($0FFFC000);
  FASTLOCK_MREW_WRITERESERVEBITSHIFT = 14;
  FASTLOCK_MREW_WRITEDELTA           = Integer($10000000);
  FASTLOCK_MREW_WRITEBITSHIFT        = 28;
  FASTLOCK_MREW_ERRWRITECOUNT        = 8;

{==============================================================================}
{------------------------------------------------------------------------------}
{                                   TFastLock                                  }
{------------------------------------------------------------------------------}
{==============================================================================}

{==============================================================================}
{   TFastLock - implementation                                                 }
{==============================================================================}

{------------------------------------------------------------------------------}
{   TFastLock - protected methods                                              }
{------------------------------------------------------------------------------}

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

{$IFDEF FPCDWM}{$PUSH}W5057{$ENDIF}
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
{$IFDEF FPCDWM}{$POP}{$ENDIF}

{------------------------------------------------------------------------------}
{   TFastLock - public methods                                                 }
{------------------------------------------------------------------------------}

constructor TFastLock.Create(WaitSpinCount: UInt32 = DefaultWaitSpinCount);
begin
inherited Create;
fMainFlag := FASTLOCK_UNLOCKED;
{$IFDEF FPCDWM}{$PUSH}W4055{$ENDIF}
If (PtrUInt(Addr(fMainFlag)) and 3) <> 0 then
{$IFDEF FPCDWM}{$POP}{$ENDIF}
  raise Exception.CreateFmt('TFastLock.Create: Main flag (0x%p) is not properly aligned.',[Addr(fMainFlag)]);
fWaitSpinCount := WaitSpinCount;
If not QueryPerformanceFrequency(fPerfCntFreq) then
  raise Exception.CreateFmt('TFastLock.Create: Cannot obtain performance counter frequency (0x%.8x).',[GetLastError]);
end;


{==============================================================================}
{------------------------------------------------------------------------------}
{                             TFastCriticalSection                             }
{------------------------------------------------------------------------------}
{==============================================================================}

{==============================================================================}
{   TFastCriticalSection - implementation                                      }
{==============================================================================}

{------------------------------------------------------------------------------}
{   TFastCriticalSection - protected methods                                   }
{------------------------------------------------------------------------------}

Function TFastCriticalSection.Acquire(Reserved: Boolean): Boolean;
var
  OldFlagValue: Integer;
begin
OldFlagValue := InterlockedExchangeAdd(fMainFlag,FASTLOCK_CS_ACQUIREDELTA);
If (OldFlagValue and FASTLOCK_CS_ACQUIREMASK) <= FASTLOCK_CS_ERRACQUIRECOUNT then
  begin
    If Reserved then
      Result := (OldFlagValue and FASTLOCK_CS_ACQUIREMASK) = FASTLOCK_UNLOCKED
    else
      Result := OldFlagValue = FASTLOCK_UNLOCKED;
  end
else Result := False;
If not Result then
  InterlockedExchangeAdd(fMainFlag,-FASTLOCK_CS_ACQUIREDELTA);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Release;
begin
InterlockedExchangeAdd(fMainFlag,-FASTLOCK_CS_ACQUIREDELTA);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Reserve;
var
  OldFlagValue: Integer;
begin
OldFlagValue := InterlockedExchangeAdd(fMainFlag,FASTLOCK_CS_RESERVEDELTA);
If ((OldFlagValue and FASTLOCK_CS_RESERVEMASK) shr FASTLOCK_CS_RESERVEBITSHIFT) > FASTLOCK_CS_RESERVEMAX then
  raise Exception.CreateFmt('TFastCriticalSection.Reserve: Cannot reserve critical section (%d).',
                            [(OldFlagValue and FASTLOCK_CS_RESERVEMASK) shr FASTLOCK_CS_RESERVEBITSHIFT]);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Unreserve;
begin
InterlockedExchangeAdd(fMainFlag,-FASTLOCK_CS_RESERVEDELTA);
end;

{------------------------------------------------------------------------------}
{   TFastCriticalSection - public methods                                      }
{------------------------------------------------------------------------------}

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


{==============================================================================}
{------------------------------------------------------------------------------}
{                   TFastMultiReadExclusiveWriteSynchronizer                   }
{------------------------------------------------------------------------------}
{==============================================================================}

{==============================================================================}
{   TFastMultiReadExclusiveWriteSynchronizer - implementation                  }
{==============================================================================}

{------------------------------------------------------------------------------}
{   TFastMultiReadExclusiveWriteSynchronizer - protected methods               }
{------------------------------------------------------------------------------}

{$IFDEF FPCDWM}{$PUSH}W5024{$ENDIF}
Function TFastMultiReadExclusiveWriteSynchronizer.AcquireRead(Reserved: Boolean): Boolean;
begin
Result := InterlockedExchangeAdd(fMainFlag,FASTLOCK_MREW_READERDELTA) <= FASTLOCK_MREW_MAXREADERS;
If not Result then
  InterlockedExchangeAdd(fMainFlag,-FASTLOCK_MREW_READERDELTA);
end;
{$IFDEF FPCDWM}{$POP}{$ENDIF}

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.ReleaseRead;
begin
InterlockedExchangeAdd(fMainFlag,-FASTLOCK_MREW_READERDELTA);
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.AcquireWrite(Reserved: Boolean): Boolean;
var
  OldFlagValue: Integer;
begin
OldFlagValue := InterlockedExchangeAdd(fMainFlag,FASTLOCK_MREW_WRITEDELTA);
If (OldFlagValue shr FASTLOCK_MREW_WRITEBITSHIFT) <= FASTLOCK_MREW_ERRWRITECOUNT then
  begin
    If Reserved then
      Result := OldFlagValue and not FASTLOCK_MREW_WRITERESERVEMASK = FASTLOCK_UNLOCKED
    else
      Result := OldFlagValue = FASTLOCK_UNLOCKED;
  end
else Result := False;
If not Result then
  InterlockedExchangeAdd(fMainFlag,-FASTLOCK_MREW_WRITEDELTA);
end;

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.ReleaseWrite;
begin
InterlockedExchangeAdd(fMainFlag,-FASTLOCK_MREW_WRITEDELTA)
end;

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.ReserveWrite;
var
  OldFlagValue: Integer;
begin
OldFlagValue := InterlockedExchangeAdd(fMainFlag,FASTLOCK_MREW_WRITERESERVEDELTA);
If ((OldFlagValue and FASTLOCK_MREW_WRITERESERVEMASK) shr FASTLOCK_MREW_WRITERESERVEBITSHIFT) > FASTLOCK_MREW_WRITERESERVEMAX then
  raise Exception.CreateFmt('TFastMultiReadExclusiveWriteSynchronizer.ReserveWrite: Cannot reserve MREW for writing (%d).',
                            [(OldFlagValue and FASTLOCK_MREW_WRITERESERVEMASK) shr FASTLOCK_MREW_WRITERESERVEBITSHIFT]);
end;

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.UnreserveWrite;
begin
InterlockedExchangeAdd(fMainFlag,-FASTLOCK_MREW_WRITERESERVEDELTA);
end;

{------------------------------------------------------------------------------}
{   TFastMultiReadExclusiveWriteSynchronizer - public methods                  }
{------------------------------------------------------------------------------}

Function TFastMultiReadExclusiveWriteSynchronizer.BeginRead: Boolean;
begin
Result := AcquireRead(False);
end;

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.EndRead;
begin
ReleaseRead;
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.BeginWrite: Boolean;
begin
Result := AcquireWrite(False);
end;

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.EndWrite;
begin
ReleaseWrite;
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.SpinToRead(SpinCount: UInt32): TFLWaitResult;
begin
Result := SpinOn(SpinCount,AcquireRead,nil,nil);
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.WaitToRead(Timeout: UInt32; WaitSpin: Boolean = True): TFLWaitResult;
begin
Result := WaitOn(Timeout,AcquireRead,WaitSpin,nil,nil);
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.SpinToWrite(SpinCount: UInt32; Reservation: Boolean = True): TFLWaitResult;
begin
If Reservation then
  Result := SpinOn(SpinCount,AcquireWrite,ReserveWrite,UnreserveWrite)
else
  Result := SpinOn(SpinCount,AcquireWrite,nil,nil);
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.WaitToWrite(Timeout: UInt32; WaitSpin: Boolean = True; Reservation: Boolean = True): TFLWaitResult;
begin
If Reservation then
  Result := WaitOn(Timeout,AcquireWrite,WaitSpin,ReserveWrite,UnreserveWrite)
else
  Result := WaitOn(Timeout,AcquireWrite,WaitSpin,nil,nil);
end;

end.

