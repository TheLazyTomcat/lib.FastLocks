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
        fail, with exception being MREW reading, which is given by concept of
        multiple readers access)
      - use provided wait methods only when necessary - synchronizers are
        intended to be used as non blocking
      - waiting is by default active (spinning) - do not wait for prolonged
        time intervals as it might starve other threads, use infinite waiting
        only in extreme cases and only when really necessary
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

  Version 1.2 (2021-04-27)

  Last change 2021-04-27

  ©2016-2021 František Milt

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

{
  FastLocks_PurePascal

  If you want to compile this unit without ASM, don't want to or cannot define
  PurePascal for the entire project and at the same time you don't want to or
  cannot make changes to this unit, define this symbol for the entire project
  and this unit will be compiled in PurePascal mode.
}
{$IFDEF FastLocks_PurePascal}
  {$DEFINE PurePascal}
{$ENDIF}

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
  {$MODE ObjFPC}
  {$MODESWITCH DuplicateLocals+}
  {$MODESWITCH ClassicProcVars+}
  {$DEFINE FPC_DisableWarns}
  {$MACRO ON}
  {$IFNDEF PurePascal}
    {$ASMMODE Intel}
  {$ENDIF}
{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  AuxTypes, AuxClasses;

type
  // library-specific exceptions
  EFLException = class(Exception);

  EFLCreationError = class(EFLException);

{===============================================================================
--------------------------------------------------------------------------------
                                    TFastLock
--------------------------------------------------------------------------------
===============================================================================}

const
  FL_DEF_WAIT_SPIN_CNT = 1500; // around 100us (microseconds) on Intel C2D T7100 @1.8GHz

{$IFNDEF Windows}
  INFINITE = UInt32(-1);
{$ENDIF}

type
  TFLAcquireMethod = Function(Reserved: Boolean): Boolean of object;

  TFLReserveMethod   = Function: Boolean of object;  
  TFLUnreserveMethod = procedure of object;

  TFLWaitResult = (wrAcquired,wrTimeOut,wrError);

{
  In waiting (methods WaitTo*), the function blocks by executing a cycle. Each
  iteration of this cycle contains a try to acquire the lock, a check for
  timeout and a delaying part that prevents rapid calls to acquire and timers.

  TFLWaitDelayMethod enumeration is here to select a method used for this
  delaying.

    wdNone        No delaying action is performed.

    wdSpin        A call to SpinOn is made with spin count set to a value
                  stored in property WaitSpinCount.

    wdYield       An attempt to yield execution of current thread is made.
                  If system has another thread that can be run, the current
                  thread is suspended, rescheduled and the next thread is run.
                  If there is no thread awaiting execution, then the current
                  thread is not suspended and continues execution and pretty
                  much performs spinning.

                    WARNING - use with caution, as it can cause spinning with
                              rapid calls to thread yielding on uncontested CPU.

    wdSleep       The current thread stops execution (call to Sleep) for no
                  less than 10ms. Note that this time might actually be longer
                  because of granularity of scheduling timers, resulting in
                  slightly longer wait time than is requested.

    wdSleepEx     Behaves the same as wdSleep, but the thread can be awakened
                  by APC or I/O completion calls.

                    NOTE - works only on Windows, everywhere else it behaves
                           the same as wdSleep.

    wdYieldSleep  Combination od wdYield and wdSleep - when the thread is not
                  yielded (eg. because no thread is waiting execution), a sleep
                  is performed.

                    NOTE - works only on Windows, everywhere else it behaves
                           the same as wdSleep.
}
  TFLWaitDelayMethod = (wdNone,wdSpin,wdYield,wdSleep,wdSleepEx,wdYieldSleep);

{===============================================================================
    TFastLock - class declaration
===============================================================================}

  TFastLock = class(TCustomObject)
  protected
    fMainFlag:      Int32;
    fCounterFreq:   Int64;
    fWaitSpinCount: UInt32;
    Function GetWaitSpinCount: UInt32; virtual;
    procedure SetWaitSpinCount(Value: UInt32); virtual;
    Function SpinOn(SpinCount: UInt32;
                    AcquireMethod: TFLAcquireMethod;
                    ReserveMethod: TFLReserveMethod;
                    UnreserveMethod: TFLUnreserveMethod): TFLWaitResult; virtual;
    Function WaitOn(TimeOut: UInt32;
                    AcquireMethod: TFLAcquireMethod;
                    WaitDelayMethod: TFLWaitDelayMethod;
                    ReserveMethod: TFLReserveMethod;
                    UnreserveMethod: TFLUnreserveMethod): TFLWaitResult; virtual;
  public
    constructor Create(WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT); virtual;
    property WaitSpinCount: UInt32 read GetWaitSpinCount write SetWaitSpinCount;
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
    acquire was made and that the synchronizer can acquire even when
    reservation is marked in the flags.
  }
    Function Acquire(Reserved: Boolean): Boolean; virtual;
    procedure Release; virtual;
    Function Reserve: Boolean; virtual;
    procedure Unreserve; virtual;
  public
    Function Enter: Boolean; virtual;
    procedure Leave; virtual;
    Function SpinToEnter(SpinCount: UInt32; Reserve: Boolean = True): TFLWaitResult; virtual;
    Function WaitToEnter(Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin; Reserve: Boolean = True): TFLWaitResult; virtual;
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
    Function ReserveWrite: Boolean; virtual;
    procedure UnreserveWrite; virtual;
  public
    Function BeginRead: Boolean; virtual;
    procedure EndRead; virtual;
    Function BeginWrite: Boolean; virtual;
    procedure EndWrite; virtual;
    Function SpinToRead(SpinCount: UInt32): TFLWaitResult; virtual;
    Function WaitToRead(Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin): TFLWaitResult; virtual;
    Function SpinToWrite(SpinCount: UInt32; Reserve: Boolean = True): TFLWaitResult; virtual;
    Function WaitToWrite(Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin; Reserve: Boolean = True): TFLWaitResult; virtual;
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

