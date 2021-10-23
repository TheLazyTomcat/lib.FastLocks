{-------------------------------------------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

-------------------------------------------------------------------------------}
{===============================================================================

  FastLocks

    Simple non-blocking synchronization objects based on interlocked functions
    operating on locking flags and counters.

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
    For details about how any of the object works and what are its limitation,
    refer to its declaration.

    In its basic form, each in-here implemented synchronizer is just an integer
    residing in the memory. Within this library, this integer is called flag
    word.
    It is used to store the locking flags and/or counters and interlocked
    functions are used to atomically change and probe stored values and to
    decide state of the object and required action.

      WARNING - all implemented synchronizers are operating on the same flag
                word type (TFLFlagWord), but they are not mutually compatible.
                So always use one flag word for only one type of synchronizer,
                newer mix them on one variable.

    All synchronizers can be used either directly, where you allocate a variable
    of type TFLFlagWord and then operate on it using interface functions (eg.
    FastCriticalSectionReserve, FastMREWBeginRead, ...), or indirectly,
    by creating an instance of provided class and using its methods.

    When creating the class instance, you can either provide preallocated flag
    word variable or leave its complete management on the instance itself.
    This gives you more freedom in deciding how to use the sychnonization - you
    can either allocate common flag word and create new instance for each
    syhcnronizing thread, or you can create one common instance and us >it< in
    all threads.

      NOTE - if the flag vord variable is located in a shared memory, the
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
  FlagWord64

  When this symbol is defined, the type used for flag words (TFLFlagWord), and
  therefore the flag words themselves, is 64 bits wide, otherwise it is 32 bits
  wide.

  This holds true on all systems.

  By default defined.
}
{$DEFINE FlagWord64}

interface

uses
  SysUtils,
  AuxTypes, AuxClasses;

{===============================================================================
    Library-specific exceptions
===============================================================================}
type
  EFLException = class(Exception);

  EFLCreationError = class(EFLException);
  EFLInvalidValue  = class(EFLException);

{===============================================================================
--------------------------------------------------------------------------------
                                    TFastLock
--------------------------------------------------------------------------------
===============================================================================}

const
  FL_DEF_SPIN_DELAY_CNT = 1000;
  FL_DEF_WAIT_SPIN_CNT  = 1500;

  INFINITE = UInt32(-1);  // infinite timeout interval

type
  TFLFlagWord = {$IFDEF FlagWord64}UInt64{$ELSE}UInt32{$ENDIF};
  PFLFlagWord = ^TFLFlagWord;

