{-------------------------------------------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

-------------------------------------------------------------------------------}
{===============================================================================

  FastLocks

    Non-blocking synchronization objects based on interlocked functions
    operating on locking flag(s).

    Notes:
      - provided synchronizers are non-blocking - acquire operation returns
        immediatelly and its result signals whether the synchronizer was
        acquired (True) or not (False)
      - as for all synchronizers, create one instace and pass it to all threads
        that need to use it (remember to free it only once)  
      - there is absolutely no deadlock prevention - be extremely carefull when
        trying to acquire synchronizer in more than one place in a single thread
        (trying to acquire synchronizer second time in the same thread will
        fail, ith exception being MREW reading, which is given by concept of
        multiple readers access)
      - use provided wait methods only when necessary - synchronizers are
        intended to be used as non blocking
      - waiting is always active (spinning) - do not wait for prolonged time
        intervals as it might starve other threads; use infinite waiting only
        in extreme cases and only when really necessary
      - use synchronization by provided objects only on very short (in time,
        not code) routines - do not use to synchronize code that is executing
        longer than few milliseconds
      - every successfull acquire of a synchronizer MUST be paired by a release,
        synhronizers are not automalically released
      - if synchronization flags are marked as reserved, then only synchronizers
        that are trying to acquire with reservation can acquire them, no
        synchronizer can acquire them if it is called withour reservation

    Example on how to properly use non-blocking character of provided objects:

                <unsynchronized_code>
           -->  If CritSect.Enter then
           |      try
           |        <synchronized_code>
           |      finally
           |        CritSect.Leave;
           |      end
           |    else
           |      begin           
           |        <code_not_needing_sync>
           |        synchronization not possible, do other things that
           |        do not need to be synchronized
           |      end;
           --   repeat from start and try synchronization again if needed
                <unsynchronized_code>

    If you want to use wating, do the following:

                <unsynchronized_code>
           -->  If CritSect.WaitToEnter(500) = wrAcquired then
           |      try
           |        <synchronized_code>
           |      finally
           |        CritSect.Leave;
           |      end
           |    else
           |      begin
           |        <code_not_needing_sync>
           |      end;
           --   <repeat_if_needed>
                <unsynchronized_code>

  Version 1.1.1 (2020-01-19)

  Last change 2020-01-19

  ©2016-2020 František Milt

  Contacts:
    František Milt: frantisek.milt@gmail.com

  Support:
    If you find this code useful, please consider supporting its author(s) by
    making a small donation using the following link(s):

      https://www.paypal.me/FMilt

  Changelog:
    For detailed changelog and history please refer to this git repository:

      github.com/TheLazyTomcat/Lib.FastLocks

  Dependencies:
    AuxTypes   - github.com/TheLazyTomcat/Lib.AuxTypes
    AuxClasses - github.com/TheLazyTomcat/Lib.AuxClasses

===============================================================================}
unit FastLocks;

{$IF Defined(CPUX86_64) or Defined(CPUX64)}
  {$DEFINE x64}
{$ELSEIF Defined(CPU386)}
  {$DEFINE x86}
{$ELSE}
  {$DEFINE PurePascal}
{$IFEND}

{$IF Defined(WINDOWS) or Defined(MSWINDOWS)}
  {$DEFINE Windows}
{$ELSEIF Defined(LINUX) and Defined(FPC)}
  {$DEFINE Linux}
{$ELSE}
  {$MESSAGE FATAL 'Unsupported operating system.'}
{$IFEND}

{$IFDEF FPC}
  {$MODE Delphi}
  {$DEFINE FPC_DisableWarns}
  {$MACRO ON}
  {$IFNDEF PurePascal}
    {$ASMMODE Intel}
  {$ENDIF}
{$ENDIF}

interface

uses
  SysUtils,
  AuxTypes, AuxClasses;

type
  // library specific exceptions
  EFLException = class(Exception);

  EFLSystemError     = class(EFLException);
  EFLCreationError   = class(EFLException);
  EFLResevationError = class(EFLException);

{===============================================================================
--------------------------------------------------------------------------------
                                    TFastLock
--------------------------------------------------------------------------------
===============================================================================}

const
  FL_DEF_WAIT_SPIN_CNT = 1500; // around 100us (microseconds) on Intel C2D T7100 @1.8GHz

type
  TFLAcquireMethod = Function(Reserved: Boolean): Boolean of object;
  TFLReserveMethod = procedure of object;

  TFLWaitResult = (wrAcquired,wrTimeOut,wrError);