{===============================================================================
    Auxiliary functions
===============================================================================}
{
  InterlockedExchangeAdd and InterlockedExchange are implemented here, so there
  is no need to call then from elsewhere - this is true mainly on windows,
  where a call to system function residing in a DLL would be made.
} 
Function InterlockedExchangeAdd(var A: Int32; B: Int32): Int32; {$IFNDEF PurePascal}register; assembler;
asm
    LOCK  XADD  dword ptr [A], B
          MOV   EAX, B
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

Function InterlockedExchange(var A: Int32; B: Int32): Int32; {$IFNDEF PurePascal}register; assembler;
asm
    LOCK  XCHG  dword ptr [A], B
          MOV   EAX, B
end;
{$ELSE}
begin
{$IFDEF Windows}
Result := Windows.InterlockedExchange(A,B);
{$ELSE}
{$IFDEF FPC}
Result := System.InterlockedExchange(A,B);
{$ELSE}
Result := SysUtils.InterlockedExchange(A,B);
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

//------------------------------------------------------------------------------

{$IFDEF Windows}
{$IF not Declared(SwitchToThread)}
Function SwitchToThread: BOOL; stdcall; external kernel32;
{$IFEND}
{$ELSE}
{
  FPC declares sched_yield as procedure without result, which afaik does not
  correspond to linux man.
}
Function sched_yield: cint; cdecl; external;
{$ENDIF}

//------------------------------------------------------------------------------

Function YieldThread: Boolean;
begin
{$IFDEF Windows}
Result := SwitchToThread;
{$ELSE}
Result := sched_yield = 0;
{$ENDIF}
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
}
{
  FL_CS_MAX_ACQUIRE

    If acquire count is found to be above this value during acquiring, the
    acquire automatically fails without any further checks (it is to prevent
    acquire count to overflow into reservation count).

}
  FL_CS_ACQUIRE_DELTA = 1;
  FL_CS_ACQUIRE_MASK  = Int32($000000FF);
  FL_CS_ACQUIRE_MAX   = 150;   {must be lower than $FF (255)}

{
  FL_CS_MAX_RESERVE

    Maximum number of reservations, if reservation count is found to be above
    this value, the reservation fails and consequently the wait function will
    return an error.
}
  FL_CS_RESERVE_DELTA = $100;
  FL_CS_RESERVE_MASK  = Int32($0FFFFF00);
  FL_CS_RESERVE_MAX   = 750000 {must be lower than $FFFFF (1048575)};
  FL_CS_RESERVE_SHIFT = 8;