{
  Returned as a result of spinning or waiting (methods SpinTo* and WaitTo*).
  Informs whether a required access to the synchronizer was granted and if not,
  for what reason.

    wrAcquired - requested access was granted and the object is now locked

    wrTimeOut  - spinning/waiting timed-out, ie. access was not granted in
                 given timeout period

    wrReserved - spinning/waiting failed and the acces was not granted because
                 the synchronizer was reserved or a maximum reservation count
                 was reached

    wrError    - an error has ocurred
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

  // TFLAcquireMethod is only for internal use, but must be public
  TFLAcquireMethod = Function(Reserved: Boolean): Boolean of object;

{===============================================================================
    TFastLock - class declaration
===============================================================================}
{$message 'add description of spinning/waiting'}
type
  TFastLock = class(TCustomObject)
  protected
    fFlagWord:        TFLFlagWord;
    fFlagWordPtr:     PFLFlagWord;
    fOwnsFlagWord:    Boolean;
    fCounterFreq:     Int64;
    fSpinDelayCount:  UInt32;
    fWaitSpinCount:   UInt32;
    Function GetSpinDelayCount: UInt32; virtual;
    procedure SetSpinDelayCount(Value: UInt32); virtual;
    Function GetWaitSpinCount: UInt32; virtual;
    procedure SetWaitSpinCount(Value: UInt32); virtual;
    Function ReserveLock: Boolean; virtual; abstract;
    procedure UnreserveLock; virtual; abstract;
    Function SpinOn(SpinCount: UInt32; AcquireMethod: TFLAcquireMethod; Reserved, Reserve: Boolean): TFLWaitResult; virtual;
    Function WaitOn(TimeOut: UInt32; AcquireMethod: TFLAcquireMethod; WaitDelayMethod: TFLWaitDelayMethod; Reserve: Boolean): TFLWaitResult; virtual;
    procedure Initialize(FlagWordPtr: PFLFlagWord); virtual;
    procedure Finalize; virtual;
  public
    constructor Create(FlagWordPtr: PFLFlagWord); overload; virtual;
    constructor Create; overload; virtual;
    destructor Destroy; override;
    property SpinDelayCount: UInt32 read GetSpinDelayCount write SetSpinDelayCount;
    property WaitSpinCount: UInt32 read GetWaitSpinCount write SetWaitSpinCount;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                              TFastCriticalSection
--------------------------------------------------------------------------------
===============================================================================}
{
  Classical critical section - only one thread can acquire lock, and while it
  is locked all subsequent attemps to acquire/enter it will fail.
}
{===============================================================================
    TFastCriticalSection - flat interface declaration
===============================================================================}
{
  Call FastCriticalSectionInit only once for each flag word. If you call it for
  already initialized/used flag word, it will be reinitialized.

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
  
  The section can be reserved multiple times, but each successful reservation
  must be paired with unreservation.

  Recommended sequence while using reservation is af follows:

    If FastCriticalSectionReserve then
    try
      If FastCriticalSectionEnter(True) then
      try
        <synchronized_code>
      finally
        FastCriticalSectionLeave;
      end;
    finally
      FastCriticalSectionUnreserve;
    end;
}

procedure FastCriticalSectionInit(FlagWordPtr: PFLFlagWord);
procedure FastCriticalSectionFinal(FlagWordPtr: PFLFlagWord);

Function FastCriticalSectionReserve(FlagWordPtr: PFLFlagWord): Boolean;
procedure FastCriticalSectionUnreserve(FlagWordPtr: PFLFlagWord);

Function FastCriticalSectionEnter(FlagWordPtr: PFLFlagWord; Reserved: Boolean = False): Boolean;
procedure FastCriticalSectionLeave(FlagWordPtr: PFLFlagWord);

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
    Function ReserveLock: Boolean; override;
    procedure UnreserveLock; override;
    Function Acquire(Reserved: Boolean): Boolean; virtual;
    procedure Release; virtual;
    procedure Initialize(FlagWordPtr: PFLFlagWord); override;
    procedure Finalize; override;
  public
    Function Enter: Boolean; virtual;
    procedure Leave; virtual;
    Function SpinToEnter(SpinCount: UInt32): TFLWaitResult; virtual;
    Function WaitToEnter(Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin): TFLWaitResult; virtual;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                    TFastMultiReadExclusiveWriteSynchronizer
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastMultiReadExclusiveWriteSynchronizer - flat interface declaration
===============================================================================}

procedure FastMREWInit(FlagWordPtr: PFLFlagWord);
procedure FastMREWFinal(FlagWordPtr: PFLFlagWord);

Function FastMREWBeginRead(FlagWordPtr: PFLFlagWord): Boolean;
procedure FastMREWEndRead(FlagWordPtr: PFLFlagWord);

Function FastMREWReserveWrite(FlagWordPtr: PFLFlagWord): Boolean;
procedure FastMREWUnreserveWrite(FlagWordPtr: PFLFlagWord);

Function FastMREWBeginWrite(FlagWordPtr: PFLFlagWord; Reserved: Boolean = False): Boolean;
procedure FastMREWEndWrite(FlagWordPtr: PFLFlagWord);