{===============================================================================
    TFastLock - class declaration
===============================================================================}

  TFastLock = class(TCustomObject)
  protected
    fMainFlag:      Integer;
    fWaitSpinCount: UInt32;
    fCounterFreq:   Int64;
    Function SpinOn(SpinCount: UInt32;
                    AcquireMethod: TFLAcquireMethod;
                    ReserveMethod: TFLReserveMethod = nil;
                    UnreserveMethod: TFLReserveMethod = nil): TFLWaitResult; virtual;
    Function WaitOn(TimeOut: UInt32;
                    AcquireMethod: TFLAcquireMethod;
                    SpinBetweenWaits: Boolean = True;
                    ReserveMethod: TFLReserveMethod = nil;
                    UnreserveMethod: TFLReserveMethod = nil): TFLWaitResult; virtual;
  public
    constructor Create(WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT); virtual;
    property WaitSpinCount: UInt32 read fWaitSpinCount write fWaitSpinCount;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                              TFastCriticalSection
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastCriticalSection - class declaration
===============================================================================}

  TFastCriticalSection = class(TFastLock)
  protected
  {
    Reserved indicates that the synchronizer was reserved before a try to
    acquire was made and that the synchronizer can acquire when reservation is
    marked in the flags.
  }
    Function Acquire(Reserved: Boolean): Boolean; virtual;
    procedure Release; virtual;
    procedure Reserve; virtual;
    procedure Unreserve; virtual;
  public
    Function Enter: Boolean; virtual;
    procedure Leave; virtual;
    Function SpinToEnter(SpinCount: UInt32; Reserve: Boolean = True): TFLWaitResult; virtual;
    Function WaitToEnter(Timeout: UInt32; SpinBetweenWaits: Boolean = True; Reserve: Boolean = True): TFLWaitResult; virtual;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                    TFastMultiReadExclusiveWriteSynchronizer
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastMultiReadExclusiveWriteSynchronizer - class declaration
===============================================================================}

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
    Function WaitToRead(Timeout: UInt32; SpinBetweenWaits: Boolean = True): TFLWaitResult; virtual;
    Function SpinToWrite(SpinCount: UInt32; Reserve: Boolean = True): TFLWaitResult; virtual;
    Function WaitToWrite(Timeout: UInt32; SpinBetweenWaits: Boolean = True; Reserve: Boolean = True): TFLWaitResult; virtual;
  end;

  // shorter name alias
  TFastMREW = TFastMultiReadExclusiveWriteSynchronizer;

implementation

uses
{$IFDEF Windows}
  Windows
{$ELSE}
  unixtype, baseunix, linux
{$ENDIF};

{$IFDEF FPC_DisableWarns}
  {$DEFINE FPCDWM}
  {$DEFINE W4055:={$WARN 4055 OFF}} // Conversion between ordinals and pointers is not portable
  {$DEFINE W5024:={$WARN 5024 OFF}} // Parameter "$1" not used
{$ENDIF}

{$IFNDEF Windows}
const
  INFINITE = UInt32(-1);
{$ENDIF}

{===============================================================================
    Auxiliary functions
===============================================================================}

{
  InterlockedExchangeAdd is implemented here, so there is no need to call it
  from other unit - this is true mainly on windows, where a call to system
  function residing in DLL would be made.
} 
Function InterlockedExchangeAdd(var A: Int32; B: Int32): Int32; {$IFNDEF PurePascal}register; assembler;
asm
{$IFDEF x64}
  {$IFDEF Windows}
        XCHG  RCX,  RDX
  LOCK  XADD  dword ptr [RDX], ECX
        MOV   EAX,  ECX
  {$ELSE}
        XCHG  RDI,  RSI
  LOCK  XADD  dword ptr [RSI], EDI
        MOV   EAX,  EDI
  {$ENDIF}
{$ELSE}
        XCHG  EAX,  EDX
  LOCK  XADD  dword ptr [EDX], EAX
{$ENDIF}
end;
{$ELSE}
begin
{$IFDEF Windows}
Result := Windows.InterlockedExchangeAdd(A,B);
{$ELSE}
{$IFDEF FPC}
Result := System.InterlockedExchangeAdd(A,B);
{$ELSE}
Result := SysUtils.InterlockedExchangeAdd(A,B);
{$ENDIF}
{$ENDIF}
end;
{$ENDIF}

//------------------------------------------------------------------------------

Function GetCounterFrequency(out Freq: Int64): Boolean;
{$IFNDEF Windows}
var
  Time: TTimeSpec;
{$ENDIF}
begin
{$IFDEF Windows}
Freq := 0;
Result := QueryPerformanceFrequency(Freq);
{$ELSE}
Freq := 1000000000{ns};
Result := clock_getres(CLOCK_MONOTONIC_RAW,@Time) = 0;
{$ENDIF}
Freq := Freq and Int64($7FFFFFFFFFFFFFFF);  // mask out bit 63
end;

