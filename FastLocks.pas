{-------------------------------------------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

-------------------------------------------------------------------------------}
{===============================================================================

  FastLocks

    Simple non-blocking synchronization objects based on interlocked functions
    operating on locking counters.

    WARNING >>>

      This library was written for a specific scenario, where there was tens
      of thousand of separate data structures, each of which could have been
      accessed by several threads, and where concurrent access was rare but
      very possible and dangerous. When a simultaneous access occured, it was
      almost always reading.

      Creating RW lock for each of the structure was unfeasible, so this
      library was written to provide some light-weight locking mechanism with
      minimal memory and OS resources footprint. Implementation is therefore
      maximally simple, which causes many limitations.

    <<< WARNING

    Non-blocking behaviour means that any attempt to acquire lock will return
    immediatelly, and resulting value of this attempt indicates whether the
    lock was really acquired or not.

    At this point, only two synchronization primitives/objects are implenented,
    critical section and an RW lock (multiple-read exclusive-write
    synchronizer). More might be added later, but currently it is unlikely.
    For details about how any of the object works and what are its limitations,
    refer to its declaration.

    In its basic form, each in-here implemented synchronizer is just an integer
    residing in the memory. Within this library, this integer is called sync
    word.
    It is used to store the locking counters and interlocked functions are used
    to atomically change and probe stored values and to decide state of the
    object and required action.

      WARNING - all implemented synchronizers are operating on the same sync
                word type (TFLSyncWord), but they are not mutually compatible.
                So always use one sync word for only one type of synchronizer,
                never mix them on one variable.

    All synchronizers can be used either directly, where you allocate a variable
    of type TFLSyncWord and then operate on it using interface functions (eg.
    FastCriticalSectionReserve, FastMREWBeginRead, ...), or indirectly,
    by creating an instance of provided class and using its methods.

    When creating the class instance, you can either provide preallocated sync
    word variable or leave its complete management on the instance itself.
    This gives you more freedom in deciding how to use the sychnonization - you
    can either allocate common sync word and create new instance for each
    syhcnronizing thread, or you can create one common instance and us >it< in
    all threads.

      NOTE - if the sync vord variable is located in a shared memory, the
             synchronizers can then be used for inter-process synchronization.

    One advantage of instance approach is that they provide a mechanism for
    waiting - ie. they block until the lock is acquired or timeout elapses.
    But note that this waiting is always active (spinning), and therefore
    should be used only rarely and carefully.

    Here is a small example how a non-blocking synchronization can be used:

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

    Some more iportant notes on the implementation and use:

      - none of the provided synchronizers is robust (when a thread holding
        a lock ends without releasing it, it will stay locked indefinitely)

      - none of the provided synchronizers is recursive (when attempting to
        acquire a lock second time in the same thread, it will always fail)

      - there is absolutely no deadlock prevention - be extremely carefull when
        trying to acquire synchronizer in more than one place in a single thread
        (trying to acquire synchronizer second time in the same thread will
        always fail, with exception being MREW reading, which is given by
        concept of multiple readers access)

      - use provided wait methods only when necessary - synchronizers are
        intended to be used as non-blocking

      - waiting is always active (spinning) - do not wait for prolonged time
        intervals as it might starve other threads, use infinite waiting only
        in extreme cases and only when really necessary

      - use synchronization by provided objects only on very short (in time,
        not code) routines - do not use to synchronize code that is executing
        longer than few milliseconds

      - every successfull acquire of a synchronizer MUST be paired by a release,
        synhronizers are not automalically released

  Version 1.3 (2021-10-23)

  Last change 2021-10-23

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
    AuxTypes       - github.com/TheLazyTomcat/Lib.AuxTypes
    AuxClasses     - github.com/TheLazyTomcat/Lib.AuxClasses
    InterlockedOps - github.com/TheLazyTomcat/Lib.InterlockedOps
  * SimpleCPUID    - github.com/TheLazyTomcat/Lib.SimpleCPUID

  SimpleCPUID might not be required, see library InterlockedOps for details.

===============================================================================}
unit FastLocks;

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
  {$INLINE ON}
  {$DEFINE CanInline}
  {$MACRO ON}
  {$IFNDEF PurePascal}
    {$ASMMODE Intel}
  {$ENDIF}
{$ELSE}
  {$IF CompilerVersion >= 17 then}  // Delphi 2005+
    {$DEFINE CanInline}
  {$ELSE}
    {$UNDEF CanInline}
  {$IFEND}
{$ENDIF}
{$H+}

//------------------------------------------------------------------------------
{
  SyncWord64

  When this symbol is defined, the type used for sync words (TFLSyncWord), and
  therefore the sync words themselves, is 64 bits wide, otherwise it is 32 bits
  wide.

  This holds true on all systems.

  By default defined.
}
{$DEFINE SyncWord64}

interface

uses
  SysUtils,
  AuxTypes, AuxClasses;

{===============================================================================
    Library-specific exceptions
===============================================================================}
type
  EFLException = class(Exception);

  EFLCounterError = class(EFLException);
  EFLInvalidValue = class(EFLException);

{===============================================================================
--------------------------------------------------------------------------------
                                    TFastLock
--------------------------------------------------------------------------------
===============================================================================}

const
  FL_DEF_SPIN_DELAY_CNT = 1000; // default value of SpinDelayCount
  FL_DEF_WAIT_SPIN_CNT  = 1500; // default value of WaitSpinCount

  INFINITE = UInt32(-1);  // infinite timeout interval

type
  TFLSyncWord = {$IFDEF SyncWord64}UInt64{$ELSE}UInt32{$ENDIF};
  PFLSyncWord = ^TFLSyncWord;