{===============================================================================
    TFastMultiReadExclusiveWriteSynchronizer - class declaration
===============================================================================}
type
  TFastMultiReadExclusiveWriteSynchronizer = class(TFastLock)
  protected
    Function ReserveLock: Boolean; override;
    procedure UnreserveLock; override;
    Function AcquireRead(Reserved: Boolean): Boolean; virtual;
    procedure ReleaseRead; virtual;
    Function AcquireWrite(Reserved: Boolean): Boolean; virtual;
    procedure ReleaseWrite; virtual;
    procedure Initialize(FlagWordPtr: PFLFlagWord); override;
    procedure Finalize; override;    
  public
    Function BeginRead: Boolean; virtual;
    procedure EndRead; virtual;
    Function BeginWrite: Boolean; virtual;
    procedure EndWrite; virtual;
    Function SpinToRead(SpinCount: UInt32): TFLWaitResult; virtual;
    Function WaitToRead(Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin): TFLWaitResult; virtual;
    Function SpinToWrite(SpinCount: UInt32): TFLWaitResult; virtual;
    Function WaitToWrite(Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin): TFLWaitResult; virtual;
  end;

  // shorter name alias
  TFastMREW = TFastMultiReadExclusiveWriteSynchronizer;

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
// just some relatively long, but othervise pointless, operation
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

Function YieldThread: Boolean;
begin
{$IFDEF Windows}
Result := SwitchToThread;
{$ELSE}
Result := sched_yield = 0;
{$ENDIF}
end;

{===============================================================================
    Interlocked functions wrappers
===============================================================================}

Function _InterlockedExchangeAdd(A: PFLFlagWord; B: TFLFlagWord): TFLFlagWord;{$IFDEF CanInline} inline;{$ENDIF}
begin
{$IFDEF FlagWord64}
Result := InterlockedExchangeAdd64(A,B);      
{$ELSE}
Result := InterlockedExchangeAdd32(A,B);
{$ENDIF}
end;

//------------------------------------------------------------------------------

Function _InterlockedExchangeSub(A: PFLFlagWord; B: TFLFlagWord): TFLFlagWord;{$IFDEF CanInline} inline;{$ENDIF}
begin
{$IFDEF FlagWord64}
Result := InterlockedExchangeSub64(A,B);
{$ELSE}
Result := InterlockedExchangeSub32(A,B);
{$ENDIF}
end;

{===============================================================================
    Imlementation constants
===============================================================================}

const
{$IFDEF FlagWord64}
  FL_UNLOCKED = TFLFLagWord(0);

//------------------------------------------------------------------------------

  FL_CS_ACQUIRE_DELTA = TFLFLagWord($0000000000000001);
  FL_CS_ACQUIRE_MASK  = TFLFLagWord($00000000FFFFFFFF);
  FL_CS_ACQUIRE_MAX   = TFLFLagWord(2147483647);    // 0x7FFFFFFF
  FL_CS_ACQUIRE_SHIFT = 0;

  FL_CS_RESERVE_DELTA = TFLFLagWord($0000000100000000);
  FL_CS_RESERVE_MASK  = TFLFLagWord($FFFFFFFF00000000);
  FL_CS_RESERVE_MAX   = TFLFLagWord(2147483647);    // 0x7FFFFFFF
  FL_CS_RESERVE_SHIFT = 32;

//------------------------------------------------------------------------------

  FL_MREW_READ_DELTA = TFLFLagWord($0000000000000001);
  FL_MREW_READ_MASK  = TFLFLagWord($00000000FFFFFFFF);
  FL_MREW_READ_MAX   = TFLFLagWord(2147483647);     // 0x7FFFFFFF
  FL_MREW_READ_SHIFT = 0;

  FL_MREW_WRITE_DELTA = TFLFLagWord($0000000100000000);
  FL_MREW_WRITE_MASK  = TFLFLagWord($0000FFFF00000000);
  FL_MREW_WRITE_MAX   = TFLFLagWord(32767);         // 0x7FFF
  FL_MREW_WRITE_SHIFT = 32;

  FL_MREW_RESERVE_DELTA = TFLFLagWord($0001000000000000);
  FL_MREW_RESERVE_MASK  = TFLFLagWord($FFFF000000000000);
  FL_MREW_RESERVE_MAX   = TFLFLagWord(32767);       // 0x7FFF
  FL_MREW_RESERVE_SHIFT = 48;