//------------------------------------------------------------------------------

Function GetCounterValue(out Count: Int64): Boolean;
{$IFNDEF Windows}
var
  Time: TTimeSpec;
{$ENDIF}
begin
{$IFDEF Windows}
Count := 0;
Result := QueryPerformanceCounter(Count);
{$ELSE}
Result := clock_gettime(CLOCK_MONOTONIC_RAW,@Time) = 0;
Count := Int64(Time.tv_sec) * 1000000000 + Time.tv_nsec;
{$ENDIF}
Count := Count and Int64($7FFFFFFFFFFFFFFF);  // mask out bit 63
end;

{===============================================================================
    Imlementation constants
===============================================================================}

const
  FL_UNLOCKED = Integer(0);

{
  Meaning of bits in main flag word in TFastCriticalSection:

    bit 0..7  - acquire count
    bit 8..27 - reserve count

  FL_CS_MAX_ACQUIRE

    if acquire count is found to be above this value during acquiring, the
    acquire automatically fails without any further checks (it is to prevent
    acquire count to overflow into reservation count)

  FL_CS_MASK_RESERVE

    maximum number of reservations, if reservation count is found to be above
    this value during reservation, an EFLResevationError exception is raised
}
  FL_CS_DELTA_ACQUIRE = 1;
  FL_CS_DELTA_RESERVE = $100;

  FL_CS_MASK_ACQUIRE = Integer($000000FF);
  FL_CS_MASK_RESERVE = Integer($0FFFFF00);

  FL_CS_MAX_ACQUIRE = 200;   {must be lower than $FF (255)}
  FL_CS_MAX_RESERVE = 750000 {must be lower than $FFFFF (1048575)};

  FL_CS_SHIFT_RESERVE = 8;

//------------------------------------------------------------------------------
{
  Meaning of bits in main flag word in TFastMultiReadExclusiveWriteSynchronizer:

    bit 0..13   - read count
    bit 14..27  - write reservation count
    bit 28..31  - write count
}
  FL_MREW_DELTA_READ          = 1;
  FL_MREW_DELTA_WRITE_RESERVE = Integer($4000);
  FL_MREW_DELTA_WRITE         = Integer($10000000);

  FL_MREW_MASK_WRITE_RESERVE = Integer($0FFFC000);

  FL_MREW_MAX_READ          = 10000 {must be lower than $3FFF (16383)};
  FL_MREW_MAX_WRITE_RESERVE = 10000 {must be lower than $3FFF (16383)};
  FL_MREW_MAX_WRITE         = 8;    {must be lower than 16}

  FL_MREW_SHIFT_WRITE_RESERVE = 14;
  FL_MREW_SHIFT_WRITE         = 28;

{===============================================================================
--------------------------------------------------------------------------------
                                    TFastLock
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastLock - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TFastLock - protected methods
-------------------------------------------------------------------------------}

Function TFastLock.SpinOn(SpinCount: UInt32; AcquireMethod: TFLAcquireMethod;
  ReserveMethod: TFLReserveMethod = nil; UnreserveMethod: TFLReserveMethod = nil): TFLWaitResult;

  Function Spin: Boolean;
  begin
    If SpinCount <> INFINITE then
      Dec(SpinCount);
    Result := SpinCount > 0;
  end;

  //  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --

  Function InternalSpin(Reserved: Boolean): TFLWaitResult;
  begin
    while not AcquireMethod(Reserved) do
      If not Spin then
        begin
          Result := wrTimeout;
          Exit;
        end;
    Result := wrAcquired;
  end;

    //  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --

begin
try
  If Assigned(ReserveMethod) and Assigned(UnreserveMethod) then
    begin
      ReserveMethod;
      try
        Result := InternalSpin(True);
      finally
        UnreserveMethod;
      end;
    end
  else Result := InternalSpin(False);
except
  Result := wrError;
end;
end;

//------------------------------------------------------------------------------

Function TFastLock.WaitOn(TimeOut: UInt32; AcquireMethod: TFLAcquireMethod; SpinBetweenWaits: Boolean = True;
  ReserveMethod: TFLReserveMethod = nil; UnreserveMethod: TFLReserveMethod = nil): TFLWaitResult;