//------------------------------------------------------------------------------
{
  Meaning of bits in main flag word in TFastMultiReadExclusiveWriteSynchronizer:

    bit 0..13   - read count
    bit 14..27  - write reservation count
    bit 28..31  - write count
}
  FL_MREW_READ_DELTA = 1;
  FL_MREW_READ_MAX   = 10000 {must be lower than $3FFF (16383)};

  FL_MREW_RESERVE_DELTA = Int32($4000);
  FL_MREW_RESERVE_MASK  = Int32($0FFFC000);
  FL_MREW_RESERVE_MAX   = 10000 {must be lower than $3FFF (16383)};
  FL_MREW_RESERVE_SHIFT = 14;

  FL_MREW_WRITE_DELTA = Int32($10000000);
  FL_MREW_WRITE_MAX   = 8;    {must be lower than 16}
  FL_MREW_WRITE_SHIFT = 28;
  

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

Function TFastLock.GetWaitSpinCount: UInt32;
begin
Result := InterlockedExchangeAdd(Integer(fWaitSpinCount),0);
end;

//------------------------------------------------------------------------------

procedure TFastLock.SetWaitSpinCount(Value: UInt32);
begin
InterlockedExchange(Integer(fWaitSpinCount),Integer(Value));
end;

//------------------------------------------------------------------------------

Function TFastLock.SpinOn(SpinCount: UInt32; AcquireMethod: TFLAcquireMethod;
  ReserveMethod: TFLReserveMethod; UnreserveMethod: TFLUnreserveMethod): TFLWaitResult;

  Function Spin: Boolean;
  begin
    If SpinCount <> INFINITE then
      Dec(SpinCount);
    Result := SpinCount > 0;
  end;

//--  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --

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

//--  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --

begin
try
  If Assigned(ReserveMethod) and Assigned(UnreserveMethod) then
    begin
      If ReserveMethod then
        try
          Result := InternalSpin(True);
        finally
          UnreserveMethod;
        end
      else Result := wrError;
    end
  else Result := InternalSpin(False);
except
  Result := wrError;
end;
end;

//------------------------------------------------------------------------------

Function TFastLock.WaitOn(TimeOut: UInt32; AcquireMethod: TFLAcquireMethod; WaitDelayMethod: TFLWaitDelayMethod;
  ReserveMethod: TFLReserveMethod; UnreserveMethod: TFLUnreserveMethod): TFLWaitResult;
var
  StartCount:       Int64;
  WaitSpinCntLocal: UInt32;

//--  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --

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

//--  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --

  Function InternalWait(Reserved: Boolean): TFLWaitResult;
  begin
    while not AcquireMethod(Reserved) do
      If (TimeOut <> INFINITE) and (GetElapsedMillis >= TimeOut) then
        begin
          Result := wrTimeout;
          Exit;
        end
      else
        begin
          case WaitDelayMethod of
            wdNone:;      // do nothing;
            wdSpin:       If SpinOn(WaitSpinCntLocal,AcquireMethod,nil,nil) = wrAcquired then
                            Break{while};
            wdYield:      YieldThread;
          {$IFDEF Windows}
            wdSleep:      Sleep(10);
            wdSleepEx:    SleepEx(10,True);
            wdYieldSleep: If not YieldThread then
                            Sleep(10);
          {$ELSE}
            wdSleep,
            wdSleepEx,
            wdYieldSleep: Sleep(10);
          {$ENDIF}
          end
        end;
    Result := wrAcquired;
  end;

//--  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --

begin
WaitSpinCntLocal := GetWaitSpinCount;
If GetCounterValue(StartCount) then
  begin
    If Assigned(ReserveMethod) and Assigned(UnreserveMethod) then
      begin
        If ReserveMethod then
          try
            Result := InternalWait(True);
          finally
            UnreserveMethod;
          end
        else Result := wrError;
      end
    else Result := InternalWait(False);
  end
else Result := wrError;
end;

{-------------------------------------------------------------------------------
    TFastLock - public methods
-------------------------------------------------------------------------------}

constructor TFastLock.Create(WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT);
begin
inherited Create;
fMainFlag := FL_UNLOCKED;
If not GetCounterFrequency(fCounterFreq) then
  raise EFLCreationError.CreateFmt('TFastLock.Create: Cannot obtain counter frequency (0x%.8x).',
                                   [{$IFDEF Windows}GetLastError{$ELSE}errno{$ENDIF}]);