{$ELSE}
  FL_UNLOCKED = TFLFLagWord(0);

//------------------------------------------------------------------------------

  FL_CS_ACQUIRE_DELTA = TFLFLagWord($00000001);
  FL_CS_ACQUIRE_MASK  = TFLFLagWord($0000FFFF);
  FL_CS_ACQUIRE_MAX   = TFLFLagWord(32767);         // 0x7FFF
  FL_CS_ACQUIRE_SHIFT = 0;

  FL_CS_RESERVE_DELTA = TFLFLagWord($00010000);
  FL_CS_RESERVE_MASK  = TFLFLagWord($FFFF0000);
  FL_CS_RESERVE_MAX   = TFLFLagWord(32767);         // 0x7FFF
  FL_CS_RESERVE_SHIFT = 16;

//------------------------------------------------------------------------------

  FL_MREW_READ_DELTA = TFLFLagWord($00000001);
  FL_MREW_READ_MASK  = TFLFLagWord($00000FFF);
  FL_MREW_READ_MAX   = TFLFLagWord(2047);           // 0x7FF
  FL_MREW_READ_SHIFT = 0;

  FL_MREW_WRITE_DELTA = TFLFLagWord($00001000);
  FL_MREW_WRITE_MASK  = TFLFLagWord($003FF000);
  FL_MREW_WRITE_MAX   = TFLFLagWord(512);           // 0x1FF
  FL_MREW_WRITE_SHIFT = 12;

  FL_MREW_RESERVE_DELTA = TFLFLagWord($00400000);
  FL_MREW_RESERVE_MASK  = TFLFLagWord($FFC00000);
  FL_MREW_RESERVE_MAX   = TFLFLagWord(512);         // 0x1FF
  FL_MREW_RESERVE_SHIFT = 22;  

{$ENDIF}
(*
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
  Meaning of bits in main flag word in TFastMultiReadExclusiveWriteSynchronizer:

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
                                    TFastLock
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastLock - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TFastLock - protected methods
-------------------------------------------------------------------------------}

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

Function TFastLock.SpinOn(SpinCount: UInt32; AcquireMethod: TFLAcquireMethod; Reserved, Reserve: Boolean): TFLWaitResult;
var
  SpinDelays: UInt32;

  Function Spin: Boolean;
  var
    i:  Integer;
  begin
    // spin delay
    For i := 1 to SpinDelays do
      SpinDelay(i);
    If SpinCount <> INFINITE then
      Dec(SpinCount);
    Result := SpinCount > 0;
  end;

//--  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --  --

  Function InternalSpin(IsReserved: Boolean): TFLWaitResult;
  begin
    while not AcquireMethod(IsReserved) do
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
  SpinDelays := GetSpinDelayCount;
  If Reserve then
    begin
      If ReserveLock then
        try
          Result := InternalSpin(True);
        finally
          UnreserveLock;
        end
      else Result := wrReserved;
    end
  else Result := InternalSpin(Reserved);
except
  Result := wrError;
end;
end;

//------------------------------------------------------------------------------

Function TFastLock.WaitOn(TimeOut: UInt32; AcquireMethod: TFLAcquireMethod; WaitDelayMethod: TFLWaitDelayMethod; Reserve: Boolean): TFLWaitResult;
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

  Function InternalWait(IsReserved: Boolean): TFLWaitResult;
  begin
    while not AcquireMethod(False) do
      If (TimeOut <> INFINITE) and (GetElapsedMillis >= TimeOut) then
        begin
          Result := wrTimeout;
          Exit;
        end
      else
        begin
          case WaitDelayMethod of
            wdNone:;      // do nothing;
            wdSpin:       If SpinOn(WaitSpinCntLocal,AcquireMethod,IsReserved,False) = wrAcquired then
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
    If Reserve then
      begin
        If ReserveLock then
          try
            Result := InternalWait(True);
          finally
            UnreserveLock;
          end
        else Result := wrReserved;
      end
    else Result := InternalWait(False);
  end