{
  Returned as a result of spinning or waiting (methods SpinTo* and WaitTo*).
  Informs whether the object was acquired and locked, and if not, for what
  reason the locking failed.

    wrAcquired - The object was acquired and is now locked.

    wrTimeOut  - Spinning/waiting timed-out, ie. locking was not successful in
                 a given timeout period.

    wrReserved - Spinning/waiting failed and the object was not locked because
                 it was reserved or the reserve count reached its maximum.
                 This is not an error, just a limitation of the implementation,
                 you should try the waiting again after some time.

    wrError    - Unknown or external error has ocurred, the object might be in
                 an inconsistent state and should not be used anymore.
}
  TFLWaitResult = (wrAcquired,wrTimeOut,wrReserved,wrError);

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
{$message 'add description of spinning/waiting (SpinDelayCount, WaitSpinCount, ...)'}
type
  TFastLock = class(TCustomObject)
  protected
    fSyncWord:        TFLSyncWord;
    fSyncWordPtr:     PFLSyncWord;
    fOwnsSyncWord:    Boolean;
    fWaitDelayMethod: UInt32;
    fWaitSpinCount:   UInt32;
    fSpinDelayCount:  UInt32;
    fCounterFreq:     Int64;
    Function GetWaitDelayMethod: TFLWaitDelayMethod; virtual;
    procedure SetWaitDelayMethod(Value: TFLWaitDelayMethod); virtual;
    Function GetWaitSpinCount: UInt32; virtual;
    procedure SetWaitSpinCount(Value: UInt32); virtual;
    Function GetSpinDelayCount: UInt32; virtual;
    procedure SetSpinDelayCount(Value: UInt32); virtual;
    procedure Initialize(SyncWordPtr: PFLSyncWord); virtual;
    procedure Finalize; virtual;
  public
    constructor Create(SyncWordPtr: PFLSyncWord); overload; virtual;
    constructor Create; overload; virtual;
    destructor Destroy; override;
    property OwnsSyncWord: Boolean read fOwnsSyncWord;
    property WaitDelayMethod: TFLWaitDelayMethod read GetWaitDelayMethod write SetWaitDelayMethod;
    property WaitSpinCount: UInt32 read GetWaitSpinCount write SetWaitSpinCount;
    property SpinDelayCount: UInt32 read GetSpinDelayCount write SetSpinDelayCount;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                              Fast critical section
--------------------------------------------------------------------------------
===============================================================================}
{
  Classical critical section - only one thread can acquire the object, and
  while it is locked all subsequent attemps to acquire it will fail.
}
{===============================================================================
    Fast critical section - flat interface declaration
===============================================================================}
{
  Call FastCriticalSectionInit only once for each sync word. If you call it for
  already initialized/used sync word, it will be reinitialized.

  FastCriticalSectionFinal will set the section to a state where it cannot
  be entered or reserved.

  If you reserve the section, then it can only be entered by a call to
  FastCriticalSectionEnter which also sets the parameter Reserved to true.
  In other words, if you try to enter reserved section while setting the
  Reserved param to false, it will fail, even if the section is not locked.
  An attempt to enter not reserved section while setting param Reserved to true
  will also always fail.

  Reservation can be made irrespective of whether the section is currently
  locked or not.

  The reservation can fail and you must check return value to see it if was
  succcessful.

  There is no protection against situation, where the section is reserved in
  a different thread than which is currently trying to enter it with Reserved
  set to true.

}

procedure FastCriticalSectionInit(SyncWordPtr: PFLSyncWord);
procedure FastCriticalSectionFinal(SyncWordPtr: PFLSyncWord);

Function FastCriticalSectionEnter(SyncWordPtr: PFLSyncWord): Boolean;
procedure FastCriticalSectionLeave(SyncWordPtr: PFLSyncWord);