var
  StartCount:       Int64;
  WaitSpinCntLocal: UInt32;

  //  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --

  Function GetElapsedMillis: UInt32;
  var
    CurrentCount: Int64;
  begin
    If GetCounterValue(CurrentCount) then
      begin
        If CurrentCount < StartCount then
          Result := ((High(Int64) - StartCount + CurrentCount) * 1000) div fCounterFreq
        else
          Result := ((CurrentCount - StartCount) * 1000) div fCounterFreq;
      end
    else Result := UInt32(-1);
  end;

  //  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --

  Function InternalWait(Reserved: Boolean): TFLWaitResult;
  begin
    while not AcquireMethod(Reserved) do
      If GetElapsedMillis >= TimeOut then
        begin
          Result := wrTimeout;
          Exit;
        end
      else
        begin
          If SpinBetweenWaits then
            If SpinOn(WaitSpinCntLocal,AcquireMethod,nil,nil) = wrAcquired then
              Break{while};
        end;
    Result := wrAcquired;
  end;

  //  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --

begin
WaitSpinCntLocal := fWaitSpinCount;
If TimeOut = INFINITE then
  Result := SpinOn(INFINITE,AcquireMethod,ReserveMethod,UnreserveMethod)
else
  begin
    If GetCounterValue(StartCount) then
      begin
        If Assigned(ReserveMethod) and Assigned(UnreserveMethod) then
          begin
            ReserveMethod;
            try
              Result := InternalWait(True);
            finally
              UnreserveMethod;
            end;
          end
        else Result := InternalWait(False);
      end
    else Result := wrError;
  end;
end;

{-------------------------------------------------------------------------------
    TFastLock - public methods
-------------------------------------------------------------------------------}

constructor TFastLock.Create(WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT);
begin
inherited Create;
fMainFlag := FL_UNLOCKED;
{$IFDEF FPCDWM}{$PUSH}W4055{$ENDIF}
If (PtrUInt(Addr(fMainFlag)) and 3) <> 0 then
{$IFDEF FPCDWM}{$POP}{$ENDIF}
  raise EFLCreationError.CreateFmt('TFastLock.Create: Main flag address (0x%p) is not properly aligned.',[Addr(fMainFlag)]);
fWaitSpinCount := WaitSpinCount;
If not GetCounterFrequency(fCounterFreq) then
  raise EFLCreationError.CreateFmt('TFastLock.Create: Cannot obtain counter frequency (0x%.8x).',
                                   [{$IFDEF Windows}GetLastError{$ELSE}errno{$ENDIF}]);
end;


{===============================================================================
--------------------------------------------------------------------------------
                              TFastCriticalSection
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastCriticalSection - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TFastCriticalSection - protected methods
-------------------------------------------------------------------------------}

Function TFastCriticalSection.Acquire(Reserved: Boolean): Boolean;
var
  OldFlagValue: Integer;
begin
OldFlagValue := InterlockedExchangeAdd(fMainFlag,FL_CS_DELTA_ACQUIRE);
If (OldFlagValue and FL_CS_MASK_ACQUIRE) <= FL_CS_MAX_ACQUIRE then
  begin
    If Reserved then
      Result := (OldFlagValue and FL_CS_MASK_ACQUIRE) = FL_UNLOCKED
    else
      Result := OldFlagValue = FL_UNLOCKED;
  end
else Result := False;
If not Result then
  InterlockedExchangeAdd(fMainFlag,-FL_CS_DELTA_ACQUIRE);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Release;
begin
InterlockedExchangeAdd(fMainFlag,-FL_CS_DELTA_ACQUIRE);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Reserve;
var
  OldFlagValue: Integer;
begin
OldFlagValue := InterlockedExchangeAdd(fMainFlag,FL_CS_DELTA_RESERVE);
If ((OldFlagValue and FL_CS_MASK_RESERVE) shr FL_CS_SHIFT_RESERVE) > FL_CS_MAX_RESERVE then
  raise EFLResevationError.CreateFmt('TFastCriticalSection.Reserve: Cannot reserve critical section (%d).',
                            [(OldFlagValue and FL_CS_MASK_RESERVE) shr FL_CS_SHIFT_RESERVE]);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Unreserve;
begin
InterlockedExchangeAdd(fMainFlag,-FL_CS_DELTA_RESERVE);
end;

{-------------------------------------------------------------------------------
    TFastCriticalSection - public methods
-------------------------------------------------------------------------------}

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

Function TFastCriticalSection.SpinToEnter(SpinCount: UInt32; Reserve: Boolean = True): TFLWaitResult;
begin
If Reserve then
  Result := SpinOn(SpinCount,Self.Acquire,Self.Reserve,Self.Unreserve)