else Result := wrError;  
end;

//------------------------------------------------------------------------------

procedure TFastLock.Initialize(FlagWordPtr: PFLFlagWord);
begin
fFlagWord := FL_UNLOCKED;
fFlagWordPtr := FlagWordPtr;
fOwnsFlagWord := fFlagWordPtr = Addr(fFlagWord);
If not GetCounterFrequency(fCounterFreq) then
  raise EFLCreationError.CreateFmt('TFastLock.Initialize: Cannot obtain counter frequency (0x%.8x).',
                                   [{$IFDEF Windows}GetLastError{$ELSE}errno{$ENDIF}]);
SetWaitSpinCount(FL_DEF_WAIT_SPIN_CNT);
SetSpinDelayCount(FL_DEF_SPIN_DELAY_CNT);
end;

//------------------------------------------------------------------------------

procedure TFastLock.Finalize;
begin
fFlagWordPtr := nil;
end;

{-------------------------------------------------------------------------------
    TFastLock - public methods
-------------------------------------------------------------------------------}

constructor TFastLock.Create(FlagWordPtr: PFLFlagWord);
begin
inherited Create;
Initialize(FlagWordPtr);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TFastLock.Create;
begin
inherited Create;
Initialize(@fFlagWord);
end;

//------------------------------------------------------------------------------

destructor TFastLock.Destroy;
begin
Finalize;
inherited
end;


{===============================================================================
--------------------------------------------------------------------------------
                              TFastCriticalSection
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastCriticalSection - flat interface implementation
===============================================================================}

procedure FastCriticalSectionInit(FlagWordPtr: PFLFlagWord);
begin
FlagWordPtr^ := FL_UNLOCKED;
end;

//------------------------------------------------------------------------------

procedure FastCriticalSectionFinal(FlagWordPtr: PFLFlagWord);
begin
FlagWordPtr^ := TFLFlagWord(-1);  // fully locked
end;

//------------------------------------------------------------------------------

Function FastCriticalSectionReserve(FlagWordPtr: PFLFlagWord): Boolean;
var
  OldFlagWord:  TFLFlagWord;
begin
OldFlagWord := _InterlockedExchangeAdd(FlagWordPtr,FL_CS_RESERVE_DELTA);
Result := ((OldFlagWord and FL_CS_RESERVE_MASK) shr FL_CS_RESERVE_SHIFT) < FL_CS_RESERVE_MAX;
If not Result then
  _InterlockedExchangeSub(FlagWordPtr,FL_CS_RESERVE_DELTA);
end;

//------------------------------------------------------------------------------

procedure FastCriticalSectionUnreserve(FlagWordPtr: PFLFlagWord);
begin
_InterlockedExchangeSub(FlagWordPtr,FL_CS_RESERVE_DELTA);
end;

//------------------------------------------------------------------------------

Function FastCriticalSectionEnter(FlagWordPtr: PFLFlagWord; Reserved: Boolean = False): Boolean;
var
  OldFlagWord:  TFLFlagWord;
begin
OldFlagWord := _InterlockedExchangeAdd(FlagWordPtr,FL_CS_ACQUIRE_DELTA);
If ((OldFlagWord and FL_CS_ACQUIRE_MASK) shr FL_CS_ACQUIRE_SHIFT) < FL_CS_ACQUIRE_MAX then
  begin
    If Reserved then
      Result := (((OldFlagWord and FL_CS_RESERVE_MASK) shr FL_CS_RESERVE_SHIFT) > 0) and
                (((OldFlagWord and FL_CS_ACQUIRE_MASK) shr FL_CS_ACQUIRE_SHIFT) = 0)
    else
      Result := OldFlagWord = FL_UNLOCKED;
  end