Function FastCriticalSectionSpinToEnter(SyncWordPtr: PFLSyncWord; SpinCount: UInt32; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
Function FastCriticalSectionWaitToEnter(SyncWordPtr: PFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin;
  WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;

{===============================================================================
--------------------------------------------------------------------------------
                              TFastCriticalSection
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastCriticalSection - class declaration
===============================================================================}
{
  Methods SpinToEnter and WaitToEnter are both trying to enter the section
  with a reservation, ensuring they have "higher priority" than calls to method
  Enter, which does not reserve the section.
}
type
  TFastCriticalSection = class(TFastLock)
  protected
    procedure Initialize(SyncWordPtr: PFLSyncWord); override;
    procedure Finalize; override;
  public
    Function Enter: Boolean; virtual;
    procedure Leave; virtual;
    Function SpinToEnter(SpinCount: UInt32): TFLWaitResult; virtual;
    Function WaitToEnter(Timeout: UInt32): TFLWaitResult; virtual;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                    TFastMultiReadExclusiveWriteSynchronizer
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastMultiReadExclusiveWriteSynchronizer - flat interface declaration
===============================================================================}

procedure FastMREWInit(SyncWordPtr: PFLSyncWord);
procedure FastMREWFinal(SyncWordPtr: PFLSyncWord);

Function FastMREWBeginRead(SyncWordPtr: PFLSyncWord): Boolean;
procedure FastMREWEndRead(SyncWordPtr: PFLSyncWord);

Function FastMREWSpinToRead(SyncWordPtr: PFLSyncWord; SpinCount: UInt32; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
Function FastMREWWaitToRead(SyncWordPtr: PFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin;
  WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;

Function FastMREWBeginWrite(SyncWordPtr: PFLSyncWord): Boolean;
procedure FastMREWEndWrite(SyncWordPtr: PFLSyncWord);

Function FastMREWSpinToWrite(SyncWordPtr: PFLSyncWord; SpinCount: UInt32; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
Function FastMREWWaitToWrite(SyncWordPtr: PFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin;
  WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;

{===============================================================================
    TFastMultiReadExclusiveWriteSynchronizer - class declaration
===============================================================================}
type
  TFastMREW = class(TFastLock)
  protected
    procedure Initialize(SyncWordPtr: PFLSyncWord); override;
    procedure Finalize; override;    
  public
    Function BeginRead: Boolean; virtual;
    procedure EndRead; virtual;
    Function BeginWrite: Boolean; virtual;
    procedure EndWrite; virtual;
    Function SpinToRead(SpinCount: UInt32): TFLWaitResult; virtual;
    Function WaitToRead(Timeout: UInt32): TFLWaitResult; virtual;
    Function SpinToWrite(SpinCount: UInt32): TFLWaitResult; virtual;
    Function WaitToWrite(Timeout: UInt32): TFLWaitResult; virtual;
  end;

  // full-name alias
  TFastMultiReadExclusiveWriteSynchronizer = TFastMREW;

implementation

uses
{$IFDEF Windows}
  Windows,
{$ELSE}
  unixtype, baseunix, linux,
{$ENDIF}
  InterlockedOps;

{$IFDEF FPC_DisableWarns}
  {$DEFINE FPCDWM}
  {$DEFINE W5024:={$WARN 5024 OFF}} // Parameter "$1" not used
{$ENDIF}

{===============================================================================
    Internal functions
===============================================================================}

Function SpinDelay(Divisor: UInt32): UInt32;
begin
// just some contained, relatively long, but othervise pointless operation
Result := UInt32(3895731025) div Divisor;
end;

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
If Freq and Int64($1000000000000000) <> 0 then
  raise EFLInvalidValue.CreateFmt('GetCounterFrequency: Unsupported frequency value (0x%.16x)',[Freq]);
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
// mask out bit 63 to prevent problems with signed 64bit integer
Count := Count and Int64($7FFFFFFFFFFFFFFF);
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

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function YieldThread: Boolean;
begin
{$IFDEF Windows}
Result := SwitchToThread;
{$ELSE}
Result := sched_yield = 0;
{$ENDIF}
end;

{===============================================================================
    Interlocked function wrappers
===============================================================================}

Function _InterlockedExchangeAdd(A: PFLSyncWord; B: TFLSyncWord): TFLSyncWord;{$IFDEF CanInline} inline;{$ENDIF}
begin
{$IFDEF SyncWord64}
Result := InterlockedExchangeAdd64(A,B);      
{$ELSE}
Result := InterlockedExchangeAdd32(A,B);
{$ENDIF}
end;

//------------------------------------------------------------------------------

Function _InterlockedExchangeSub(A: PFLSyncWord; B: TFLSyncWord): TFLSyncWord;{$IFDEF CanInline} inline;{$ENDIF}
begin
{$IFDEF SyncWord64}
Result := InterlockedExchangeSub64(A,B);
{$ELSE}
Result := InterlockedExchangeSub32(A,B);
{$ENDIF}
end;

{===============================================================================
    Imlementation constants
===============================================================================}

(*
{
  Meaning of bits in main sync word in TFastCriticalSection:

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
  FL_CS_ACQUIRE_MASK  = UInt32($000000FF);
  FL_CS_ACQUIRE_MAX   = 150;   {must be lower than $FF (255)}

{
  FL_CS_MAX_RESERVE

    Maximum number of reservations, if reservation count is found to be above
    this value, the reservation fails and consequently the wait function will
    return an error.
}
  FL_CS_RESERVE_DELTA = $100;
  FL_CS_RESERVE_MASK  = UInt32($0FFFFF00);
  FL_CS_RESERVE_MAX   = 750000 {must be lower than $FFFFF (1048575)};
  FL_CS_RESERVE_SHIFT = 8;

//------------------------------------------------------------------------------
{
  Meaning of bits in main sync word in TFastMREW:

    bit 0..13   - read count
    bit 14..27  - write reservation count
    bit 28..31  - write count
}
  FL_MREW_READ_DELTA = 1;
  FL_MREW_READ_MAX   = 10000 {must be lower than $3FFF (16383)};

  FL_MREW_RESERVE_DELTA = UInt32($4000);
  FL_MREW_RESERVE_MASK  = UInt32($0FFFC000);
  FL_MREW_RESERVE_MAX   = 10000 {must be lower than $3FFF (16383)};
  FL_MREW_RESERVE_SHIFT = 14;

  FL_MREW_WRITE_DELTA = UInt32($10000000);
  FL_MREW_WRITE_MAX   = 8;    {must be lower than 16}
  FL_MREW_WRITE_SHIFT = 28;
*)

{===============================================================================
--------------------------------------------------------------------------------
                                   Fast locks
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    Fast locks - imlementation constants
===============================================================================}

const
  FL_UNLOCKED = TFLSyncWord(0);

  FL_INVALID = TFLSyncWord(-1);

{===============================================================================
    Fast locks - waiting and spinning
===============================================================================}

type
  TFLSpinParams = record
    SyncWordPtr:    PFLSyncWord;
    SpinCount:      UInt32;
    SpinDelayCount: UInt32;
    Reserve:        Boolean;
    Reserved:       Boolean;
    FceReserve:     Function(SyncWord: PFLSyncWord): Boolean;
    FceUnreserve:   procedure(SyncWord: PFLSyncWord);
    FceAcquire:     Function(SyncWord: PFLSyncWord; Reserved: Boolean; out FailedDueToReservation: Boolean): Boolean;
  end;

//------------------------------------------------------------------------------

Function _DoSpin(Params: TFLSpinParams): TFLWaitResult;

  Function InternalSpin(Reserved: Boolean): TFLWaitResult;

    Function SpinDelayAndCount: Boolean;
    var
      i:  Integer;
    begin
      // do some delaying and decrease spin count if not in infinite spinning
      For i := 1 to Params.SpinDelayCount do
        SpinDelay(i);
      If Params.SpinCount <> INFINITE then
        Dec(Params.SpinCount);
      Result := Params.SpinCount > 0;
    end;
    
  var
    FailedDueToReservation: Boolean;
  begin
    while not Params.FceAcquire(Params.SyncWordPtr,Reserved,FailedDueToReservation) do
      If not FailedDueToReservation then
        begin
          // acquire failed for other reason than reservation
          If not SpinDelayAndCount then
            begin
              // spin count reached zero
              Result := wrTimeout;
              Exit;
            end;
        end
      else
        begin
          // acquire failed due to reservation
          Result := wrReserved;
          Exit;
        end;
    // if we are here, acquire was successful    
    Result := wrAcquired;
  end;

begin
try
  If Params.Reserve then
    begin
      If Params.FceReserve(Params.SyncWordPtr) then
        try
          Result := InternalSpin(True);
        finally
          Params.FceUnreserve(Params.SyncWordPtr);
        end
      else Result := wrReserved;
    end
  else Result := InternalSpin(Params.Reserved);
except
  Result := wrError;
end;
end;

//==============================================================================

type
  TFLWaitParams = record
    SyncWordPtr:      PFLSyncWord;
    Timeout:          UInt32;
    WaitDelayMethod:  TFLWaitDelayMethod;
    WaitSpinCount:    UInt32;
    SpinDelayCount:   UInt32;
    Reserve:          Boolean;
    FceReserve:       Function(SyncWord: PFLSyncWord): Boolean;
    FceUnreserve:     procedure(SyncWord: PFLSyncWord);
    FceAcquire:       Function(SyncWord: PFLSyncWord; Reserved: Boolean; out FailedDueToReservation: Boolean): Boolean;
    CounterFrequency: Int64;    
    StartCount:       Int64;
  end;

//------------------------------------------------------------------------------

Function _DoWait(Params: TFLWaitParams): TFLWaitResult;

  Function InternalWait(Reserved: Boolean): TFLWaitResult;

    Function GetElapsedMillis: UInt32;
    var
      CurrentCount: Int64;
    begin
      If GetCounterValue(CurrentCount) then
        begin
          If CurrentCount < Params.StartCount then
            Result := ((High(Int64) - Params.StartCount + CurrentCount) * 1000) div Params.CounterFrequency
          else
            Result := ((CurrentCount - Params.StartCount) * 1000) div Params.CounterFrequency;
        end
      else Result := UInt32(-1);
    end;

  var
    FailedDueToReservation: Boolean;
    SpinParams:             TFLSpinParams;
  begin
    while not Params.FceAcquire(Params.SyncWordPtr,Reserved,FailedDueToReservation) do
      If not FailedDueToReservation then
        begin
          // acquire failed for other reason than reservation, check elapsed time
          If (Params.TimeOut <> INFINITE) and (GetElapsedMillis >= Params.TimeOut) then
            begin
              // timeout elapsed
              Result := wrTimeout;
              Exit;
            end
          else
            begin
              // still in timeout period, do delaying
              case Params.WaitDelayMethod of
                wdNone:;      // do nothing;
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
              else
               {wdSpin}
                // fill parameters for spinning
                SpinParams.SyncWordPtr := Params.SyncWordPtr;
                SpinParams.SpinCount := Params.WaitSpinCount;
                SpinParams.SpinDelayCount := Params.SpinDelayCount;
                SpinParams.Reserve := False;
                SpinParams.Reserved := Reserved;
                SpinParams.FceReserve := Params.FceReserve;
                SpinParams.FceUnreserve := Params.FceUnreserve;
                SpinParams.FceAcquire := Params.FceAcquire;
                case _DoSpin(SpinParams) of
                  wrAcquired:   Break{while};
                  wrTimeout:;   // just continue, spinning completed without acquire
                  wrReserved:   begin
                                  Result := wrReserved;
                                  Exit;
                                end;
                else
                  Result := wrError;
                  Exit;
                end;
              end
            end;
        end
      else
        begin
          // acquire failed due to reservation
          Result := wrReserved;
          Exit;
        end;
    Result := wrAcquired;
  end;

begin
If GetCounterValue(Params.StartCount) then
  begin
    If Params.Reserve then
      begin
        If Params.FceReserve(Params.SyncWordPtr) then
          try
            Result := InternalWait(True);
          finally
            Params.FceUnreserve(Params.SyncWordPtr);
          end
        else Result := wrReserved;
      end
    else Result := InternalWait(False);
  end
else Result := wrError; 
end;

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

Function TFastLock.GetWaitDelayMethod: TFLWaitDelayMethod;
begin
Result := TFLWaitDelayMethod(InterlockedLoad(fWaitDelayMethod));
end;

//------------------------------------------------------------------------------

procedure TFastLock.SetWaitDelayMethod(Value: TFLWaitDelayMethod);
begin
InterlockedStore(fWaitDelayMethod,UInt32(Ord(Value)));
end;

//------------------------------------------------------------------------------

Function TFastLock.GetWaitSpinCount: UInt32;
begin
Result := InterlockedLoad(fWaitSpinCount);
end;

//------------------------------------------------------------------------------

procedure TFastLock.SetWaitSpinCount(Value: UInt32);
begin
InterlockedStore(fWaitSpinCount,Value);
end;

//------------------------------------------------------------------------------

Function TFastLock.GetSpinDelayCount: UInt32;
begin
Result := InterlockedLoad(fSpinDelayCount);
end;

//------------------------------------------------------------------------------

procedure TFastLock.SetSpinDelayCount(Value: UInt32);
begin
InterlockedStore(fSpinDelayCount,Value);
end;

//------------------------------------------------------------------------------

procedure TFastLock.Initialize(SyncWordPtr: PFLSyncWord);
begin
fSyncWord := FL_UNLOCKED;
fSyncWordPtr := SyncWordPtr;
fOwnsSyncWord := fSyncWordPtr = Addr(fSyncWord);
SetWaitDelayMethod(wdSpin);
SetWaitSpinCount(FL_DEF_WAIT_SPIN_CNT);
SetSpinDelayCount(FL_DEF_SPIN_DELAY_CNT);
If not GetCounterFrequency(fCounterFreq) then
  raise EFLCounterError.CreateFmt('TFastLock.Initialize: Cannot obtain counter frequency (0x%.8x).',
                                  [{$IFDEF Windows}GetLastError{$ELSE}errno{$ENDIF}]);
end;

//------------------------------------------------------------------------------

procedure TFastLock.Finalize;
begin
fSyncWordPtr := nil;
end;

{-------------------------------------------------------------------------------
    TFastLock - public methods
-------------------------------------------------------------------------------}

constructor TFastLock.Create(SyncWordPtr: PFLSyncWord);
begin
inherited Create;
Initialize(SyncWordPtr);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TFastLock.Create;
begin
inherited Create;
Initialize(@fSyncWord);
end;

//------------------------------------------------------------------------------

destructor TFastLock.Destroy;
begin
Finalize;
inherited
end;


{===============================================================================
--------------------------------------------------------------------------------
                              Fast critical section
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    Fast critical section - imlementation constants
===============================================================================}

const
{$IFDEF SyncWord64}

  FL_CS_ACQUIRE_DELTA = TFLSyncWord($0000000000000001);
  FL_CS_ACQUIRE_MASK  = TFLSyncWord($00000000FFFFFFFF);
  FL_CS_ACQUIRE_MAX   = TFLSyncWord(2147483647);  // 0x7FFFFFFF
  FL_CS_ACQUIRE_SHIFT = 0;

  FL_CS_RESERVE_DELTA = TFLSyncWord($0000000100000000);
  FL_CS_RESERVE_MASK  = TFLSyncWord($FFFFFFFF00000000);
  FL_CS_RESERVE_MAX   = TFLSyncWord(2147483647);  // 0x7FFFFFFF
  FL_CS_RESERVE_SHIFT = 32;

{$ELSE} //-  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -

  FL_CS_ACQUIRE_DELTA = TFLSyncWord($00000001);
  FL_CS_ACQUIRE_MASK  = TFLSyncWord($0000FFFF);
  FL_CS_ACQUIRE_MAX   = TFLSyncWord(32767);   // 0x7FFF
  FL_CS_ACQUIRE_SHIFT = 0;

  FL_CS_RESERVE_DELTA = TFLSyncWord($00010000);
  FL_CS_RESERVE_MASK  = TFLSyncWord($FFFF0000);
  FL_CS_RESERVE_MAX   = TFLSyncWord(32767);   // 0x7FFF
  FL_CS_RESERVE_SHIFT = 16;

{$ENDIF}  

{===============================================================================
    Fast critical section - procedural interface implementation
===============================================================================}
{-------------------------------------------------------------------------------
    Fast critical section - internal functions
-------------------------------------------------------------------------------}

Function _FastCriticalSectionReserve(SyncWordPtr: PFLSyncWord): Boolean;
var
  OldSyncWord:  TFLSyncWord;
begin
OldSyncWord := _InterlockedExchangeAdd(SyncWordPtr,FL_CS_RESERVE_DELTA);
Result := ((OldSyncWord and FL_CS_RESERVE_MASK) shr FL_CS_RESERVE_SHIFT) < FL_CS_RESERVE_MAX;
If not Result then
  _InterlockedExchangeSub(SyncWordPtr,FL_CS_RESERVE_DELTA);
end;

//------------------------------------------------------------------------------

procedure _FastCriticalSectionUnreserve(SyncWordPtr: PFLSyncWord);
begin
_InterlockedExchangeSub(SyncWordPtr,FL_CS_RESERVE_DELTA);
end;

//------------------------------------------------------------------------------

Function _FastCriticalSectionEnter(SyncWordPtr: PFLSyncWord; Reserved: Boolean; out FailedDueToReservation: Boolean): Boolean;
var
  OldSyncWord:  TFLSyncWord;
begin
FailedDueToReservation := False;
OldSyncWord := _InterlockedExchangeAdd(SyncWordPtr,FL_CS_ACQUIRE_DELTA);
If ((OldSyncWord and FL_CS_ACQUIRE_MASK) shr FL_CS_ACQUIRE_SHIFT) < FL_CS_ACQUIRE_MAX then
  begin
    If Reserved then
      Result := (((OldSyncWord and FL_CS_RESERVE_MASK) shr FL_CS_RESERVE_SHIFT) <> 0) and
                (((OldSyncWord and FL_CS_ACQUIRE_MASK) shr FL_CS_ACQUIRE_SHIFT) = 0)
    else
      Result := OldSyncWord = 0;
  end
else Result := False;
If not Result then
  _InterlockedExchangeSub(SyncWordPtr,FL_CS_ACQUIRE_DELTA);
end;

//------------------------------------------------------------------------------

Function _FastCriticalSectionWaitToEnter(SyncWordPtr: PFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod; WaitSpinCount, SpinDelayCount: UInt32; CounterFrequency: Int64): TFLWaitResult;
var
  WaitParams: TFLWaitParams;
begin
WaitParams.SyncWordPtr := SyncWordPtr;
WaitParams.Timeout := Timeout;
WaitParams.WaitDelayMethod := WaitDelayMethod;
WaitParams.WaitSpinCount := WaitSpinCount;
WaitParams.SpinDelayCount := SpinDelayCount;
WaitParams.Reserve := True;
WaitParams.FceReserve := _FastCriticalSectionReserve;
WaitParams.FceUnreserve := _FastCriticalSectionUnreserve;
WaitParams.FceAcquire := _FastCriticalSectionEnter;
WaitParams.CounterFrequency := CounterFrequency;
WaitParams.StartCount := 0;
Result := _DoWait(WaitParams);
end;

{-------------------------------------------------------------------------------
    Fast critical section - public functions
-------------------------------------------------------------------------------}

procedure FastCriticalSectionInit(SyncWordPtr: PFLSyncWord);
begin
SyncWordPtr^ := FL_UNLOCKED;
end;

//------------------------------------------------------------------------------

procedure FastCriticalSectionFinal(SyncWordPtr: PFLSyncWord);
begin
SyncWordPtr^ := FL_INVALID; 
end;

//------------------------------------------------------------------------------

Function FastCriticalSectionEnter(SyncWordPtr: PFLSyncWord): Boolean;
var
  FailedDueToReservation: Boolean;
begin
Result := _FastCriticalSectionEnter(SyncWordPtr,False,FailedDueToReservation);
end;

//------------------------------------------------------------------------------

procedure FastCriticalSectionLeave(SyncWordPtr: PFLSyncWord);
begin
_InterlockedExchangeSub(SyncWordPtr,FL_CS_ACQUIRE_DELTA);
end;

//------------------------------------------------------------------------------

Function FastCriticalSectionSpinToEnter(SyncWordPtr: PFLSyncWord; SpinCount: UInt32; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
var
  SpinParams: TFLSpinParams;
begin
SpinParams.SyncWordPtr := SyncWordPtr;
SpinParams.SpinCount := SpinCount;
SpinParams.SpinDelayCount := SpinDelayCount;
SpinParams.Reserve := True;
SpinParams.Reserved := False;
SpinParams.FceReserve := _FastCriticalSectionReserve;
SpinParams.FceUnreserve := _FastCriticalSectionUnreserve;
SpinParams.FceAcquire := _FastCriticalSectionEnter;
Result := _DoSpin(SpinParams);
end;

//------------------------------------------------------------------------------

Function FastCriticalSectionWaitToEnter(SyncWordPtr: PFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin;
  WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
var
  CounterFrequency: Int64;
begin
If GetCounterFrequency(CounterFrequency) then
  Result := _FastCriticalSectionWaitToEnter(SyncWordPtr,Timeout,WaitDelayMethod,WaitSpinCount,SpinDelayCount,CounterFrequency)
else
  raise EFLCounterError.CreateFmt('FastCriticalSectionWaitToEnter: Cannot obtain counter frequency (0x%.8x).',
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

procedure TFastCriticalSection.Initialize(SyncWordPtr: PFLSyncWord);
begin
inherited Initialize(SyncWordPtr);
If fOwnsSyncWord then
  FastCriticalSectionInit(fSyncWordPtr);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Finalize;
begin
If fOwnsSyncWord then
  FastCriticalSectionFinal(fSyncWordPtr);
inherited;
end;

{-------------------------------------------------------------------------------
    TFastCriticalSection - public methods
-------------------------------------------------------------------------------}

Function TFastCriticalSection.Enter: Boolean;
begin
Result := FastCriticalSectionEnter(fSyncWordPtr);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Leave;
begin
FastCriticalSectionLeave(fSyncWordPtr);
end;

//------------------------------------------------------------------------------

Function TFastCriticalSection.SpinToEnter(SpinCount: UInt32): TFLWaitResult;
begin
Result := FastCriticalSectionSpinToEnter(fSyncWordPtr,SpinCount,GetSpinDelayCount);
end;

//------------------------------------------------------------------------------

Function TFastCriticalSection.WaitToEnter(Timeout: UInt32): TFLWaitResult;
begin
Result := _FastCriticalSectionWaitToEnter(fSyncWordPtr,Timeout,GetWaitDelayMethod,GetWaitSpinCount,GetSpinDelayCount,fCounterFreq);
end;


{===============================================================================
--------------------------------------------------------------------------------
                    TFastMREW
--------------------------------------------------------------------------------
===============================================================================}
const
{$IFDEF SyncWord64}

  FL_MREW_READ_DELTA = TFLSyncWord($0000000000000001);
  FL_MREW_READ_MASK  = TFLSyncWord($00000000FFFFFFFF);
  FL_MREW_READ_MAX   = TFLSyncWord(2147483647); // 0x7FFFFFFF
  FL_MREW_READ_SHIFT = 0;

  FL_MREW_WRITE_DELTA = TFLSyncWord($0000000100000000);
  FL_MREW_WRITE_MASK  = TFLSyncWord($0000FFFF00000000);
  FL_MREW_WRITE_MAX   = TFLSyncWord(32767);     // 0x7FFF
  FL_MREW_WRITE_SHIFT = 32;

  FL_MREW_RESERVE_DELTA = TFLSyncWord($0001000000000000);
  FL_MREW_RESERVE_MASK  = TFLSyncWord($FFFF000000000000);
  FL_MREW_RESERVE_MAX   = TFLSyncWord(32767);   // 0x7FFF
  FL_MREW_RESERVE_SHIFT = 48;

{$ELSE}

  FL_MREW_READ_DELTA = TFLSyncWord($00000001);
  FL_MREW_READ_MASK  = TFLSyncWord($00000FFF);
  FL_MREW_READ_MAX   = TFLSyncWord(2047);   // 0x7FF
  FL_MREW_READ_SHIFT = 0;

  FL_MREW_WRITE_DELTA = TFLSyncWord($00001000);
  FL_MREW_WRITE_MASK  = TFLSyncWord($003FF000);
  FL_MREW_WRITE_MAX   = TFLSyncWord(512);   // 0x1FF
  FL_MREW_WRITE_SHIFT = 12;

  FL_MREW_RESERVE_DELTA = TFLSyncWord($00400000);
  FL_MREW_RESERVE_MASK  = TFLSyncWord($FFC00000);
  FL_MREW_RESERVE_MAX   = TFLSyncWord(512); // 0x1FF
  FL_MREW_RESERVE_SHIFT = 22;  

{$ENDIF}

{===============================================================================
    TFastMREW - procedural interface implementation
===============================================================================}

Function _FastMREWReserveWrite(SyncWordPtr: PFLSyncWord): Boolean;
var
  OldSyncWord:  TFLSyncWord;
begin
OldSyncWord := _InterlockedExchangeAdd(SyncWordPtr,FL_MREW_RESERVE_DELTA);
// note that reservation is allowed if there are readers, but no new reader can enter
Result := ((OldSyncWord and FL_MREW_RESERVE_MASK) shr FL_MREW_RESERVE_SHIFT) < FL_MREW_RESERVE_MAX;
If not Result then
  _InterlockedExchangeSub(SyncWordPtr,FL_MREW_RESERVE_DELTA);
end;

//------------------------------------------------------------------------------

procedure _FastMREWUnreserveWrite(SyncWordPtr: PFLSyncWord);
begin
_InterlockedExchangeSub(SyncWordPtr,FL_MREW_RESERVE_DELTA);
end;

//------------------------------------------------------------------------------

Function _FastMREWBeginRead(SyncWordPtr: PFLSyncWord; Reserved: Boolean; out FailedDueToReservation: Boolean): Boolean;
var
  OldSyncWord:  TFLSyncWord;
begin
FailedDueToReservation := False;
OldSyncWord := _InterlockedExchangeAdd(SyncWordPtr,FL_MREW_READ_DELTA);
{
  Do not mask or shift the read count. If there is any writer or reservation
  (which would manifest as count being above reader maximum), straight up fail.
}
If OldSyncWord >= FL_MREW_READ_MAX then
  begin
    _InterlockedExchangeSub(SyncWordPtr,FL_MREW_READ_DELTA);
    // indicate whether this failed solely due to reservation
    FailedDueToReservation := (((OldSyncWord and FL_MREW_WRITE_MASK) shr FL_MREW_WRITE_SHIFT) = 0) and
                              (((OldSyncWord and FL_MREW_RESERVE_MASK) shr FL_MREW_RESERVE_SHIFT) <> 0);
    Result := False;
  end
else Result := True;
end;

//------------------------------------------------------------------------------

Function _FastMREWWaitToRead(SyncWordPtr: PFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod; WaitSpinCount, SpinDelayCount: UInt32; CounterFrequency: Int64): TFLWaitResult;
var
  WaitParams: TFLWaitParams;
begin
WaitParams.SyncWordPtr := SyncWordPtr;
WaitParams.Timeout := Timeout;
WaitParams.WaitDelayMethod := WaitDelayMethod;
WaitParams.WaitSpinCount := WaitSpinCount;
WaitParams.SpinDelayCount := SpinDelayCount;
WaitParams.Reserve := False;
WaitParams.FceReserve := _FastMREWReserveWrite;
WaitParams.FceUnreserve := _FastMREWUnreserveWrite;
WaitParams.FceAcquire := _FastMREWBeginRead;
WaitParams.CounterFrequency := CounterFrequency;
WaitParams.StartCount := 0;
Result := _DoWait(WaitParams);
end;

//------------------------------------------------------------------------------

Function _FastMREWBeginWrite(SyncWordPtr: PFLSyncWord; Reserved: Boolean; out FailedDueToReservation: Boolean): Boolean;
var
  OldSyncWord:  TFLSyncWord;
begin
FailedDueToReservation := False;
OldSyncWord := _InterlockedExchangeAdd(SyncWordPtr,FL_MREW_WRITE_DELTA);
// there can be no reader if writer is to be allowed to enter
If (((OldSyncWord and FL_MREW_READ_MASK) shr FL_MREW_READ_SHIFT) = 0) and
   (((OldSyncWord and FL_MREW_WRITE_MASK) shr FL_MREW_WRITE_SHIFT) < FL_MREW_WRITE_MAX) then
  begin
    If Reserved then
      Result := ((OldSyncWord and FL_MREW_WRITE_MASK) shr FL_MREW_WRITE_SHIFT = 0) and
                ((OldSyncWord and FL_MREW_RESERVE_MASK) shr FL_MREW_RESERVE_SHIFT <> 0)
    else
      Result := OldSyncWord = 0;
  end
else Result := False;
If not Result then
  _InterlockedExchangeSub(SyncWordPtr,FL_MREW_WRITE_DELTA);
end;

//------------------------------------------------------------------------------

Function _FastMREWWaitToWrite(SyncWordPtr: PFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod; WaitSpinCount, SpinDelayCount: UInt32; CounterFrequency: Int64): TFLWaitResult;
var
  WaitParams: TFLWaitParams;
begin
WaitParams.SyncWordPtr := SyncWordPtr;
WaitParams.Timeout := Timeout;
WaitParams.WaitDelayMethod := WaitDelayMethod;
WaitParams.WaitSpinCount := WaitSpinCount;
WaitParams.SpinDelayCount := SpinDelayCount;
WaitParams.Reserve := True;
WaitParams.FceReserve := _FastMREWReserveWrite;
WaitParams.FceUnreserve := _FastMREWUnreserveWrite;
WaitParams.FceAcquire := _FastMREWBeginWrite;
WaitParams.CounterFrequency := CounterFrequency;
WaitParams.StartCount := 0;
Result := _DoWait(WaitParams);
end;

{-------------------------------------------------------------------------------
    Fast RW lock - public functions
-------------------------------------------------------------------------------}

procedure FastMREWInit(SyncWordPtr: PFLSyncWord);
begin
SyncWordPtr^ := FL_UNLOCKED;
end;

//------------------------------------------------------------------------------

procedure FastMREWFinal(SyncWordPtr: PFLSyncWord);
begin
SyncWordPtr^ := FL_INVALID;
end;

//------------------------------------------------------------------------------

Function FastMREWBeginRead(SyncWordPtr: PFLSyncWord): Boolean;
var
  FailedDueToReservation: Boolean;
begin
Result := _FastMREWBeginRead(SyncWordPtr,False,FailedDueToReservation);
end;

//------------------------------------------------------------------------------

procedure FastMREWEndRead(SyncWordPtr: PFLSyncWord);
begin
_InterlockedExchangeSub(SyncWordPtr,FL_MREW_READ_DELTA);
end;

//------------------------------------------------------------------------------

Function FastMREWSpinToRead(SyncWordPtr: PFLSyncWord; SpinCount: UInt32; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
var
  SpinParams: TFLSpinParams;
begin
SpinParams.SyncWordPtr := SyncWordPtr;
SpinParams.SpinCount := SpinCount;
SpinParams.SpinDelayCount := SpinDelayCount;
SpinParams.Reserve := False;
SpinParams.Reserved := False;
SpinParams.FceReserve := _FastMREWReserveWrite;
SpinParams.FceUnreserve := _FastMREWUnreserveWrite;
SpinParams.FceAcquire := _FastMREWBeginRead;
Result := _DoSpin(SpinParams);
end;

//------------------------------------------------------------------------------

Function FastMREWWaitToRead(SyncWordPtr: PFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin;
  WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
var
  CounterFrequency: Int64;
begin
If GetCounterFrequency(CounterFrequency) then
  Result := _FastMREWWaitToRead(SyncWordPtr,Timeout,WaitDelayMethod,WaitSpinCount,SpinDelayCount,CounterFrequency)
else
  raise EFLCounterError.CreateFmt('FastMREWWaitToRead: Cannot obtain counter frequency (0x%.8x).',
                                  [{$IFDEF Windows}GetLastError{$ELSE}errno{$ENDIF}]);
end;

//------------------------------------------------------------------------------

Function FastMREWBeginWrite(SyncWordPtr: PFLSyncWord): Boolean;
var
  FailedDueToReservation: Boolean;
begin
Result := _FastMREWBeginWrite(SyncWordPtr,False,FailedDueToReservation);
end;

//------------------------------------------------------------------------------

procedure FastMREWEndWrite(SyncWordPtr: PFLSyncWord);
begin
_InterlockedExchangeSub(SyncWordPtr,FL_MREW_WRITE_DELTA);
end;

//------------------------------------------------------------------------------

Function FastMREWSpinToWrite(SyncWordPtr: PFLSyncWord; SpinCount: UInt32; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
var
  SpinParams: TFLSpinParams;
begin
SpinParams.SyncWordPtr := SyncWordPtr;
SpinParams.SpinCount := SpinCount;
SpinParams.SpinDelayCount := SpinDelayCount;
SpinParams.Reserve := True;
SpinParams.Reserved := False;
SpinParams.FceReserve := _FastMREWReserveWrite;
SpinParams.FceUnreserve := _FastMREWUnreserveWrite;
SpinParams.FceAcquire := _FastMREWBeginWrite;
Result := _DoSpin(SpinParams);
end;

//------------------------------------------------------------------------------

Function FastMREWWaitToWrite(SyncWordPtr: PFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin;
  WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
var
  CounterFrequency: Int64;
begin
If GetCounterFrequency(CounterFrequency) then
  Result := _FastMREWWaitToWrite(SyncWordPtr,Timeout,WaitDelayMethod,WaitSpinCount,SpinDelayCount,CounterFrequency)
else
  raise EFLCounterError.CreateFmt('FastMREWWaitToWrite: Cannot obtain counter frequency (0x%.8x).',
                                  [{$IFDEF Windows}GetLastError{$ELSE}errno{$ENDIF}]);
end;

{===============================================================================
    TFastMREW - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TFastMREW - protected methods
-------------------------------------------------------------------------------}

procedure TFastMREW.Initialize(SyncWordPtr: PFLSyncWord);
begin
inherited Initialize(SyncWordPtr);
If fOwnsSyncWord then
  FastMREWInit(fSyncWordPtr);
end;

//------------------------------------------------------------------------------

procedure TFastMREW.Finalize;
begin
If fOwnsSyncWord then
  FastMREWFinal(fSyncWordPtr);
inherited;
end;

{-------------------------------------------------------------------------------
    TFastMREW - public methods
-------------------------------------------------------------------------------}

Function TFastMREW.BeginRead: Boolean;
begin
Result := FastMREWBeginRead(fSyncWordPtr);
end;

//------------------------------------------------------------------------------

procedure TFastMREW.EndRead;
begin
FastMREWEndRead(fSyncWordPtr);
end;

//------------------------------------------------------------------------------

Function TFastMREW.BeginWrite: Boolean;
begin
Result := FastMREWBeginWrite(fSyncWordPtr);
end;

//------------------------------------------------------------------------------

procedure TFastMREW.EndWrite;
begin
FastMREWEndWrite(fSyncWordPtr);
end;

//------------------------------------------------------------------------------

Function TFastMREW.SpinToRead(SpinCount: UInt32): TFLWaitResult;
begin
Result := FastMREWSpinToRead(fSyncWordPtr,SpinCount,GetSpinDelayCount);
end;

//------------------------------------------------------------------------------

Function TFastMREW.WaitToRead(Timeout: UInt32): TFLWaitResult;
begin
Result := _FastMREWWaitToRead(fSyncWordPtr,Timeout,GetWaitDelayMethod,GetWaitSpinCount,GetSpinDelayCount,fCounterFreq);
end;

//------------------------------------------------------------------------------

Function TFastMREW.SpinToWrite(SpinCount: UInt32): TFLWaitResult;
begin
Result := FastMREWSpinToWrite(fSyncWordPtr,SpinCount,GetSpinDelayCount);
end;

//------------------------------------------------------------------------------

Function TFastMREW.WaitToWrite(Timeout: UInt32): TFLWaitResult;
begin
Result := _FastMREWWaitToWrite(fSyncWordPtr,Timeout,GetWaitDelayMethod,GetWaitSpinCount,GetSpinDelayCount,fCounterFreq);
end;

end.