SetWaitSpinCount(WaitSpinCount);
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
OldFlagValue := InterlockedExchangeAdd(fMainFlag,FL_CS_ACQUIRE_DELTA);
If (OldFlagValue and FL_CS_ACQUIRE_MASK) < FL_CS_ACQUIRE_MAX then
  begin
    If Reserved then
      Result := (OldFlagValue and not FL_CS_RESERVE_MASK) = FL_UNLOCKED
    else
      Result := OldFlagValue = FL_UNLOCKED;
  end
else Result := False;
If not Result then
  InterlockedExchangeAdd(fMainFlag,-FL_CS_ACQUIRE_DELTA);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Release;
begin
InterlockedExchangeAdd(fMainFlag,-FL_CS_ACQUIRE_DELTA);
end;

//------------------------------------------------------------------------------

Function TFastCriticalSection.Reserve: Boolean;
var
  OldFlagValue: Integer;
begin
OldFlagValue := InterlockedExchangeAdd(fMainFlag,FL_CS_RESERVE_DELTA);
Result := ((OldFlagValue and FL_CS_RESERVE_MASK) shr FL_CS_RESERVE_SHIFT) < FL_CS_RESERVE_MAX;
If not Result then
  InterlockedExchangeAdd(fMainFlag,-FL_CS_RESERVE_DELTA);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Unreserve;
begin
InterlockedExchangeAdd(fMainFlag,-FL_CS_RESERVE_DELTA);
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

Function TFastCriticalSection.WaitToEnter(Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin; Reserve: Boolean = True): TFLWaitResult;
begin
If Reserve then
  Result := WaitOn(Timeout,Self.Acquire,WaitDelayMethod,Self.Reserve,Self.Unreserve)
else
  Result := WaitOn(Timeout,Self.Acquire,WaitDelayMethod,nil,nil);
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
Result := InterlockedExchangeAdd(fMainFlag,FL_MREW_READ_DELTA) < FL_MREW_READ_MAX;
If not Result then
  InterlockedExchangeAdd(fMainFlag,-FL_MREW_READ_DELTA);
end;
{$IFDEF FPCDWM}{$POP}{$ENDIF}

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.ReleaseRead;
begin
InterlockedExchangeAdd(fMainFlag,-FL_MREW_READ_DELTA);
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.AcquireWrite(Reserved: Boolean): Boolean;
var
  OldFlagValue: Integer;
begin
OldFlagValue := InterlockedExchangeAdd(fMainFlag,FL_MREW_WRITE_DELTA);
If (OldFlagValue shr FL_MREW_WRITE_SHIFT) < FL_MREW_WRITE_MAX then
  begin
    If Reserved then
      Result := (OldFlagValue and not FL_MREW_RESERVE_MASK) = FL_UNLOCKED
    else
      Result := OldFlagValue = FL_UNLOCKED;
  end
else Result := False;
If not Result then
  InterlockedExchangeAdd(fMainFlag,-FL_MREW_WRITE_DELTA);
end;

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.ReleaseWrite;
begin
InterlockedExchangeAdd(fMainFlag,-FL_MREW_WRITE_DELTA)
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.ReserveWrite: Boolean;
var
  OldFlagValue: Integer;
begin
OldFlagValue := InterlockedExchangeAdd(fMainFlag,FL_MREW_RESERVE_DELTA);
Result := ((OldFlagValue and FL_MREW_RESERVE_MASK) shr FL_MREW_RESERVE_SHIFT) < FL_MREW_RESERVE_MAX;
If not Result then
  InterlockedExchangeAdd(fMainFlag,-FL_MREW_RESERVE_DELTA);
end;

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.UnreserveWrite;
begin
InterlockedExchangeAdd(fMainFlag,-FL_MREW_RESERVE_DELTA);
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

Function TFastMultiReadExclusiveWriteSynchronizer.WaitToRead(Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin): TFLWaitResult;
begin
Result := WaitOn(Timeout,Self.AcquireRead,WaitDelayMethod,nil,nil);
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

Function TFastMultiReadExclusiveWriteSynchronizer.WaitToWrite(Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin; Reserve: Boolean = True): TFLWaitResult;
begin
If Reserve then
  Result := WaitOn(Timeout,Self.AcquireWrite,WaitDelayMethod,Self.ReserveWrite,Self.UnreserveWrite)
else
  Result := WaitOn(Timeout,Self.AcquireWrite,WaitDelayMethod,nil,nil);
end;

end.