else Result := False;
If not Result then
  _InterlockedExchangeSub(FlagWordPtr,FL_CS_ACQUIRE_DELTA);
end;

//------------------------------------------------------------------------------

procedure FastCriticalSectionLeave(FlagWordPtr: PFLFlagWord);
begin
_InterlockedExchangeSub(FlagWordPtr,FL_CS_ACQUIRE_DELTA);
end;

{===============================================================================
    TFastCriticalSection - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TFastCriticalSection - protected methods
-------------------------------------------------------------------------------}

Function TFastCriticalSection.ReserveLock: Boolean;
begin
Result := FastCriticalSectionReserve(fFlagWordPtr);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.UnreserveLock;
begin
FastCriticalSectionUnreserve(fFlagWordPtr);
end;

//------------------------------------------------------------------------------

Function TFastCriticalSection.Acquire(Reserved: Boolean): Boolean;
begin
Result := FastCriticalSectionEnter(fFlagWordPtr,Reserved);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Release;
begin
FastCriticalSectionLeave(fFlagWordPtr);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Initialize(FlagWordPtr: PFLFlagWord);
begin
inherited Initialize(FlagWordPtr);
If fOwnsFlagWord then
  FastCriticalSectionInit(fFlagWordPtr);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Finalize;
begin
If fOwnsFlagWord then
  FastCriticalSectionFinal(fFlagWordPtr);
inherited;
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

Function TFastCriticalSection.SpinToEnter(SpinCount: UInt32): TFLWaitResult;
begin
Result := SpinOn(SpinCount,Self.Acquire,False,True);
end;

//------------------------------------------------------------------------------

Function TFastCriticalSection.WaitToEnter(Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin): TFLWaitResult;
begin
Result := WaitOn(Timeout,Self.Acquire,WaitDelayMethod,True);
end;


{===============================================================================
--------------------------------------------------------------------------------
                    TFastMultiReadExclusiveWriteSynchronizer
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastMultiReadExclusiveWriteSynchronizer - flat interface implementation
===============================================================================}

procedure FastMREWInit(FlagWordPtr: PFLFlagWord);
begin
FlagWordPtr^ := FL_UNLOCKED;
end;

//------------------------------------------------------------------------------

procedure FastMREWFinal(FlagWordPtr: PFLFlagWord);
begin
FlagWordPtr^ := TFLFlagWord(-1);
end;

//------------------------------------------------------------------------------

Function FastMREWBeginRead(FlagWordPtr: PFLFlagWord): Boolean;
begin
{
  Do not mask or shift the read count. If there is any writer or reservation
  (which would manifest as count being abowe reader maximum), straight up fail.
}
Result := _InterlockedExchangeAdd(FlagWordPtr,FL_MREW_READ_DELTA) < FL_MREW_READ_MAX;
If not Result then
  _InterlockedExchangeSub(FlagWordPtr,FL_MREW_READ_DELTA);
end; {$message 'indicate whther this failed due to reservation'}

//------------------------------------------------------------------------------

procedure FastMREWEndRead(FlagWordPtr: PFLFlagWord);
begin
_InterlockedExchangeSub(FlagWordPtr,FL_MREW_READ_DELTA);
end;

//------------------------------------------------------------------------------

Function FastMREWReserveWrite(FlagWordPtr: PFLFlagWord): Boolean;
var
  OldFlagWord:  TFLFlagWord;
begin
OldFlagWord := _InterlockedExchangeAdd(FlagWordPtr,FL_MREW_RESERVE_DELTA);
// note that reservation is allowed if there are readers, but no new reader can enter
Result := ((OldFlagWord and FL_MREW_RESERVE_MASK) shr FL_MREW_RESERVE_SHIFT) < FL_MREW_RESERVE_MAX;
If not Result then
  _InterlockedExchangeSub(FlagWordPtr,FL_MREW_RESERVE_DELTA);