else
  Result := SpinOn(SpinCount,Self.Acquire,nil,nil);
end;

//------------------------------------------------------------------------------

Function TFastCriticalSection.WaitToEnter(Timeout: UInt32; SpinBetweenWaits: Boolean = True; Reserve: Boolean = True): TFLWaitResult;
begin
If Reserve then
  Result := WaitOn(Timeout,Self.Acquire,SpinBetweenWaits,Self.Reserve,Self.Unreserve)
else
  Result := WaitOn(Timeout,Self.Acquire,SpinBetweenWaits,nil,nil);
end;


{===============================================================================
--------------------------------------------------------------------------------
                    TFastMultiReadExclusiveWriteSynchronizer
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastMultiReadExclusiveWriteSynchronizer - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TFastMultiReadExclusiveWriteSynchronizer - protected methods
-------------------------------------------------------------------------------}

{$IFDEF FPCDWM}{$PUSH}W5024{$ENDIF}
Function TFastMultiReadExclusiveWriteSynchronizer.AcquireRead(Reserved: Boolean): Boolean;
begin
Result := InterlockedExchangeAdd(fMainFlag,FL_MREW_DELTA_READ) <= FL_MREW_MAX_READ;
If not Result then
  InterlockedExchangeAdd(fMainFlag,-FL_MREW_DELTA_READ);
end;
{$IFDEF FPCDWM}{$POP}{$ENDIF}

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.ReleaseRead;
begin
InterlockedExchangeAdd(fMainFlag,-FL_MREW_DELTA_READ);
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.AcquireWrite(Reserved: Boolean): Boolean;
var
  OldFlagValue: Integer;
begin
OldFlagValue := InterlockedExchangeAdd(fMainFlag,FL_MREW_DELTA_WRITE);
If (OldFlagValue shr FL_MREW_SHIFT_WRITE) <= FL_MREW_MAX_WRITE then
  begin
    If Reserved then
      Result := OldFlagValue and not FL_MREW_MASK_WRITE_RESERVE = FL_UNLOCKED
    else
      Result := OldFlagValue = FL_UNLOCKED;
  end
else Result := False;
If not Result then
  InterlockedExchangeAdd(fMainFlag,-FL_MREW_DELTA_WRITE);
end;

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.ReleaseWrite;
begin
InterlockedExchangeAdd(fMainFlag,-FL_MREW_DELTA_WRITE)
end;

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.ReserveWrite;
var
  OldFlagValue: Integer;
begin
OldFlagValue := InterlockedExchangeAdd(fMainFlag,FL_MREW_DELTA_WRITE_RESERVE);
If ((OldFlagValue and FL_MREW_MASK_WRITE_RESERVE) shr FL_MREW_SHIFT_WRITE_RESERVE) > FL_MREW_MAX_WRITE_RESERVE then
  raise EFLResevationError.CreateFmt('TFastMultiReadExclusiveWriteSynchronizer.ReserveWrite: Cannot reserve MREW for writing (%d).',
                            [(OldFlagValue and FL_MREW_MASK_WRITE_RESERVE) shr FL_MREW_SHIFT_WRITE_RESERVE]);
end;

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.UnreserveWrite;
begin
InterlockedExchangeAdd(fMainFlag,-FL_MREW_DELTA_WRITE_RESERVE);
end;

{-------------------------------------------------------------------------------
    TFastMultiReadExclusiveWriteSynchronizer - public methods
-------------------------------------------------------------------------------}

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
Result := SpinOn(SpinCount,Self.AcquireRead,nil,nil);
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.WaitToRead(Timeout: UInt32; SpinBetweenWaits: Boolean = True): TFLWaitResult;
begin
Result := WaitOn(Timeout,Self.AcquireRead,SpinBetweenWaits,nil,nil);
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.SpinToWrite(SpinCount: UInt32; Reserve: Boolean = True): TFLWaitResult;
begin
If Reserve then
  Result := SpinOn(SpinCount,Self.AcquireWrite,Self.ReserveWrite,Self.UnreserveWrite)
else
  Result := SpinOn(SpinCount,Self.AcquireWrite,nil,nil);
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.WaitToWrite(Timeout: UInt32; SpinBetweenWaits: Boolean = True; Reserve: Boolean = True): TFLWaitResult;
begin
If Reserve then
  Result := WaitOn(Timeout,Self.AcquireWrite,SpinBetweenWaits,Self.ReserveWrite,Self.UnreserveWrite)
else
  Result := WaitOn(Timeout,Self.AcquireWrite,SpinBetweenWaits,nil,nil);
end;

end.