end;

//------------------------------------------------------------------------------

procedure FastMREWUnreserveWrite(FlagWordPtr: PFLFlagWord);
begin
_InterlockedExchangeSub(FlagWordPtr,FL_MREW_RESERVE_DELTA);
end;

//------------------------------------------------------------------------------

Function FastMREWBeginWrite(FlagWordPtr: PFLFlagWord; Reserved: Boolean = False): Boolean;
var
  OldFlagWord:  TFLFlagWord;
begin
OldFlagWord := _InterlockedExchangeAdd(FlagWordPtr,FL_MREW_WRITE_DELTA);
// there can be no reader if writer is to be allowed to enter
If (((OldFlagWord and FL_MREW_READ_MASK) shr FL_MREW_READ_SHIFT) = 0) and
   (((OldFlagWord and FL_MREW_WRITE_MASK) shr FL_MREW_WRITE_SHIFT) < FL_MREW_WRITE_MAX) then
  begin
    If Reserved then
      Result := (OldFlagWord and not FL_MREW_RESERVE_MASK) = FL_UNLOCKED
    else
      Result := OldFlagWord = FL_UNLOCKED;
  end
else Result := False;
If not Result then
  _InterlockedExchangeSub(FlagWordPtr,FL_MREW_WRITE_DELTA);
end;

//------------------------------------------------------------------------------

procedure FastMREWEndWrite(FlagWordPtr: PFLFlagWord);
begin
_InterlockedExchangeSub(FlagWordPtr,FL_MREW_WRITE_DELTA);
end;

{===============================================================================
    TFastMultiReadExclusiveWriteSynchronizer - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TFastMultiReadExclusiveWriteSynchronizer - protected methods
-------------------------------------------------------------------------------}

Function TFastMultiReadExclusiveWriteSynchronizer.ReserveLock: Boolean;
begin
Result := FastMREWReserveWrite(fFlagWordPtr);
end;

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.UnreserveLock;
begin
FastMREWUnreserveWrite(fFlagWordPtr);
end;

//------------------------------------------------------------------------------

{$IFDEF FPCDWM}{$PUSH}W5024{$ENDIF}
Function TFastMultiReadExclusiveWriteSynchronizer.AcquireRead(Reserved: Boolean): Boolean;
begin
Result := FastMREWBeginRead(fFlagWordPtr);
end;
{$IFDEF FPCDWM}{$POP}{$ENDIF}

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.ReleaseRead;
begin
FastMREWEndRead(fFlagWordPtr);
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.AcquireWrite(Reserved: Boolean): Boolean;
begin
Result := FastMREWBeginWrite(fFlagWordPtr,Reserved);
end;

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.ReleaseWrite;
begin
FastMREWEndWrite(fFlagWordPtr);
end;

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.Initialize(FlagWordPtr: PFLFlagWord);
begin
inherited Initialize(FlagWordPtr);
If fOwnsFlagWord then
  FastMREWInit(fFlagWordPtr);
end;

//------------------------------------------------------------------------------

procedure TFastMultiReadExclusiveWriteSynchronizer.Finalize;
begin
If fOwnsFlagWord then
  FastMREWFinal(fFlagWordPtr);
inherited;
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
Result := SpinOn(SpinCount,Self.AcquireRead,False,False);
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.WaitToRead(Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin): TFLWaitResult;
begin
Result := WaitOn(Timeout,Self.AcquireRead,WaitDelayMethod,False);
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.SpinToWrite(SpinCount: UInt32): TFLWaitResult;
begin
Result := SpinOn(SpinCount,Self.AcquireWrite,False,True);
end;

//------------------------------------------------------------------------------

Function TFastMultiReadExclusiveWriteSynchronizer.WaitToWrite(Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = wdSpin): TFLWaitResult;
begin
Result := WaitOn(Timeout,Self.AcquireWrite,WaitDelayMethod,True);
end;

end.

