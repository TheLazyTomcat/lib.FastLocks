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
      of thousands of separate data structures, each of which could have been
      accessed by several threads, and where parallel access was rare but very
      possible and dangerous. When a simultaneous access occured, it was almost
      always reading.

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

      WARNING - do not directly read or write sync word variables, use only
                functions provided for individual synchronizers.

    All synchronizers can be used either directly, where you declare or allocate a variable
    of type TFLSyncWord and then operate on it using procedural interface (eg.
    FastCriticalSectionEnter, FastMREWBeginRead, ...), or indirectly, creating
    an instance of provided class and using its methods.

    When creating the class instance, you can either provide preallocated sync
    word variable or leave its complete management on the instance itself.
    This gives you more freedom in deciding how to use the sychnonization - you
    can either allocate common sync word and create new instance for each
    syhcnronizing thread, or you can create one common instance and use >it< in
    all threads.

      NOTE - if the sync word variable is located in a shared memory, the
             synchronizers can then be used for inter-process synchronization.

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

    Some more important notes on the implementation and use:

      - none of the provided synchronizers is robust (when a thread holding
        a lock ends without releasing it, it will stay locked indefinitely)

      - none of the provided synchronizers is recursive (when attempting to
        acquire a lock second time in the same thread, it will always fail)

      - there is absolutely no deadlock prevention - be extremely carefull when
        trying to acquire synchronizer in more than one place in a single thread
        (trying to acquire synchronizer second time in the same thread will
        always fail, with exception being MREW reading, which is given by
        concept of multiple readers access)

      - use provided waiting and spinning only when necessary - synchronizers
        are intended to be primarily used as non-blocking

      - waiting is always active (spinning) - do not wait for prolonged time
        intervals as it might starve other threads, use infinite waiting only
        in extreme cases and only when really necessary

      - use synchronization by provided objects only on very short (in time,
        not code) routines - do not use to synchronize code that is executing
        longer than few milliseconds

      - every successful acquire of a synchronizer MUST be paired by a release,
        synhronizers are not automalically released

  Version 1.3.2 (2024-05-02)

  Last change 2026-02-25

  ©2016-2026 František Milt

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
    AuxClasses     - github.com/TheLazyTomcat/Lib.AuxClasses
  * AuxExceptions  - github.com/TheLazyTomcat/Lib.AuxExceptions
    AuxTypes       - github.com/TheLazyTomcat/Lib.AuxTypes
    InterlockedOps - github.com/TheLazyTomcat/Lib.InterlockedOps

  Library AuxExceptions is required only when rebasing local exception classes
  (see symbol FastLocks_UseAuxExceptions for details).

  Library AuxExceptions might also be required as an indirect dependency.

  Indirect dependencies:
    ListUtils   - github.com/TheLazyTomcat/Lib.ListUtils
    SimpleCPUID - github.com/TheLazyTomcat/Lib.SimpleCPUID
    StrRect     - github.com/TheLazyTomcat/Lib.StrRect
    UInt64Utils - github.com/TheLazyTomcat/Lib.UInt64Utils
    WinFileInfo - github.com/TheLazyTomcat/Lib.WinFileInfo

===============================================================================}
{$message 'todo: rework description'}
unit FastLocks;
{
  FastLocks_PurePascal

  If you want to compile this unit without ASM, don't want to or cannot define
  PurePascal for the entire project and at the same time you don't want to or
  cannot make changes to this unit, define this symbol for the entire project
  and only this unit will be compiled in PurePascal mode.
}
{$IFDEF FastLocks_PurePascal}
  {$DEFINE PurePascal}
{$ENDIF}

{
  FastLocks_UseAuxExceptions

  If you want library-specific exceptions to be based on more advanced classes
  provided by AuxExceptions library instead of basic Exception class, and don't
  want to or cannot change code in this unit, you can define global symbol
  FastLocks_UseAuxExceptions to achieve this.
}
{$IF Defined(FastLocks_UseAuxExceptions)}
  {$DEFINE UseAuxExceptions}
{$IFEND}
//------------------------------------------------------------------------------

{$IF defined(CPUX86_64) or defined(CPUX64)}
  {$DEFINE x64}
{$ELSEIF defined(CPU386)}
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
  {$MODESWITCH ClassicProcVars+}
  {$DEFINE FPC_DisableWarns}
  {$MACRO ON}
  {$DEFINE CanInline}  
  {$INLINE ON}
  {$IFNDEF PurePascal}
    {$ASMMODE Intel}
  {$ENDIF}
{$ELSE}
  {$IF CompilerVersion >= 17} // Delphi 2005+
    {$DEFINE CanInline}
  {$ELSE}
    {$UNDEF CanInline}
  {$IFEND}
{$ENDIF}
{$H+}

//------------------------------------------------------------------------------
{
  SyncWord64

  When this symbol is defined, the type used for sync word (TFLSyncWord), and
  therefore the sync word itself, is 64 bits wide, otherwise it is 32 bits wide.
  This is true on all systems, irrespective of whether they are 32bit or 64bit.

    NOTE - 64bit sync words require that library InterlockedOps provides
           support for 64bit arguments, see there for details.

  By default NOT defined.

  To enable/define this symbol in a project without changing this library,
  define project-wide symbol FastLocks_SyncWord64_On.
}
{$UNDEF SyncWord64}
{$IFDEF FastLocks_SyncWord64_On}
  {$DEFINE SyncWord64}
{$ENDIF}

interface

uses
  SysUtils,
  AuxTypes, AuxClasses{$IFDEF UseAuxExceptions}, AuxExceptions{$ENDIF};

{===============================================================================
    Library-specific exceptions
===============================================================================}
type
  EFLException = class({$IFDEF UseAuxExceptions}EAEGeneralException{$ELSE}Exception{$ENDIF});

  EFLClockError   = class(EFLException);
  EFLInvalidState = class(EFLException);
  EFLInvalidValue = class(EFLException);

{===============================================================================
--------------------------------------------------------------------------------
                                   Fast locks
--------------------------------------------------------------------------------
===============================================================================}
type
  TFLSyncWord = {$IFDEF SyncWord64}Int64{$ELSE}Int32{$ENDIF};
  PFLSyncWord = ^TFLSyncWord;
  
//------------------------------------------------------------------------------
{
  TFLWaitDelayMethod

  During waiting (functions and methods ...WaitTo...), the call blocks by
  executing a cycle where each iteration of this cycle attempts to acquire
  the lock - if this fails then a check for timeout is made, followed by a
  delaying part that prevents rapid repeated calls to acquire and timers.

  This enumeration is here to select a method used for this delaying.

    dmNone          - No delaying action is performed. Use this only in
                      situations where you know the synchronizer will not
                      stay locked for long.

    dmSpin          - A spinning will be performed. See description of types
                      TFLSpinParams and TFLWaitParams for more details about
                      spinning. This is the default operation.

    dmYield         - An attempt to yield execution of current thread is made.
                      If system has another thread that can be run, the current
                      thread is suspended, rescheduled and next thread is run.
                      If there is no thread awaiting execution, then the
                      current thread is not suspended and continues execution
                      and pretty much performs spinning.

                        WARNING - use with caution, as it can cause spinning
                                  with rapid calls to thread yielding on
                                  uncontested CPU.

    dmSleep         - The current thread suspends its own execution (using a
                      call to function Sleep) for number of milliseconds given
                      in field SleepTime of WaitParams.
                      Note that this time is usually longer because of
                      granularity of scheduling timers, resulting in slightly
                      longer wait time than is requested.

    dmSleepEx       - Behaves the same as dmSleep, but the thread can be
                      awakened by APC or I/O completion calls.

                        NOTE - useful only on Windows, everywhere else it
                               behaves the same as dmSleep.

    dmYieldSleep    - Combination od dmYield and dmSleep - when the thread
                      is not yielded (eg. because no other thread is awaiting
                      execution), a sleep is performed.

                        NOTE - useful only on Windows, everywhere else it
                               behaves the same as dmSleep.                      

    dmYieldSleepEx  - Works the same as dmYieldSleep, but the sleep allows
                      for thread wakeup by APC or I/O completion calls.

                        NOTE - useful only on Windows, everywhere else it
                               behaves the same as dmYieldSleep.
}
  TFLWaitDelayMethod = (dmNone,dmSpin,dmYield,dmSleep,dmSleepEx,dmYieldSleep,
                        dmYieldSleepEx);

{
  TFLSpinParams

  Structure used to pass parameters into spinning.

  In spinning, a cycle is performed. In each iteration of this cycle, an
  attempt to acquire the object is tried. If it is not successful, a delaying
  action is executed and then the cycle repeats.

  Maximum number of these iterations is limited by value of field SpinCount,
  unless it is set to INFINITE, in which case the cycle never terminates.

  The delaying action is a small piece of code with no external effects that
  is executed multiple times to make this delaying longer. Number of executions
  is controlled by field DelayCount.
}
  TFLSpinParams = record
    SpinCount:  UInt32;
    DelayCount: UInt32;
  end;

{
  TFLWaitParams

  Used to pass parameters for waiting.

  Waiting is very similar to spinning in that it runs in a cycle, but the
  number of iteration is not given explicitly, it depends on a timeout interval.

  In each iteration, and attempt to acquire is made, and when not successful
  a delaying action is performed. Nature of this action can be selected by
  field DelayMethod.

  One possible delaying action is spinning. In this case, a spin as described
  in description of type TFLSpinParams is performed and values for SpinCount
  and DelayCount are taken from variant fields of the same name here.

    NOTE - SpinCount here can be se to INFINITE, but it will not be unbound.
           Instead, a numerical value of this constant is used as the count.

  If any action that is performing sleep is selected, you can define number of
  milliseconds to sleep in field SleepTime.
}
  TFLWaitParams = record
    Timeout:          UInt32;
    case DelayMethod: TFLWaitDelayMethod of
      dmSpin: (
        SpinCount:      UInt32;
        DelayCount:     UInt32);
      dmSleep,
      dmSleepEx,
      dmYieldSleep,
      dmYieldSleepEx: (
        SleepTime:      UInt32);
  end;

const
  // infinite spin count or timeout interval
  INFINITE = UInt32(-1);

  DefaultSpinParams: TFLSpinParams = (
    SpinCount:  INFINITE;
    DelayCount: 1000);

  DefaultWaitParams: TFLWaitParams = (
    Timeout:      INFINITE;
    DelayMethod:  dmSpin;
    SpinCount:    1000;
    DelayCount:   5000);

//------------------------------------------------------------------------------
{
  TFLWaitResult

  Used to indicate result of blocking (spinning or waiting) functions.

    wrAcquired - The synchronizer object was signaled (unlocked). Current state
                 of the synchronizer object depends on its type and settings.

    wrTimeout  - Spinning or waiting timed-out, ie. the synchronizer did
                 not became signaled in a given timeout period or number
                 of spinning cycles (was non-signaled the whole time).

    wrTryAgain - Returned when the synchronizer is in a state that temporarily
                 precludes spinning or waiting (for example when event is
                 pulsing or there is too many threads already waiting).
                 You should try to aquire the synchronizer again later.

    wrError    - Unknown or external error has ocurred, the object might be in
                 an inconsistent state and should not be used anymore.
                 In current implementation, this is never returned as all
                 erroneous states lead to an exception being raised.
}
type
  TFLWaitResult = (wrAcquired,wrTimeout,wrTryAgain,wrError);

{
  WaitResultToStr

  Resturns textual representation of provided wait result.

  It is inteded mainly for debugging purposes.
}
Function WaitResultToStr(WaitResult: TFLWaitResult): String;

{===============================================================================
--------------------------------------------------------------------------------
                                    TFastLock
--------------------------------------------------------------------------------
===============================================================================}
type
  TFastLockMode = (flmOwner,flmSlave,flmWrapper);

{===============================================================================
    TFastLock - class declaration
===============================================================================}
{
  TFastLock

  TFastLock is a common ancestor for all classes implemented by this library
  that are encapsulating procedural interfaces of provided synchronization
  primitives into object forms.

  These objects can be created in three principial modes - Owner, Slave and
  Wrapper.

    Owner object uses its own internal field to provide sync word and therefore
    does not need it to be allocated or declared externally. You simply create
    it using no-parameter constructor and that is all

      NOTE - some synchronizers may provide constructors accepting parameters
             that specify properties of that primitive. Simply put, owner mode
             object is created when you use constructor that does NOT expect
             sync word variable or other (master) instance of TFastLock or its
             descendant.  

    Slave object does not have its own sync word, instead it uses sync word
    provided by master object passed to constructor. This mechanism is here to
    allow for effective sharing of one lock between multiple instances of fast
    lock objects - you create owner object in one (possibly main) thread and
    to synchronize in other threads you just give them slave objects created
    using the owner object as their master. Also note that the master object
    does not need to be created in owner mode - it can be another slave or
    even wrapper instance (yep, you can create a tree of slaves, but better
    avoid that).

      WARNING - to ensure that master objects are not destroyed while being
                used by their slaves, all objects are reference counted.
                Everytime any instance is used as master, its reference count
                is incremented and, when the slave object is destroyed it gets
                decremented.
                If you call destructor of object that is currently being used
                as master, it will not be freed within that call, only its
                reference count will be decremented. When last slave using it
                is being destroyed, this master will be destroyed too.

    Wrapper object also does not have its own sync word, but instead of using
    master object it accepts reference to any sync word wariable and uses that
    one. Lifetime of this variable must be managed by external means. You can
    use single variable in any number of wrapper instances, they will all be
    mutually synchronized.
    The variable can be initialized and finalized externally, but if you set
    constructor parameter InitSyncWord to True, the object will automatically
    initialize and also finalize it - be carefull and make sure you do not
    re-initialize already used sync word.
}
type
  TFastLock = class(TCustomObject)
  protected
    fMode:            TFastLockMode;
    fRefCount:        Integer;
    fMaster:          TFastLock;
    fSyncWord:        TFLSyncWord;
    fSyncWordPtr:     PFLSyncWord;
    fInitializer:     Boolean;
    fClockFreq:       Int64;
    fSpinParams:      TFLSpinParams;
    fWaitParams:      TFLWaitParams;
    fCanFreeInstance: Boolean;
    Function GetReferenceCount: Integer; virtual;
    Function AcquireReference: Integer; virtual;
    Function ReleaseReference: Integer; virtual;
    procedure SyncWordInit(const InitArgs: array of const); virtual; abstract;
    procedure SyncWordFinal; virtual; abstract;
    procedure Initialize(SyncWordPtr: PFLSyncWord; InitSyncWord: Boolean; const InitArgs: array of const); virtual;
    procedure Finalize; virtual;
    class Function ArgTypePresent(const InitArgs: array of const; Index: Integer; VType: Byte): Boolean; virtual;
  public
    procedure FreeInstance; override;
    constructor CreateBase; // static constructor
    constructor Create; overload; virtual;
    constructor Create(Master: TFastLock); overload; virtual;    
    constructor Create(var SyncWord: TFLSyncWord; InitSyncWord: Boolean = True); overload; virtual;
    destructor Destroy; override;
    property Mode: TFastLockMode read fMode;    
    property ReferenceCount: Integer read GetReferenceCount;
    property Initializer: Boolean read fInitializer;
    property ClockFrequency: Int64 read fClockFreq;
    property SpinParams: TFLSpinParams read fSpinParams write fSpinParams;
    property WaitParams: TFLWaitParams read fWaitParams write fWaitParams;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                                   Fast event                                   
--------------------------------------------------------------------------------
===============================================================================}
{
  Synchronizer that roughly corresponds to events provided by Windows OS (see
  their documentation for details on how and where to use events).

  It is an object whose state can be explicitly manipulated (set to signaled
  or reset to non-signaled) from any thread and which can be used eg. to inform
  other threads that some event has occurred/passed.

  Note that current implementation actually presents three possible states
  for the event - signaled, non-signaled and pulsing (non-signaled state that
  allows currently blocked threads to pass).

  For more information, refer to description of individual functions.
}
{===============================================================================
    Fast event - procedural interface declaration
===============================================================================}
{
  FastEventInit

  Initializes the event synchronizer and sets its state according to passed
  settings.

  If InitialState is set to True, then the state of initialized event will
  be signaled, otherwise (False) it will be non-signaled.

  For details about manual-reset versus auto-reset, please refer to description
  of FastEvent*Pass functions.

  If already initialized word is passed here, it will be re-initialized and
  its current state lost.
}
procedure FastEventInit(out SyncWord: TFLSyncWord; ManualReset: Boolean = False; InitialState: Boolean = False);

{
  FastEventFinal

  Finalizes the event object and sets sync word to a value that precludes its
  further use (an invalid value). Can accept uninitialized sync words.

  If any thread is spinning or waiting on this word, the spin or wait function
  will raise an EFLInvalidState exception next time it probes the event (next
  cycle).
}
procedure FastEventFinal(var SyncWord: TFLSyncWord);

{
  FastEventSet

  Sets the event to signaled state.

  If the event is currently pulsing, the pulsing is abandoned.

  Raises an EFLInvalidState exception if the sync word is not initialized or
  has invalid value in general.
}
procedure FastEventSet(var SyncWord: TFLSyncWord);

{
  FastEventReset

  Resets the event to non-signaled state.

  If the event is currently pulsing, the pulsing is abandoned.

  Raises an EFLInvalidState exception if the sync word is not initialized or
  has invalid value in general.
}
procedure FastEventReset(var SyncWord: TFLSyncWord);

{
  FastEventPulse

  If no thread is spinning or waiting on this event, then it is reset to a
  non-signaled state (equivalent to calling FastEventReset). If any thread
  is spinning or waiting, then the event is set to pulsing state.

    In pulsing state, threads that were already spinning or waiting (and only
    those threads) are allowed to pass the event. If it is an auto-reset event,
    then first thread that passes sets it to a non-signaled state, disabling
    pulsing. For manual-reset event, only when last of the spinning or waiting
    threads passes the event is reset to non-signaled state.
    
    During pulsing, no new thread can pass it or begin spinning or waiting
    (wrTryLater will be returned).

  Raises an EFLInvalidState exception if the sync word is not initialized or
  has invalid value in general.
}
procedure FastEventPulse(var SyncWord: TFLSyncWord);

{
  FastEventPass

  Probes the provided event whether it passed or not.

    For auto-reset events, the call passes (true is returned) when the event
    is in a signaled state (note that pulsing event is NOT signaled), and no
    other thread is spinning or waiting on it - this is to ensure that blocked
    threads are served as soon as possible and are not starved by asynchronous
    passes. Also, if passed, then the event is reset to non-signaled state,
    otherwise its state is left unchanged.

    Manual-reset event can be passed whenever it is in a signaled state.

  Raises an EFLInvalidState exception if the sync word is not initialized or
  has invalid value in general.
}
Function FastEventPass(var SyncWord: TFLSyncWord): Boolean;

{
  FastEventSpinToPass

  Tries to pass the event and, if not successful, enters spinning. The spinning
  ends when the event can be passed (becomes signaled or pulsing) or prescribed
  number of spinning cycles (SpinCount) is performed - note that SpinCount can
  be set to INFINITE, in which case spinning will never terminate by running
  out of cycles.

  If the event becomes signaled or pulsing during waiting, or if it is passed
  without even starting spinning, then wrAcquired is returned.

  If the function exits because number of prescribed cycles elapses, then
  wrTimeout is returned.

  It can also return wrTryAgain - this happens either because the event was in
  pulsing state, which precludes new threads to start spinning or waiting on
  it, or because internal counter that tracks number of currently spinning or
  waiting threads reached its maximum (1023 in current implementation). In any
  case, you should try spinning again after some time.

  Overload accepting SpinParams instead of just SpinCount is here to allow for
  finer control over the spinning (more parameters can be varied).

  Raises an EFLInvalidState exception if the sync word is not initialized or
  has invalid value in general.
}
Function FastEventSpinToPass(var SyncWord: TFLSyncWord; SpinParams: TFLSpinParams): TFLWaitResult; overload;
Function FastEventSpinToPass(var SyncWord: TFLSyncWord; SpinCount: UInt32): TFLWaitResult; overload;

{
  FastEventWaitToPass

  Works exactly the same as FastEventSpinToPass (see there for details), but,
  instead of spinning, it will enter waiting. Time that can be spent waiting
  is not given by number of cycles, but by number of milliseconds (Timeout).

  This type of blocking is here to allow for better control over the time spent,
  because how much actual time is spent in spinning greatly depends on system
  performance (eg. CPU clock, instruction troughput and latency, optimizations
  of used instructions, exact behaviour of PAUSE instruction, you name it...).

  See description of types TFLWaitDelayMethod and TFLWaitParams for more
  information regarding waiting.

    NOTE - waiting is, similarly to spinning, active, meaning the thread will
           still run and load the processor and not enter any kind of suspended
           state (unless in some specific delay methods, see description of
           TFLWaitDelayMethod for details).
}
Function FastEventWaitToPass(var SyncWord: TFLSyncWord; WaitParams: TFLWaitParams): TFLWaitResult; overload;
Function FastEventWaitToPass(var SyncWord: TFLSyncWord; Timeout: UInt32): TFLWaitResult; overload;

{===============================================================================
--------------------------------------------------------------------------------
                                   TFastEvent
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastEvent - class declaration
===============================================================================}
type
  TFastEvent = class(TFastLock)
  protected
    procedure SyncWordInit(const InitArgs: array of const); override;
    procedure SyncWordFinal; override;
  public
    constructor Create(ManualReset: Boolean; InitialState: Boolean); overload; virtual;
    // following overload WILL initialize the provided sync word
    constructor Create(var SyncWord: TFLSyncWord; ManualReset: Boolean; InitialState: Boolean); overload; virtual;
  {
    Unfortunatelly, "set" is a reserved word in pascal, therefore it cannot be
    used as method name. I chose to rename it to EventSet, and to keep naming
    scheme, all methods in TFastLock descendants will be named similarly.
  }
    procedure EventSet; virtual;
    procedure EventReset; virtual;
    procedure EventPulse; virtual;
    Function EventPass: Boolean; virtual;
    Function EventSpinToPass(SpinCount: UInt32): TFLWaitResult; overload; virtual;
    Function EventSpinToPass: TFLWaitResult; overload; virtual;
    Function EventWaitToPass(Timeout: UInt32): TFLWaitResult; overload; virtual;
    Function EventWaitToPass: TFLWaitResult; overload; virtual;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                                 Fast semaphore
--------------------------------------------------------------------------------
===============================================================================}
{$message 'todo: descriptions'}
procedure FastSemaphoreInit(out SyncWord: TFLSyncWord; InitialCount: TFLSyncWord = 0);
procedure FastSemaphoreFinal(var SyncWord: TFLSyncWord);

Function FastSemaphoreCount(var SyncWord: TFLSyncWord): TFLSyncWord;

Function FastSemaphoreAcquire(var SyncWord: TFLSyncWord; AcquireCount: TFLSyncWord = 1): Boolean;
Function FastSemaphoreRelease(var SyncWord: TFLSyncWord; ReleaseCount: TFLSyncWord = 1): Boolean;

Function FastSemaphoreSpinToAcquire(var SyncWord: TFLSyncWord; SpinParams: TFLSpinParams; AcquireCount: TFLSyncWord = 1): TFLWaitResult; overload;
Function FastSemaphoreSpinToAcquire(var SyncWord: TFLSyncWord; SpinCount: UInt32; AcquireCount: TFLSyncWord = 1): TFLWaitResult; overload;

Function FastSemaphoreWaitToAcquire(var SyncWord: TFLSyncWord; WaitParams: TFLWaitParams; AcquireCount: TFLSyncWord = 1): TFLWaitResult; overload;
Function FastSemaphoreWaitToAcquire(var SyncWord: TFLSyncWord; Timeout: UInt32; AcquireCount: TFLSyncWord = 1): TFLWaitResult; overload;

{===============================================================================
--------------------------------------------------------------------------------
                                 TFastSemaphore
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastSemaphore - class declaration
===============================================================================}
type
  TFastSemaphore = class(TFastLock)
  protected
    procedure SyncWordInit(const InitArgs: array of const); override;
    procedure SyncWordFinal; override;
  public
    constructor Create(InitialCount: TFLSyncWord); overload; virtual;
    // following overload will initialize the provided sync word
    constructor Create(var SyncWord: TFLSyncWord; InitialCount: TFLSyncWord); overload; virtual;
    Function SemaphoreCount: TFLSyncWord; virtual;
    Function SemaphoreAcquire(AcquireCount: TFLSyncWord = 1): Boolean; virtual;
    Function SemaphoreRelease(ReleaseCount: TFLSyncWord = 1): Boolean; virtual;
    Function SemaphoreSpinToAcquireBy(SpinCount: UInt32; AcquireCount: TFLSyncWord): TFLWaitResult; overload; virtual;
    Function SemaphoreSpinToAcquireBy(AcquireCount: TFLSyncWord): TFLWaitResult; overload; virtual;
    Function SemaphoreSpinToAcquire(SpinCount: UInt32): TFLWaitResult; overload; virtual; // acquire count is 1
    Function SemaphoreSpinToAcquire: TFLWaitResult; overload; virtual;
    Function SemaphoreWaitToAcquireBy(Timeout: UInt32; AcquireCount: TFLSyncWord): TFLWaitResult; overload; virtual;
    Function SemaphoreWaitToAcquireBy(AcquireCount: TFLSyncWord): TFLWaitResult; overload; virtual;
    Function SemaphoreWaitToAcquire(Timeout: UInt32): TFLWaitResult; overload; virtual;
    Function SemaphoreWaitToAcquire: TFLWaitResult; overload; virtual;
  end;
(*

{===============================================================================
--------------------------------------------------------------------------------
                              Fast critical section
--------------------------------------------------------------------------------
===============================================================================}
{
  Classical critical section - only one thread can acquire the object, and
  while it is locked all subsequent attemps to acquire it will fail.

  When spinning or waiting, there is no guarantee that the first thread that
  entered this cycle will also acquire the object. The order in which waiting
  threads enter the section is undefined and more or less random.
  Note that while any thread is in spinning or waiting cycle, the section can
  only be entered by spinning or waiting threads, not by a call to enter. This
  assures that blocked threads are served before threads which are using the
  object asynchronously (as it should be).
}
{===============================================================================
    Fast critical section - procedural interface declaration
===============================================================================}

procedure FastCriticalSectionInit(out SyncWord: TFLSyncWord);
procedure FastCriticalSectionFinal(var SyncWord: TFLSyncWord);

Function FastCriticalSectionEnter(var SyncWord: TFLSyncWord): Boolean;
procedure FastCriticalSectionLeave(var SyncWord: TFLSyncWord);
 
{
  A small note on spinning and waiting implementation...

  Spinning:

    In spinning, a cycle is performed. In each iteration of this cycle, an
    attempt to acquire the object is tried. If it is not successful, a delaying
    action is executed and then the cycle repeats.

    Maximum number of iterations is limited by a parameter SpinCount, unless it
    is set to INFINITE, in which case the cycle never terminates.

    The delaying action is a small piece of code with no external effects that
    is executed multiple times to make this delaying longer. Number of
    executions is given in parameter SpinDelayCount.

  Waiting:

    Waiting is very similar to spinning in that it runs in a cycle, but the
    number of iteration is not given explicitly, it depends on a timeout
    interval.

    In each iteration, and attempt to acquire is made, and when not successful
    a delaying action is performed. Nature of this action can be selected by
    a parameter WaitDelayMethod.

    One possible delaying action is spinning. In this case, a spin as described
    above is performed, with a spin count set to WaitSpinCount.
}

Function FastCriticalSectionSpinToEnter(var SyncWord: TFLSyncWord; SpinCount: UInt32; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
Function FastCriticalSectionWaitToEnter(var SyncWord: TFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = dmSpin;
  WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;

{===============================================================================
--------------------------------------------------------------------------------
                              TFastCriticalSection
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastCriticalSection - class declaration
===============================================================================}
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
                                    Fast MREW
--------------------------------------------------------------------------------
===============================================================================}
{
  This object can be locked in two principal ways - for reading (read lock) or
  for writing (write lock).
  Unlike for write lock, where only one can be present at a time, read locks
  have counter that allows multiple readers to acquire a read lock.

  Acquiring the object for write can only be successful if no reader have a
  read lock.

  No reader can acquire read lock while the object is locked for writing, or
  any thread is spinning or waiting for a write lock (this prevents starving
  of writers by readers - waiting writer excludes any reader to acquire read
  lock).

  The read lock cannot be promoted to write lock - an attempt to acquire write
  lock while there is any read lock will always fail.

  While waiting for a read lock, it is entirely possible the object will be
  locked by other thread for writing. But, as mentioned before, during wait for
  write lock, no reader can acquire read lock, even through waiting to read.

  The order in which waiting or spinning threads acquire their locks is
  undefined.

    WARNING - number of readers is limited, 2047 for 32bit sync words (default),
              2147483647 for 64bit sync words.
}
{===============================================================================
    Fast MREW - procedural interface declaration
===============================================================================}

procedure FastMREWInit(out SyncWord: TFLSyncWord);
procedure FastMREWFinal(var SyncWord: TFLSyncWord);

Function FastMREWBeginRead(var SyncWord: TFLSyncWord): Boolean;
procedure FastMREWEndRead(var SyncWord: TFLSyncWord);

Function FastMREWSpinToRead(var SyncWord: TFLSyncWord; SpinCount: UInt32; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
Function FastMREWWaitToRead(var SyncWord: TFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = dmSpin;
  WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;

Function FastMREWBeginWrite(var SyncWord: TFLSyncWord): Boolean;
procedure FastMREWEndWrite(var SyncWord: TFLSyncWord);

Function FastMREWSpinToWrite(var SyncWord: TFLSyncWord; SpinCount: UInt32; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
Function FastMREWWaitToWrite(var SyncWord: TFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = dmSpin;
  WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;

{===============================================================================
--------------------------------------------------------------------------------
                                    TFastMREW
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastMREW - class declaration
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
*)
implementation

uses
{$IFDEF Windows} Windows,{$ELSE} baseunix, linux,{$ENDIF}
  InterlockedOps;

{.$IFNDEF Windows}
  {.$LINKLIB C}
{.$ENDIF}

{$IFDEF FPC_DisableWarns}
  {$DEFINE FPCDWM}
  {$DEFINE W5024:={$WARN 5024 OFF}} // Parameter "$1" not used
{$ENDIF}

Function ConsumeArg(Arg: TFLSyncWord): TFLSyncWord;
begin
Result := Arg + 0;
end;

{===============================================================================
--------------------------------------------------------------------------------
                                   Fast locks
--------------------------------------------------------------------------------
===============================================================================}
const
  FL_INITVAL = TFLSyncWord(0);

  FL_WORDHIBIT = {$IFDEF SyncWord64}63{$ELSE}31{$ENDIF};

  FL_COMMON_MASK_VALID = TFLSyncWord(1) shl FL_WORDHIBIT;

//------------------------------------------------------------------------------

Function IsValid(SyncWord: TFLSyncWord): Boolean;{$IFDEF CanInline} inline;{$ENDIF}
begin
Result := (SyncWord and FL_COMMON_MASK_VALID) <> 0;
end;

//------------------------------------------------------------------------------

Function WaitResultToStr(WaitResult: TFLWaitResult): String;
const
  WR_STRS: array[TFLWaitResult] of String = ('Acquired','Timeout','TryAgain','Error');
begin
If (WaitResult >= Low(TFLWaitResult)) and (WaitResult <= High(TFLWaitResult)) then
  Result := WR_STRS[WaitResult]
else
  Result := '<invalid>';
end;

{===============================================================================
    Fast locks - spinning and waiting infrastructure
===============================================================================}
type
  TFLQueueResult = (qrAcquired,qrQueued,qrFailed);

type
  TFLWaitParamsInternal = record
    PublicParams:     record case Boolean of
      False: (SpinParams: TFLSpinParams);
      True:  (WaitParams: TFLWaitParams;
              ClockStart: Int64;
              ClockFreq:  Int64);
    end;
    SyncWordPtr:      PFLSyncWord;
    EnqueueFce:       Function(var SyncWord: TFLSyncWord; CallData: TFLSyncWord): TFLQueueResult;
    QueuedAcquireFce: Function(var SyncWord: TFLSyncWord; CallData: TFLSyncWord): Boolean;
    DequeueFce:       procedure(var SyncWord: TFLSyncWord; CallData: TFLSyncWord);
    CallData:         TFLSyncWord;  // passed as CallData param to above funtions
  end;

//==============================================================================
{
  Just do some contained, relatively long, but othervise pointless operation
  that has no side effects.
}
Function SpinDelayAction(Divisor: UInt32): UInt32;{$IFNDEF PurePascal} register; assembler;
asm
{
  Assembly implementation is here only to utilize PAUSE instruction. It is
  otherwise equivalent to pascal code.
}
{$IFDEF x64}
  {$IFDEF Windows}
    // Divisor is already in ECX
  {$ELSE}
    MOV     ECX, EDI
  {$ENDIF}
{$ELSE}
    MOV     ECX, EAX
{$ENDIF}
    MOV     EAX, 3895731025
    XOR     EDX, EDX

    DIV     ECX

    PAUSE   // instruction specifically intended for spin loops
end;
{$ELSE}
begin
Result := UInt32(3895731025) div Divisor;
end;
{$ENDIF}

//------------------------------------------------------------------------------

procedure SpinDelay(Count: UInt32);
var
  i:  UInt32;
begin
{
  Repeatedly call delaying action - iterator must not start at 0 because it is
  used as divisor in SpinDelayAction.
}
For i := 1 to Count do
  SpinDelayAction(i);
end;

//------------------------------------------------------------------------------

Function GetClockFrequency(out Freq: Int64): Boolean;
{$IFNDEF Windows}
var
  Time: TTimeSpec;
{$ENDIF}
begin
{$IFDEF Windows}
Freq := 0;
Result := QueryPerformanceFrequency(Freq);
{$ELSE}
Freq := 1000000000{ns^-1, 1GHz};
Result := clock_getres(CLOCK_MONOTONIC_RAW,@Time) = 0;
{$ENDIF}
If Freq and Int64($1000000000000000) <> 0 then
  raise EFLClockError.CreateFmt('GetClockFrequency: Unsupported frequency value (0x%.16x)',[Freq]);
end;

//------------------------------------------------------------------------------

Function GetClockValue(out Count: Int64): Boolean;
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
Count := Int64(Time.tv_sec) * 1000000000 + Int64(Time.tv_nsec);
{$ENDIF}
// mask out bit 63 to prevent problems with signed 64bit integer
Count := Count and Int64($7FFFFFFFFFFFFFFF);
end;

//------------------------------------------------------------------------------

Function GetElapsedMillis(FromClock,Frequency: Int64): UInt32;
var
  CurrentClock: Int64;
begin
If GetClockValue(CurrentClock) then
  begin
    If CurrentClock < FromClock then
      // clock seems to have overflown
      Result := UInt32(((High(Int64) - FromClock + CurrentClock + 1{overflow tick}) * 1000) div Frequency)
    else
      Result := UInt32(((CurrentClock - FromClock) * 1000) div Frequency);
  end
else raise EFLClockError.Create('GetElapsedMillis: Unable to obtain clock value');
end;

//------------------------------------------------------------------------------

{$IFDEF Windows}
Function SwitchToThread: BOOL; stdcall; external kernel32;
{$ELSE}
{
  FPC declares sched_yield as procedure without result, which afaik does not
  correspond to linux man.
}
Function sched_yield: cint; cdecl; external;
{$ENDIF}

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function YieldThread: Boolean;{$IFDEF CanInline} inline;{$ENDIF}
begin
{$IFDEF Windows}
Result := SwitchToThread;
{$ELSE}
Result := sched_yield = 0;
{$ENDIF}
end;

{===============================================================================
    Fast locks - spinning and waiting implementation
===============================================================================}

Function ExecuteSpinning(WaitParamsInternal: TFLWaitParamsInternal): TFLWaitResult;

  Function SpinInternal: TFLWaitResult;
  begin
    // SpinInternal can only return wrAcquired or wrTimeout, nothing else
    while not WaitParamsInternal.QueuedAcquireFce(WaitParamsInternal.SyncWordPtr^,WaitParamsInternal.CallData) do
      begin
      {
        Could not acquire the object - do spinning, check count and exit or
        repeat, depending on counters.
      }
        SpinDelay(WaitParamsInternal.PublicParams.SpinParams.DelayCount);
        If WaitParamsInternal.PublicParams.SpinParams.SpinCount <> INFINITE then
          begin
            Dec(WaitParamsInternal.PublicParams.SpinParams.SpinCount);
            If WaitParamsInternal.PublicParams.SpinParams.SpinCount <= 0 then
              begin
                // we must explicitly dequeue
                WaitParamsInternal.DequeueFce(WaitParamsInternal.SyncWordPtr^,WaitParamsInternal.CallData);
                Result := wrTimeout;
                Exit;
              end;
          end;
      end;
    // if here, acquire was successful
    Result := wrAcquired;
  end;

begin
case WaitParamsInternal.EnqueueFce(WaitParamsInternal.SyncWordPtr^,WaitParamsInternal.CallData) of
  qrAcquired: Result := wrAcquired;
  qrQueued:   Result := SpinInternal;
else
 {qrFailed}   Result := wrTryAgain;
end;
end;

//------------------------------------------------------------------------------

Function ExecuteWaiting(WaitParamsInternal: TFLWaitParamsInternal): TFLWaitResult;

  Function WaitInternal: TFLWaitResult;
  begin
    while not WaitParamsInternal.QueuedAcquireFce(WaitParamsInternal.SyncWordPtr^,WaitParamsInternal.CallData) do
      with WaitParamsInternal.PublicParams do
        If (WaitParams.Timeout = INFINITE) or (GetElapsedMillis(ClockStart,ClockFreq) < WaitParams.Timeout) then
          // infinite wait or timeout has not elapsed yet
          case WaitParams.DelayMethod of
            dmNone:;        // do nothing
            dmYield:        YieldThread;
          {$IFDEF Windows}
            dmSleep:        Sleep(WaitParams.SleepTime);
            dmSleepEx:      SleepEx(WaitParams.SleepTime,True);
            dmYieldSleep:   If not YieldThread then
                              Sleep(WaitParams.SleepTime);
            dmYieldSleepEx: If not YieldThread then
                              SleepEx(WaitParams.SleepTime,True);
          {$ELSE}
            dmSleep,
            dmSleepEx,
            dmYieldSleep,
            dmYieldSleepEx: Sleep(WaitParams.SleepTime);
          {$ENDIF}
          else
           {dmSpin}
          {
            Perform spinning similarly to ExecuteSpinning but without queueing
            as we are already queued for waiting. Ignore INFINITE spin count
            here.
          }
            while WaitParams.SpinCount > 0 do
              begin
                SpinDelay(WaitParams.SpinCount);
                Dec(WaitParams.SpinCount);
              end;
          end
        else
          begin
            // not in infinite wait and timeout has elapsed
            WaitParamsInternal.DequeueFce(WaitParamsInternal.SyncWordPtr^,WaitParamsInternal.CallData);
            Result := wrTimeout;
            Exit;
          end;
    Result := wrAcquired;
  end;

begin
case WaitParamsInternal.EnqueueFce(WaitParamsInternal.SyncWordPtr^,WaitParamsInternal.CallData) of
  qrAcquired: Result := wrAcquired;
  qrQueued:   Result := WaitInternal;
else
 {qrFailed}   Result := wrTryAgain;
end;
end;


{===============================================================================
--------------------------------------------------------------------------------
                                    TFastLock
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastLock - class declaration
===============================================================================}
{-------------------------------------------------------------------------------
    TFastLock - protected methods implementation
-------------------------------------------------------------------------------}

Function TFastLock.GetReferenceCount: Integer;
begin
Result := InterlockedLoad(fRefCount);
end;

//------------------------------------------------------------------------------

Function TFastLock.AcquireReference: Integer;
begin
Result := InterlockedIncrement(fRefCount);
end;

//------------------------------------------------------------------------------

Function TFastLock.ReleaseReference: Integer;
begin
Result := InterlockedDecrement(fRefCount);
end;

//------------------------------------------------------------------------------

procedure TFastLock.Initialize(SyncWordPtr: PFLSyncWord; InitSyncWord: Boolean; const InitArgs: array of const);
begin
// do not touch reference counter
InterlockedStore(fSyncWord,FL_INITVAL);
fSyncWordPtr := SyncWordPtr;
fInitializer := InitSyncWord;
If fInitializer then
  SyncWordInit(InitArgs);
If not GetClockFrequency(fClockFreq) then
  raise EFLClockError.Create('TFastLock.Initialize: Cannot obtain counter frequency.');
fSpinParams := DefaultSpinParams;
fWaitParams := DefaultWaitParams;
end;

//------------------------------------------------------------------------------

procedure TFastLock.Finalize;
begin
If fInitializer then
  SyncWordFinal;
end;

//------------------------------------------------------------------------------

class Function TFastLock.ArgTypePresent(const InitArgs: array of const; Index: Integer; VType: Byte): Boolean;
begin
Result := False;
If Length(InitArgs) > Index then
  Result := VType = InitArgs[Index].VType;
end;

{-------------------------------------------------------------------------------
    TFastLock - public methods implementation
-------------------------------------------------------------------------------}

procedure TFastLock.FreeInstance;
begin
If fCanFreeInstance then
  inherited FreeInstance;
end;

//------------------------------------------------------------------------------

constructor TFastLock.CreateBase;
begin
inherited Create;
end;

//------------------------------------------------------------------------------

constructor TFastLock.Create;
begin
CreateBase;
fMode := flmOwner;
Initialize(@fSyncWord,True,[]);
AcquireReference;
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TFastLock.Create(Master: TFastLock);
begin
CreateBase;
fMode := flmSlave;
If not (Master is Self.ClassType) then
  raise EFLInvalidValue.CreateFmt('TFastLock.Create: Master object is of incompatible class (%s).',[Master.ClassName]);
fMaster := Master;
If fMaster.AcquireReference <= 1 then
  raise EFLInvalidState.Create('TFastLock.Create: Master object is being destroyed.');
Initialize(fMaster.fSyncWordPtr,False,[]);  
AcquireReference;
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TFastLock.Create(var SyncWord: TFLSyncWord; InitSyncWord: Boolean = True);
begin
CreateBase;
fMode := flmWrapper;
Initialize(@SyncWord,InitSyncWord,[]);
AcquireReference;
end;

//------------------------------------------------------------------------------

destructor TFastLock.Destroy;
begin
{
  FreeInstance is called at the end of this function, but we need to suppress
  it if we are not actually freeing - fCanFreeInstance is used for that and
  method FreeInstance is overriden to check its value.
}
fCanFreeInstance := ReleaseReference <= 0;
If fCanFreeInstance then
  begin
    Finalize;
    If (fMode = flmSlave) and Assigned(fMaster) then
      If fMaster.ReleaseReference <= 0 then
        FreeAndNil(fMaster);
    inherited Destroy;
  end;
end;


{===============================================================================
--------------------------------------------------------------------------------
                                   Fast event                                   
--------------------------------------------------------------------------------
===============================================================================}
{
      Hi  ... highest bit in the sync word (31 for 32bit words and 63 for
              64bit words)
      <x> ... immutable bits (set in initialization and then only read, usually
              used for lock settings)

  Following is a specification of bits and fields in sync word for fast events
  in current implementation (note that it can be changed without warning in
  future revisions, so do not depend on it):

           Hi      - (V) validity bit, must be 1
           Hi-1    - (L) lock bit (0 signaled, 1 non signaled)
           Hi-2    - (P) pulsing (0 not pulsing, 1 pulsing)
          <Hi-3>   - (M) manual reset (0 auto reset, 1 manual reset)
     10 .. Hi-4    -     unused
      0 .. 9       - (W) wait counter (max 1023 waiters)
}
const
  FL_EVENT_MASK_VALID       = FL_COMMON_MASK_VALID;
  FL_EVENT_MASK_LOCK        = TFLSyncWord(1) shl (FL_WORDHIBIT - 1);
  FL_EVENT_MASK_PULSING     = TFLSyncWord(1) shl (FL_WORDHIBIT - 2);
  FL_EVENT_MASK_MANUALRESET = TFLSyncWord(1) shl (FL_WORDHIBIT - 3);
  FL_EVENT_MASK_WAITCOUNTER = (TFLSyncWord(1) shl 10) - 1;

  FL_EVENT_IOPRES_INVALID = -1;
  FL_EVENT_IOPRES_SUCCESS = 0;
  FL_EVENT_IOPRES_LOCKED  = 1;
  FL_EVENT_IOPRES_PULSING = 2;
  FL_EVENT_IOPRES_WAITERS = 3;
  FL_EVENT_IOPRES_QUEUED  = 4;

{===============================================================================
    Fast event - internal functions implementation
===============================================================================}

Function FastEventResetIOP(var SyncWord: TFLSyncWord): TFLSyncWord; register;
begin
// L := 1,  P := 0
If (SyncWord and FL_EVENT_MASK_VALID) <> 0 then
  begin
    SyncWord := (SyncWord or FL_EVENT_MASK_LOCK) and not FL_EVENT_MASK_PULSING;
    Result := FL_EVENT_IOPRES_SUCCESS;
  end
else Result := FL_EVENT_IOPRES_INVALID;
end;

//------------------------------------------------------------------------------

Function FastEventPulseIOP(var SyncWord: TFLSyncWord): TFLSyncWord; register;
begin
// L := 1,  P := (W <> 0)
If (SyncWord and FL_EVENT_MASK_VALID) <> 0 then
  begin
    If (SyncWord and FL_EVENT_MASK_WAITCOUNTER) <> 0 then
      SyncWord := SyncWord or (FL_EVENT_MASK_LOCK or FL_EVENT_MASK_PULSING)
    else
      SyncWord := (SyncWord or FL_EVENT_MASK_LOCK) and not FL_EVENT_MASK_PULSING;
    Result := FL_EVENT_IOPRES_SUCCESS;
  end
else Result := FL_EVENT_IOPRES_INVALID;
end;

//------------------------------------------------------------------------------

Function FastEventPassIOP(var SyncWord: TFLSyncWord): TFLSyncWord; register;
begin
If (SyncWord and FL_EVENT_MASK_VALID) <> 0 then
  begin
    If (SyncWord and FL_EVENT_MASK_LOCK) = 0 then
      begin
        // event is signaled (unlocked)
        If (SyncWord and FL_EVENT_MASK_PULSING) = 0 then
          begin
            // so, are there any waiters?
            If (SyncWord and FL_EVENT_MASK_WAITCOUNTER) = 0 then
              begin
                // no waiters, manage auto-reset and report success
                If (SyncWord and FL_EVENT_MASK_MANUALRESET) = 0 then
                  SyncWord := SyncWord or FL_EVENT_MASK_LOCK;
                Result := FL_EVENT_IOPRES_SUCCESS;
              end
          {
            There are waiters. We can pass only if this is manual-reset event
            (waiters have precedence over us and we would block them in auto-
            reset event).
          }
            else If (SyncWord and FL_EVENT_MASK_MANUALRESET) <> 0 then
              Result := FL_EVENT_IOPRES_SUCCESS
            else
              Result := FL_EVENT_IOPRES_WAITERS;
          end
        // if L = 0, then P must also be 0
        else Result := FL_EVENT_IOPRES_INVALID;
      end
    // locked - we have failed in any case, but report if pulsing
    else If (SyncWord and FL_EVENT_MASK_PULSING) <> 0 then
      Result := FL_EVENT_IOPRES_PULSING
    else
      Result := FL_EVENT_IOPRES_LOCKED;
  end
else Result := FL_EVENT_IOPRES_INVALID;
end;

//------------------------------------------------------------------------------

Function FastEventEnqueueIOP(var SyncWord: TFLSyncWord): TFLSyncWord; register;
begin
If (SyncWord and FL_EVENT_MASK_VALID) <> 0 then
  begin
    If (SyncWord and FL_EVENT_MASK_LOCK) = 0 then
      begin
        // event is signaled, we can actually pass it
        If (SyncWord and FL_EVENT_MASK_PULSING) = 0 then
          begin
            // no need to check for waiters, we are waiter
            If (SyncWord and FL_EVENT_MASK_MANUALRESET) = 0 then
              SyncWord := SyncWord or FL_EVENT_MASK_LOCK;
            Result := FL_EVENT_IOPRES_SUCCESS;
          end
        else Result := FL_EVENT_IOPRES_INVALID;
      end
    else
      begin
        // event is non-signaled (locked), add us to the queue
        If (SyncWord and FL_EVENT_MASK_PULSING) = 0 then
          begin
            If (SyncWord and FL_EVENT_MASK_WAITCOUNTER) < FL_EVENT_MASK_WAITCOUNTER then
              begin
                Inc(SyncWord);
                Result := FL_EVENT_IOPRES_QUEUED;
              end
            else Result := FL_EVENT_IOPRES_WAITERS;
          end
        // cannot enqueue if the event is pulsing
        else Result := FL_EVENT_IOPRES_PULSING;
      end;
  end
else Result := FL_EVENT_IOPRES_INVALID;  
end;

//------------------------------------------------------------------------------

Function FastEventQueuedAcquireIOP(var SyncWord: TFLSyncWord): TFLSyncWord; register;
begin
// this can only be called after successfull queueing
If ((SyncWord and FL_EVENT_MASK_VALID) <> 0) and ((SyncWord and FL_EVENT_MASK_WAITCOUNTER) <> 0) then
  begin
    If (SyncWord and FL_EVENT_MASK_LOCK) = 0 then
      begin
        If (SyncWord and FL_EVENT_MASK_PULSING) = 0 then
          begin
            If (SyncWord and FL_EVENT_MASK_MANUALRESET) = 0 then
              SyncWord := SyncWord or FL_EVENT_MASK_LOCK;
            // dequeue  
            Dec(SyncWord);
            Result := FL_EVENT_IOPRES_SUCCESS;
          end
        else Result := FL_EVENT_IOPRES_INVALID;
      end
    else
      begin
        // non-signaled, as we are already queued, we can potentially pass on pulsing
        If (SyncWord and FL_EVENT_MASK_PULSING) <> 0 then
          begin
            // pulsing event, we are queued so it is in effect for us too, but first dequeue
            Dec(SyncWord);
            If (SyncWord and FL_EVENT_MASK_MANUALRESET) <> 0 then
              begin
                // manual-reset event, end pulsing only if no other thread is waiting
                If (SyncWord and FL_EVENT_MASK_WAITCOUNTER) = 0 then
                  SyncWord := (SyncWord or FL_EVENT_MASK_LOCK) and not FL_EVENT_MASK_PULSING;
              end
            // auto-reset event, end pulsing now and reset state
            else SyncWord := (SyncWord or FL_EVENT_MASK_LOCK) and not FL_EVENT_MASK_PULSING;
            Result := FL_EVENT_IOPRES_SUCCESS;
          end
        else Result := FL_EVENT_IOPRES_LOCKED;
      end;
  end
else Result := FL_EVENT_IOPRES_INVALID;
end;

//------------------------------------------------------------------------------

Function FastEventDequeueIOP(var SyncWord: TFLSyncWord): TFLSyncWord; register;
begin
// must only be called after successfull queueing
If ((SyncWord and FL_EVENT_MASK_VALID) <> 0) and ((SyncWord and FL_EVENT_MASK_WAITCOUNTER) <> 0) then
  begin
    // just dequeue, ignore everything else
    Dec(SyncWord);
    Result := FL_EVENT_IOPRES_SUCCESS;
  end
else Result := FL_EVENT_IOPRES_INVALID;
end;

//==============================================================================

Function FastEventEnqueue(var SyncWord: TFLSyncWord; CallData: TFLSyncWord): TFLQueueResult;
begin
ConsumeArg(CallData);
case InterlockedOperation(SyncWord,FastEventEnqueueIOP) of
  FL_EVENT_IOPRES_SUCCESS:  Result := qrAcquired;
  FL_EVENT_IOPRES_PULSING,
  FL_EVENT_IOPRES_WAITERS:  Result := qrFailed;
  FL_EVENT_IOPRES_QUEUED:   Result := qrQueued;
else
 {FL_EVENT_IOPRES_INVALID}
  raise EFLInvalidState.Create('FastEventEnqueue: Invalid state of event sync word.');
end;
end;

//------------------------------------------------------------------------------

Function FastEventQueuedAcquire(var SyncWord: TFLSyncWord; CallData: TFLSyncWord): Boolean;
begin
ConsumeArg(CallData);
case InterlockedOperation(SyncWord,FastEventQueuedAcquireIOP) of
  FL_EVENT_IOPRES_SUCCESS:  Result := True;
  FL_EVENT_IOPRES_LOCKED:   Result := False;
else
 {FL_EVENT_IOPRES_INVALID}
  raise EFLInvalidState.Create('FastEventQueuedAcquire: Invalid state of event sync word.');
end;
end;

//------------------------------------------------------------------------------

procedure FastEventDequeue(var SyncWord: TFLSyncWord; CallData: TFLSyncWord);
begin
ConsumeArg(CallData);
If InterlockedOperation(SyncWord,FastEventDequeueIOP) <> FL_EVENT_IOPRES_SUCCESS then
  raise EFLInvalidState.Create('FastEventDequeue: Invalid state of event sync word.');
end;

//------------------------------------------------------------------------------

Function FastEventWaitToPass(var SyncWord: TFLSyncWord; WaitParams: TFLWaitParams; ClockFrequency: Int64): TFLWaitResult; overload;
var
  WaitParamsInternal: TFLWaitParamsInternal;
begin
WaitParamsInternal.PublicParams.WaitParams := WaitParams;
If not GetClockValue(WaitParamsInternal.PublicParams.ClockStart) then
  raise EFLClockError.Create('FastEventWaitToPass: Unable to obtain clock value.');
WaitParamsInternal.PublicParams.ClockFreq := ClockFrequency;
WaitParamsInternal.SyncWordPtr := Addr(SyncWord);
WaitParamsInternal.EnqueueFce := FastEventEnqueue;
WaitParamsInternal.QueuedAcquireFce := FastEventQueuedAcquire;
WaitParamsInternal.DequeueFce := FastEventDequeue;
WaitParamsInternal.CallData := 0;
Result := ExecuteWaiting(WaitParamsInternal);
end;

{===============================================================================
    Fast event - procedural interface implementation
===============================================================================}

procedure FastEventInit(out SyncWord: TFLSyncWord; ManualReset: Boolean = False; InitialState: Boolean = False);
var
  SyncWordValue:  TFLSyncWord;
begin
// M := ManualReset, L := not InitialState
SyncWordValue := TFLSyncWord(FL_INITVAL or FL_EVENT_MASK_VALID);
If ManualReset then
  SyncWordValue := SyncWordValue or FL_EVENT_MASK_MANUALRESET;
If not InitialState then
  SyncWordValue := SyncWordValue or FL_EVENT_MASK_LOCK;
InterlockedStore(TFLSyncWord((@SyncWord)^),SyncWordValue);
end;

//------------------------------------------------------------------------------

procedure FastEventFinal(var SyncWord: TFLSyncWord);
begin
InterlockedStore(SyncWord,FL_INITVAL);
end;

//------------------------------------------------------------------------------

procedure FastEventSet(var SyncWord: TFLSyncWord);
begin
If not IsValid(InterlockedAnd(SyncWord,not(FL_EVENT_MASK_LOCK or FL_EVENT_MASK_PULSING))) then
  raise EFLInvalidState.Create('FastEventSet: Invalid state of event sync word.');
end;

//------------------------------------------------------------------------------

procedure FastEventReset(var SyncWord: TFLSyncWord);
begin
If InterlockedOperation(SyncWord,FastEventResetIOP) = FL_EVENT_IOPRES_INVALID then
  raise EFLInvalidState.Create('FastEventReset: Invalid state of event sync word.');
end;

//------------------------------------------------------------------------------

procedure FastEventPulse(var SyncWord: TFLSyncWord);
begin
If InterlockedOperation(SyncWord,FastEventPulseIOP) = FL_EVENT_IOPRES_INVALID then
  raise EFLInvalidState.Create('FastEventPulse: Invalid state of event sync word.');
end;

//------------------------------------------------------------------------------

Function FastEventPass(var SyncWord: TFLSyncWord): Boolean;
begin
case InterlockedOperation(SyncWord,FastEventPassIOP) of
  FL_EVENT_IOPRES_SUCCESS:  Result := True;
  FL_EVENT_IOPRES_LOCKED,
  FL_EVENT_IOPRES_PULSING,
  FL_EVENT_IOPRES_WAITERS:  Result := False;
else
 {FL_EVENT_IOPRES_INVALID}
  raise EFLInvalidState.Create('FastEventPass: Invalid state of event sync word.');
end;
end;

//------------------------------------------------------------------------------

Function FastEventSpinToPass(var SyncWord: TFLSyncWord; SpinParams: TFLSpinParams): TFLWaitResult;
var
  WaitParamsInternal: TFLWaitParamsInternal;
begin
WaitParamsInternal.PublicParams.SpinParams := SpinParams;
WaitParamsInternal.SyncWordPtr := Addr(SyncWord);
WaitParamsInternal.EnqueueFce := FastEventEnqueue;
WaitParamsInternal.QueuedAcquireFce := FastEventQueuedAcquire;
WaitParamsInternal.DequeueFce := FastEventDequeue;
WaitParamsInternal.CallData := 0;
Result := ExecuteSpinning(WaitParamsInternal);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function FastEventSpinToPass(var SyncWord: TFLSyncWord; SpinCount: UInt32): TFLWaitResult;
var
  SpinParams: TFLSpinParams;
begin
SpinParams := DefaultSpinParams;
SpinParams.SpinCount := SpinCount;
Result := FastEventSpinToPass(SyncWord,SpinParams);
end;

//------------------------------------------------------------------------------

Function FastEventWaitToPass(var SyncWord: TFLSyncWord; WaitParams: TFLWaitParams): TFLWaitResult;
var
  ClockFrequency: Int64;
begin
If not GetClockFrequency(ClockFrequency) then
  raise EFLClockError.Create('FastEventWaitToPass: Unable to obtain clock frequency.');
Result := FastEventWaitToPass(SyncWord,WaitParams,ClockFrequency);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function FastEventWaitToPass(var SyncWord: TFLSyncWord; Timeout: UInt32): TFLWaitResult;
var
  WaitParams: TFLWaitParams;
begin
WaitParams := DefaultWaitParams;
WaitParams.Timeout := Timeout;
Result := FastEventWaitToPass(SyncWord,WaitParams);
end;


{===============================================================================
--------------------------------------------------------------------------------
                                   TFastEvent
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastEvent - class declaration
===============================================================================}
{-------------------------------------------------------------------------------
    TFastEvent - protected methods implementation
-------------------------------------------------------------------------------}

procedure TFastEvent.SyncWordInit(const InitArgs: array of const);
var
  ManualReset:  Boolean;
  InitialState: Boolean;
begin
ManualReset := False;
If ArgTypePresent(InitArgs,0,vtBoolean) then
  ManualReset := InitArgs[0].VBoolean;
InitialState := False;
If ArgTypePresent(InitArgs,1,vtBoolean) then
  InitialState := InitArgs[1].VBoolean;
FastEventInit(fSyncWordPtr^,ManualReset,InitialState);
end;

//------------------------------------------------------------------------------

procedure TFastEvent.SyncWordFinal;
begin
FastEventFinal(fSyncWordPtr^);
end;

{-------------------------------------------------------------------------------
    TFastEvent - public methods implementation
-------------------------------------------------------------------------------}

constructor TFastEvent.Create(ManualReset: Boolean; InitialState: Boolean);
begin
CreateBase;
fMode := flmOwner;
Initialize(@fSyncWord,True,[ManualReset,InitialState]);
AcquireReference;
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TFastEvent.Create(var SyncWord: TFLSyncWord; ManualReset: Boolean; InitialState: Boolean);
begin
CreateBase;
fMode := flmWrapper;
Initialize(@SyncWord,True,[ManualReset,InitialState]);
AcquireReference;
end;

//------------------------------------------------------------------------------

procedure TFastEvent.EventSet;
begin
FastEventSet(fSyncWordPtr^);
end;

//------------------------------------------------------------------------------

procedure TFastEvent.EventReset;
begin
FastEventReset(fSyncWordPtr^);
end;

//------------------------------------------------------------------------------

procedure TFastEvent.EventPulse;
begin
FastEventPulse(fSyncWordPtr^);
end;

//------------------------------------------------------------------------------

Function TFastEvent.EventPass: Boolean;
begin
Result := FastEventPass(fSyncWordPtr^);
end;

//------------------------------------------------------------------------------

Function TFastEvent.EventSpinToPass(SpinCount: UInt32): TFLWaitResult;
var
  LocalSpinParams:  TFLSpinParams;
begin
LocalSpinParams := fSpinParams;
LocalSpinParams.SpinCount := SpinCount;
Result := FastEventSpinToPass(fSyncWordPtr^,LocalSpinParams);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function TFastEvent.EventSpinToPass: TFLWaitResult;
begin
Result := FastEventSpinToPass(fSyncWordPtr^,fSpinParams);
end;

//------------------------------------------------------------------------------

Function TFastEvent.EventWaitToPass(Timeout: UInt32): TFLWaitResult;
var
  LocalWaitParams:  TFLWaitParams;
begin
LocalWaitParams := fWaitParams;
LocalWaitParams.Timeout := Timeout;
Result := FastEventWaitToPass(fSyncWordPtr^,LocalWaitParams,fClockFreq);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function TFastEvent.EventWaitToPass: TFLWaitResult;
begin
Result := FastEventWaitToPass(fSyncWordPtr^,fWaitParams,fClockFreq);
end;


{===============================================================================
--------------------------------------------------------------------------------
                                 Fast semaphore
--------------------------------------------------------------------------------
===============================================================================}
{
               HI      - (V) validity bit, must be 1
      HI-10 .. HI-1    - (W) wait counter (max 1023 waiters)
          0 .. HI-11   - (C) main counter (0 non signaled, >0 signaled, max
                             value 2097151 or 9007199254740991)
}
const
  FL_SEMAPHORE_MASK_VALID       = FL_COMMON_MASK_VALID;
  FL_SEMAPHORE_MASK_WAITCOUNTER = ((TFLSyncWord(1) shl 10) - 1) shl (FL_WORDHIBIT - 10);
  FL_SEMAPHORE_MASK_MAINCOUNTER = (TFLSyncWord(1) shl (FL_WORDHIBIT - 10)) - 1;

  FL_SEMAPHORE_DELTA_WAIT = TFLSyncWord(1) shl (FL_WORDHIBIT - 10);

  FL_SEMAPHORE_IOPRES_INVALID  = -1;
  FL_SEMAPHORE_IOPRES_SUCCESS  = 0;
  FL_SEMAPHORE_IOPRES_LOCKED   = 1;
  FL_SEMAPHORE_IOPRES_WAITERS  = 2;
  FL_SEMAPHORE_IOPRES_OVERFLOW = 3;
  FL_SEMAPHORE_IOPRES_QUEUED   = 4;

{===============================================================================
    Fast semaphore - internal functions implementation
===============================================================================}

Function FastSemaphoreAcquireIOP(var SyncWord: TFLSyncWord; AcquireCount: TFLSyncWord): TFLSyncWord; register;
begin
// AcquireCount must be properly masked or bound-checked but unshifted before passing it here
If (SyncWord and FL_SEMAPHORE_MASK_VALID) <> 0 then
  begin
  {
    Asynchronous acquire can be done only when there is no waiter and of
    course the state is signaled (main counter must be at least equal to
    acquire count).
  }
    If (SyncWord and FL_SEMAPHORE_MASK_MAINCOUNTER) >= AcquireCount then
      begin
        If (SyncWord and FL_SEMAPHORE_MASK_WAITCOUNTER) = 0 then
          begin
            SyncWord := SyncWord - AcquireCount;
            Result := FL_SEMAPHORE_IOPRES_SUCCESS;
          end
        else Result := FL_SEMAPHORE_IOPRES_WAITERS;
      end
    else If (SyncWord and FL_SEMAPHORE_MASK_MAINCOUNTER) <> 0 then
      Result := FL_SEMAPHORE_IOPRES_OVERFLOW
    else
      Result := FL_SEMAPHORE_IOPRES_LOCKED;
  end
else Result := FL_SEMAPHORE_IOPRES_INVALID;
end;

//------------------------------------------------------------------------------

Function FastSemaphoreReleaseIOP(var SyncWord: TFLSyncWord; ReleaseCount: TFLSyncWord): TFLSyncWord; register;
begin
// ReleaseCount must be checked externally
If (SyncWord and FL_SEMAPHORE_MASK_VALID) <> 0 then
  begin
    // allow release only if release count cannot overflow counter
    If (SyncWord and FL_SEMAPHORE_MASK_MAINCOUNTER) <= (FL_SEMAPHORE_MASK_MAINCOUNTER - ReleaseCount) then
      begin
        SyncWord := SyncWord + ReleaseCount;
        Result := FL_SEMAPHORE_IOPRES_SUCCESS;
      end
    else Result := FL_SEMAPHORE_IOPRES_OVERFLOW;
  end
else Result := FL_SEMAPHORE_IOPRES_INVALID;
end;

//------------------------------------------------------------------------------

Function FastSemaphoreEnqueueIOP(var SyncWord: TFLSyncWord; AcquireCount: TFLSyncWord): TFLSyncWord; register;
begin
If (SyncWord and FL_SEMAPHORE_MASK_VALID) <> 0 then
  begin
    If (SyncWord and FL_SEMAPHORE_MASK_MAINCOUNTER) >= AcquireCount then
      begin
        // we can acquire the semaphore directly (do not check for waiters)
        SyncWord := SyncWord - AcquireCount;
        Result := FL_SEMAPHORE_IOPRES_SUCCESS;
      end
    // try to enqueue
    else If (SyncWord and FL_SEMAPHORE_MASK_WAITCOUNTER) < FL_SEMAPHORE_MASK_WAITCOUNTER then
      begin
        SyncWord := SyncWord + FL_SEMAPHORE_DELTA_WAIT;
        Result := FL_SEMAPHORE_IOPRES_QUEUED;
      end
    else Result := FL_SEMAPHORE_IOPRES_WAITERS;
  end
else Result := FL_SEMAPHORE_IOPRES_INVALID;
end;

//------------------------------------------------------------------------------

Function FastSemaphoreQueuedAcquireIOP(var SyncWord: TFLSyncWord; AcquireCount: TFLSyncWord): TFLSyncWord; register;
begin
If ((SyncWord and FL_SEMAPHORE_MASK_VALID) <> 0) and ((SyncWord and FL_SEMAPHORE_MASK_WAITCOUNTER) <> 0) then
  begin
    If (SyncWord and FL_SEMAPHORE_MASK_MAINCOUNTER) >= AcquireCount then
      begin
        // can acquire...
        SyncWord := SyncWord - AcquireCount;
        // dequeue
        SyncWord := SyncWord - FL_SEMAPHORE_DELTA_WAIT;
        Result := FL_SEMAPHORE_IOPRES_SUCCESS;
      end
    else If (SyncWord and FL_SEMAPHORE_MASK_MAINCOUNTER) <> 0 then
      Result := FL_SEMAPHORE_IOPRES_OVERFLOW
    else
      Result := FL_SEMAPHORE_IOPRES_LOCKED;
  end
else Result := FL_SEMAPHORE_IOPRES_INVALID;
end;

//------------------------------------------------------------------------------

Function FastSemaphoreDequeueIOP(var SyncWord: TFLSyncWord): TFLSyncWord; register;
begin
If ((SyncWord and FL_SEMAPHORE_MASK_VALID) <> 0) and ((SyncWord and FL_SEMAPHORE_MASK_WAITCOUNTER) <> 0) then
  begin
    SyncWord := SyncWord - FL_SEMAPHORE_DELTA_WAIT;
    Result := FL_SEMAPHORE_IOPRES_SUCCESS;
  end
else  Result := FL_SEMAPHORE_IOPRES_INVALID;
end;

//==============================================================================

Function FastSemaphoreEnqueue(var SyncWord: TFLSyncWord; AcquireCount: TFLSyncWord): TFLQueueResult;
begin
case InterlockedOperation(SyncWord,AcquireCount,FastSemaphoreEnqueueIOP) of
  FL_SEMAPHORE_IOPRES_SUCCESS:  Result := qrAcquired;
  FL_SEMAPHORE_IOPRES_WAITERS:  Result := qrFailed;
  FL_SEMAPHORE_IOPRES_QUEUED:   Result := qrQueued;
else
 {FL_SEMAPHORE_IOPRES_INVALID}
  raise EFLInvalidState.Create('FastSemaphoreEnqueue: Invalid state of semaphore sync word.');
end;
end;

//------------------------------------------------------------------------------

Function FastSemaphoreQueuedAcquire(var SyncWord: TFLSyncWord; AcquireCount: TFLSyncWord): Boolean;
begin
case InterlockedOperation(SyncWord,AcquireCount,FastSemaphoreQueuedAcquireIOP) of
  FL_SEMAPHORE_IOPRES_SUCCESS:  Result := True;
  FL_SEMAPHORE_IOPRES_LOCKED,
  FL_SEMAPHORE_IOPRES_OVERFLOW: Result := False;
else
 {FL_SEMAPHORE_IOPRES_INVALID}
  raise EFLInvalidState.Create('FastSemaphoreQueuedAcquire: Invalid state of semaphore sync word.');
end;
end;

//------------------------------------------------------------------------------

procedure FastSemaphoreDequeue(var SyncWord: TFLSyncWord; CallData: TFLSyncWord);
begin
ConsumeArg(CallData);
If InterlockedOperation(SyncWord,FastSemaphoreDequeueIOP) <> FL_SEMAPHORE_IOPRES_SUCCESS then
  raise EFLInvalidState.Create('FastSemaphoreDequeue: Invalid state of semaphore sync word.');
end;

//------------------------------------------------------------------------------

Function FastSemaphoreWaitToAcquire(var SyncWord: TFLSyncWord; WaitParams: TFLWaitParams; ClockFrequency: Int64; AcquireCount: TFLSyncWord): TFLWaitResult; overload;
var
  WaitParamsInternal: TFLWaitParamsInternal;
begin
WaitParamsInternal.PublicParams.WaitParams := WaitParams;
If not GetClockValue(WaitParamsInternal.PublicParams.ClockStart) then
  raise EFLClockError.Create('FastSemaphoreWaitToAcquire: Unable to obtain clock value.');
WaitParamsInternal.PublicParams.ClockFreq := ClockFrequency;
WaitParamsInternal.SyncWordPtr := Addr(SyncWord);
WaitParamsInternal.EnqueueFce := FastSemaphoreEnqueue;
WaitParamsInternal.QueuedAcquireFce := FastSemaphoreQueuedAcquire;
WaitParamsInternal.DequeueFce := FastSemaphoreDequeue;
WaitParamsInternal.CallData := AcquireCount;
Result := ExecuteWaiting(WaitParamsInternal);
end;

{===============================================================================
    Fast semaphore - procedural interface implementation
===============================================================================}

procedure FastSemaphoreInit(out SyncWord: TFLSyncWord; InitialCount: TFLSyncWord = 0);
var
  SyncWordValue:  TFLSyncWord;
begin
SyncWordValue := TFLSyncWord(FL_INITVAL or FL_SEMAPHORE_MASK_VALID);
// check bounds for initial value of main counter
If (InitialCount < 0) or (InitialCount > FL_SEMAPHORE_MASK_MAINCOUNTER) then
  raise EFLInvalidValue.CreateFmt('FastSemaphoreInit: Invalid semaphore count (%d)',[InitialCount]);
SyncWordValue := SyncWordValue or (InitialCount and FL_SEMAPHORE_MASK_MAINCOUNTER);
InterlockedStore(TFLSyncWord((@SyncWord)^),SyncWordValue);
end;

//------------------------------------------------------------------------------

procedure FastSemaphoreFinal(var SyncWord: TFLSyncWord);
begin
InterlockedStore(SyncWord,FL_INITVAL);
end;

//------------------------------------------------------------------------------

Function FastSemaphoreCount(var SyncWord: TFLSyncWord): TFLSyncWord;
begin
Result := InterlockedLoad(SyncWord);
If IsValid(Result) then
  Result := Result and FL_SEMAPHORE_MASK_MAINCOUNTER
else
  raise EFLInvalidState.Create('FastSemaphoreCount: Invalid state of semaphore sync word.');
end;

//------------------------------------------------------------------------------

Function FastSemaphoreAcquire(var SyncWord: TFLSyncWord; AcquireCount: TFLSyncWord = 1): Boolean;
begin
If (AcquireCount <= 0) or (AcquireCount > FL_SEMAPHORE_MASK_MAINCOUNTER) then
  raise EFLInvalidValue.CreateFmt('FastSemaphoreAcquire: Invalid semaphore acquire count (%d)',[AcquireCount]);
case InterlockedOperation(SyncWord,AcquireCount,FastSemaphoreAcquireIOP) of
  FL_SEMAPHORE_IOPRES_SUCCESS:  Result := True;
  FL_SEMAPHORE_IOPRES_LOCKED,
  FL_SEMAPHORE_IOPRES_WAITERS,
  FL_SEMAPHORE_IOPRES_OVERFLOW: Result := False;
else
 {FL_SEMAPHORE_IOPRES_INVALID}
  raise EFLInvalidState.Create('FastSemaphoreAcquire: Invalid state of semaphore sync word.');
end;
end;

//------------------------------------------------------------------------------

Function FastSemaphoreRelease(var SyncWord: TFLSyncWord; ReleaseCount: TFLSyncWord = 1): Boolean;
begin
If (ReleaseCount <= 0) or (ReleaseCount > FL_SEMAPHORE_MASK_MAINCOUNTER) then
  raise EFLInvalidValue.CreateFmt('FastSemaphoreAcquire: Invalid semaphore release count (%d)',[ReleaseCount]);  
case InterlockedOperation(SyncWord,ReleaseCount,FastSemaphoreReleaseIOP) of
  FL_SEMAPHORE_IOPRES_SUCCESS:  Result := True;
  FL_SEMAPHORE_IOPRES_OVERFLOW: Result := False;
else
 {FL_SEMAPHORE_IOPRES_INVALID}
  raise EFLInvalidState.Create('FastSemaphoreRelease: Invalid state of semaphore sync word.');
end;
end;

//------------------------------------------------------------------------------

Function FastSemaphoreSpinToAcquire(var SyncWord: TFLSyncWord; SpinParams: TFLSpinParams; AcquireCount: TFLSyncWord = 1): TFLWaitResult;
var
  WaitParamsInternal: TFLWaitParamsInternal;
begin
If (AcquireCount <= 0) or (AcquireCount > FL_SEMAPHORE_MASK_MAINCOUNTER) then
  raise EFLInvalidValue.CreateFmt('FastSemaphoreSpinToAcquire: Invalid semaphore acquire count (%d)',[AcquireCount]);
WaitParamsInternal.PublicParams.SpinParams := SpinParams;
WaitParamsInternal.SyncWordPtr := Addr(SyncWord);
WaitParamsInternal.EnqueueFce := FastSemaphoreEnqueue;
WaitParamsInternal.QueuedAcquireFce := FastSemaphoreQueuedAcquire;
WaitParamsInternal.DequeueFce := FastSemaphoreDequeue;
WaitParamsInternal.CallData := AcquireCount;
Result := ExecuteSpinning(WaitParamsInternal);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function FastSemaphoreSpinToAcquire(var SyncWord: TFLSyncWord; SpinCount: UInt32; AcquireCount: TFLSyncWord = 1): TFLWaitResult;
var
  SpinParams: TFLSpinParams;
begin
// acquire count is checked in called overload of FastSemaphoreSpinToAcquire
SpinParams := DefaultSpinParams;
SpinParams.SpinCount := SpinCount;
Result := FastSemaphoreSpinToAcquire(SyncWord,SpinParams,AcquireCount);
end;

//------------------------------------------------------------------------------

Function FastSemaphoreWaitToAcquire(var SyncWord: TFLSyncWord; WaitParams: TFLWaitParams; AcquireCount: TFLSyncWord = 1): TFLWaitResult;
var
  ClockFrequency: Int64;
begin
If (AcquireCount <= 0) or (AcquireCount > FL_SEMAPHORE_MASK_MAINCOUNTER) then
  raise EFLInvalidValue.CreateFmt('FastSemaphoreWaitToAcquire: Invalid semaphore acquire count (%d)',[AcquireCount]);
If not GetClockFrequency(ClockFrequency) then
  raise EFLClockError.Create('FastSemaphoreWaitToAcquire: Unable to obtain clock frequency.');
Result := FastSemaphoreWaitToAcquire(SyncWord,WaitParams,ClockFrequency,AcquireCount);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function FastSemaphoreWaitToAcquire(var SyncWord: TFLSyncWord; Timeout: UInt32; AcquireCount: TFLSyncWord = 1): TFLWaitResult;
var
  WaitParams: TFLWaitParams;
begin
If (AcquireCount <= 0) or (AcquireCount > FL_SEMAPHORE_MASK_MAINCOUNTER) then
  raise EFLInvalidValue.CreateFmt('FastSemaphoreWaitToAcquire: Invalid semaphore acquire count (%d)',[AcquireCount]);
WaitParams := DefaultWaitParams;
WaitParams.Timeout := Timeout;
Result := FastSemaphoreWaitToAcquire(SyncWord,WaitParams,AcquireCount);
end;


{===============================================================================
--------------------------------------------------------------------------------
                                 TFastSemaphore
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TFastSemaphore - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TFastSemaphore - protected methods implementation
-------------------------------------------------------------------------------}

procedure TFastSemaphore.SyncWordInit(const InitArgs: array of const);
var
  InitialCount: TFLSyncWord;
begin
InitialCount := 0;
{$IFDEF SyncWord64}
If ArgTypePresent(InitArgs,0,vtInt64) then
  InitialCount := InitArgs[0].VInt64^;  // int64 is stored only as reference
{$ELSE}
If ArgTypePresent(InitArgs,0,vtInteger) then
  InitialCount := InitArgs[0].VInteger;
{$ENDIF}
FastSemaphoreInit(fSyncWordPtr^,InitialCount);
end;

//------------------------------------------------------------------------------

procedure TFastSemaphore.SyncWordFinal;
begin
FastSemaphoreFinal(fSyncWordPtr^);
end;

{-------------------------------------------------------------------------------
    TFastSemaphore - public methods implementation
-------------------------------------------------------------------------------}

constructor TFastSemaphore.Create(InitialCount: TFLSyncWord);
begin
CreateBase;
fMode := flmOwner;
Initialize(@fSyncWord,True,[InitialCount]);
AcquireReference;
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

constructor TFastSemaphore.Create(var SyncWord: TFLSyncWord; InitialCount: TFLSyncWord);
begin
CreateBase;
fMode := flmWrapper;
Initialize(@SyncWord,True,[InitialCount]);
AcquireReference;
end;

//------------------------------------------------------------------------------

Function TFastSemaphore.SemaphoreCount: TFLSyncWord;
begin
Result := FastSemaphoreCount(fSyncWordPtr^);
end;

//------------------------------------------------------------------------------

Function TFastSemaphore.SemaphoreAcquire(AcquireCount: TFLSyncWord = 1): Boolean;
begin
Result := FastSemaphoreAcquire(fSyncWordPtr^,AcquireCount);
end;

//------------------------------------------------------------------------------

Function TFastSemaphore.SemaphoreRelease(ReleaseCount: TFLSyncWord = 1): Boolean;
begin
Result := FastSemaphoreRelease(fSyncWordPtr^,ReleaseCount);
end;

//------------------------------------------------------------------------------

Function TFastSemaphore.SemaphoreSpinToAcquireBy(SpinCount: UInt32; AcquireCount: TFLSyncWord): TFLWaitResult;
var
  LocalSpinParams:  TFLSpinParams;
begin
LocalSpinParams := fSpinParams;
LocalSpinParams.SpinCount := SpinCount;
Result := FastSemaphoreSpinToAcquire(fSyncWordPtr^,LocalSpinParams,AcquireCount);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function TFastSemaphore.SemaphoreSpinToAcquireBy(AcquireCount: TFLSyncWord): TFLWaitResult;
begin
Result := FastSemaphoreSpinToAcquire(fSyncWordPtr^,fSpinParams,AcquireCount);
end;

//------------------------------------------------------------------------------

Function TFastSemaphore.SemaphoreSpinToAcquire(SpinCount: UInt32): TFLWaitResult;
begin
Result := SemaphoreSpinToAcquireBy(SpinCount,1);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function TFastSemaphore.SemaphoreSpinToAcquire: TFLWaitResult;
begin
Result := SemaphoreSpinToAcquireBy(1);
end;

//------------------------------------------------------------------------------

Function TFastSemaphore.SemaphoreWaitToAcquireBy(Timeout: UInt32; AcquireCount: TFLSyncWord): TFLWaitResult;
var
  LocalWaitParams:  TFLWaitParams;
begin
LocalWaitParams := fWaitParams;
LocalWaitParams.Timeout := Timeout;
Result := FastSemaphoreWaitToAcquire(fSyncWordPtr^,LocalWaitParams,fClockFreq,AcquireCount);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function TFastSemaphore.SemaphoreWaitToAcquireBy(AcquireCount: TFLSyncWord): TFLWaitResult;
begin
Result := FastSemaphoreWaitToAcquire(fSyncWordPtr^,fWaitParams,fClockFreq,AcquireCount);
end;

//------------------------------------------------------------------------------

Function TFastSemaphore.SemaphoreWaitToAcquire(Timeout: UInt32): TFLWaitResult;
begin
Result := SemaphoreWaitToAcquireBy(Timeout,1);
end;

// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

Function TFastSemaphore.SemaphoreWaitToAcquire: TFLWaitResult;
begin
Result := SemaphoreWaitToAcquireBy(1);
end;

(*
{===============================================================================
--------------------------------------------------------------------------------
                                   Fast locks
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    Fast locks - internal functions
===============================================================================}

Function SpinDelay(Divisor: UInt32): UInt32;  // do not inline
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

Function YieldThread: Boolean;{$IFDEF CanInline} inline;{$ENDIF}
begin
{$IFDEF Windows}
Result := SwitchToThread;
{$ELSE}
Result := sched_yield = 0;
{$ENDIF}
end;

{===============================================================================
    Fast locks - imlementation constants
===============================================================================}
const
  FL_UNLOCKED = TFLSyncWord(0);

  FL_INVALID = TFLSyncWord(-1); // used to finalize the objects

{===============================================================================
    Fast locks - waiting and spinning implementation
===============================================================================}
type
  TFLSpinParams = record
    SyncWordPtr:    PFLSyncWord;
    SpinCount:      UInt32;
    SpinDelayCount: UInt32;
    Reserve:        Boolean;
    Reserved:       Boolean;
    FceReserve:     Function(var SyncWord: TFLSyncWord): Boolean;
    FceUnreserve:   procedure(var SyncWord: TFLSyncWord);
    FceAcquire:     Function(var SyncWord: TFLSyncWord; Reserved: Boolean; out FailedDueToReservation: Boolean): Boolean;
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
    while not Params.FceAcquire(Params.SyncWordPtr^,Reserved,FailedDueToReservation) do
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
      If Params.FceReserve(Params.SyncWordPtr^) then
        try
          Result := InternalSpin(True);
        finally
          Params.FceUnreserve(Params.SyncWordPtr^);
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
    FceReserve:       Function(var SyncWord: TFLSyncWord): Boolean;
    FceUnreserve:     procedure(var SyncWord: TFLSyncWord);
    FceAcquire:       Function(var SyncWord: TFLSyncWord; Reserved: Boolean; out FailedDueToReservation: Boolean): Boolean;
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
    while not Params.FceAcquire(Params.SyncWordPtr^,Reserved,FailedDueToReservation) do
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
                dmNone:;      // do nothing;
                dmYield:      YieldThread;
              {$IFDEF Windows}
                dmSleep:      Sleep(10);
                dmSleepEx:    SleepEx(10,True);
                dmYieldSleep: If not YieldThread then
                                Sleep(10);
              {$ELSE}
                dmSleep,
                dmSleepEx,
                dmYieldSleep: Sleep(10);
              {$ENDIF}
              else
               {dmSpin}
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
        If Params.FceReserve(Params.SyncWordPtr^) then
          try
            Result := InternalWait(True);
          finally
            Params.FceUnreserve(Params.SyncWordPtr^);
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
SetWaitDelayMethod(dmSpin);
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

constructor TFastLock.Create(var SyncWord: TFLSyncWord);
begin
inherited Create;
Initialize(@SyncWord);
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
{
  Meaning of bits in sync word for fast critical section:

    32bit     64bit
     0..15     0..31    - acquire count
    16..31    32..63    - reserve count
}
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
  FL_CS_ACQUIRE_MAX   = TFLSyncWord(32767);       // 0x7FFF
  FL_CS_ACQUIRE_SHIFT = 0;

  FL_CS_RESERVE_DELTA = TFLSyncWord($00010000);
  FL_CS_RESERVE_MASK  = TFLSyncWord($FFFF0000);
  FL_CS_RESERVE_MAX   = TFLSyncWord(32767);       // 0x7FFF
  FL_CS_RESERVE_SHIFT = 16;

{$ENDIF}  

{===============================================================================
    Fast critical section - procedural interface implementation
===============================================================================}
{-------------------------------------------------------------------------------
    Fast critical section - internal functions
-------------------------------------------------------------------------------}

Function _FastCriticalSectionReserve(var SyncWord: TFLSyncWord): Boolean;
var
  OldSyncWord:  TFLSyncWord;
begin
OldSyncWord := InterlockedExchangeAdd(SyncWord,FL_CS_RESERVE_DELTA);
Result := ((OldSyncWord and FL_CS_RESERVE_MASK) shr FL_CS_RESERVE_SHIFT) < FL_CS_RESERVE_MAX;
If not Result then
  InterlockedExchangeSub(SyncWord,FL_CS_RESERVE_DELTA);
end;

//------------------------------------------------------------------------------

procedure _FastCriticalSectionUnreserve(var SyncWord: TFLSyncWord);
begin
InterlockedExchangeSub(SyncWord,FL_CS_RESERVE_DELTA);
end;

//------------------------------------------------------------------------------

Function _FastCriticalSectionEnter(var SyncWord: TFLSyncWord; Reserved: Boolean; out FailedDueToReservation: Boolean): Boolean;
var
  OldSyncWord:  TFLSyncWord;
begin
FailedDueToReservation := False;
OldSyncWord := InterlockedExchangeAdd(SyncWord,FL_CS_ACQUIRE_DELTA);
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
  InterlockedExchangeSub(SyncWord,FL_CS_ACQUIRE_DELTA);
end;

//------------------------------------------------------------------------------

Function _FastCriticalSectionWaitToEnter(var SyncWord: TFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod; WaitSpinCount, SpinDelayCount: UInt32; CounterFrequency: Int64): TFLWaitResult;
var
  WaitParams: TFLWaitParams;
begin
WaitParams.SyncWordPtr := @SyncWord;
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

procedure FastCriticalSectionInit(out SyncWord: TFLSyncWord);
begin
{$IFDEF SyncWord64}
InterlockedStore64(@SyncWord,FL_UNLOCKED);
{$ELSE}
InterlockedStore32(@SyncWord,FL_UNLOCKED);
{$ENDIF}
end;

//------------------------------------------------------------------------------

procedure FastCriticalSectionFinal(var SyncWord: TFLSyncWord);
begin
InterlockedStore(SyncWord,FL_INVALID);
end;

//------------------------------------------------------------------------------

Function FastCriticalSectionEnter(var SyncWord: TFLSyncWord): Boolean;
var
  FailedDueToReservation: Boolean;
begin
Result := _FastCriticalSectionEnter(SyncWord,False,FailedDueToReservation);
ReadWriteBarrier;
end;

//------------------------------------------------------------------------------

procedure FastCriticalSectionLeave(var SyncWord: TFLSyncWord);
begin
ReadWriteBarrier;
InterlockedExchangeSub(SyncWord,FL_CS_ACQUIRE_DELTA);
end;

//------------------------------------------------------------------------------

Function FastCriticalSectionSpinToEnter(var SyncWord: TFLSyncWord; SpinCount: UInt32; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
var
  SpinParams: TFLSpinParams;
begin
SpinParams.SyncWordPtr := @SyncWord;
SpinParams.SpinCount := SpinCount;
SpinParams.SpinDelayCount := SpinDelayCount;
SpinParams.Reserve := True;
SpinParams.Reserved := False;
SpinParams.FceReserve := _FastCriticalSectionReserve;
SpinParams.FceUnreserve := _FastCriticalSectionUnreserve;
SpinParams.FceAcquire := _FastCriticalSectionEnter;
Result := _DoSpin(SpinParams);
ReadWriteBarrier;
end;

//------------------------------------------------------------------------------

Function FastCriticalSectionWaitToEnter(var SyncWord: TFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = dmSpin;
  WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
var
  CounterFrequency: Int64;
begin
If GetCounterFrequency(CounterFrequency) then
  begin
    Result := _FastCriticalSectionWaitToEnter(SyncWord,Timeout,WaitDelayMethod,WaitSpinCount,SpinDelayCount,CounterFrequency);
    ReadWriteBarrier;
  end
else raise EFLCounterError.CreateFmt('FastCriticalSectionWaitToEnter: Cannot obtain counter frequency (0x%.8x).',
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
  FastCriticalSectionInit(fSyncWordPtr^);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Finalize;
begin
If fOwnsSyncWord then
  FastCriticalSectionFinal(fSyncWordPtr^);
inherited;
end;

{-------------------------------------------------------------------------------
    TFastCriticalSection - public methods
-------------------------------------------------------------------------------}

Function TFastCriticalSection.Enter: Boolean;
begin
Result := FastCriticalSectionEnter(fSyncWordPtr^);
end;

//------------------------------------------------------------------------------

procedure TFastCriticalSection.Leave;
begin
FastCriticalSectionLeave(fSyncWordPtr^);
end;

//------------------------------------------------------------------------------

Function TFastCriticalSection.SpinToEnter(SpinCount: UInt32): TFLWaitResult;
begin
Result := FastCriticalSectionSpinToEnter(fSyncWordPtr^,SpinCount,GetSpinDelayCount);
end;

//------------------------------------------------------------------------------

Function TFastCriticalSection.WaitToEnter(Timeout: UInt32): TFLWaitResult;
begin
Result := _FastCriticalSectionWaitToEnter(fSyncWordPtr^,Timeout,GetWaitDelayMethod,GetWaitSpinCount,GetSpinDelayCount,fCounterFreq);
ReadWriteBarrier;
end;


{===============================================================================
--------------------------------------------------------------------------------
                                    Fast MREW
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    Fast MREW - implementation constants
===============================================================================}
{
  Meaning of bits in sync word for fast MREW:

    32bit     64bit
     0..11     0..31    - read count
    12..21    32..47    - write count
    22..31    48..63    - write reserve count
}
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
  FL_MREW_READ_MAX   = TFLSyncWord(2047);       // 0x7FF
  FL_MREW_READ_SHIFT = 0;

  FL_MREW_WRITE_DELTA = TFLSyncWord($00001000);
  FL_MREW_WRITE_MASK  = TFLSyncWord($003FF000);
  FL_MREW_WRITE_MAX   = TFLSyncWord(512);       // 0x1FF
  FL_MREW_WRITE_SHIFT = 12;

  FL_MREW_RESERVE_DELTA = TFLSyncWord($00400000);
  FL_MREW_RESERVE_MASK  = TFLSyncWord($FFC00000);
  FL_MREW_RESERVE_MAX   = TFLSyncWord(512);     // 0x1FF
  FL_MREW_RESERVE_SHIFT = 22;  

{$ENDIF}

{===============================================================================
    Fast MREW - procedural interface implementation
===============================================================================}
{-------------------------------------------------------------------------------
    Fast MREW - internal functions
-------------------------------------------------------------------------------}

Function _FastMREWReserveWrite(var SyncWord: TFLSyncWord): Boolean;
var
  OldSyncWord:  TFLSyncWord;
begin
OldSyncWord := InterlockedExchangeAdd(SyncWord,FL_MREW_RESERVE_DELTA);
// note that reservation is allowed if there are readers, but no new reader can enter
Result := ((OldSyncWord and FL_MREW_RESERVE_MASK) shr FL_MREW_RESERVE_SHIFT) < FL_MREW_RESERVE_MAX;
If not Result then
  InterlockedExchangeSub(SyncWord,FL_MREW_RESERVE_DELTA);
end;

//------------------------------------------------------------------------------

procedure _FastMREWUnreserveWrite(var SyncWord: TFLSyncWord);
begin
InterlockedExchangeSub(SyncWord,FL_MREW_RESERVE_DELTA);
end;

//------------------------------------------------------------------------------

{$IFDEF FPCDWM}{$PUSH}W5024{$ENDIF}
Function _FastMREWBeginRead(var SyncWord: TFLSyncWord; Reserved: Boolean; out FailedDueToReservation: Boolean): Boolean;
var
  OldSyncWord:  TFLSyncWord;
begin
FailedDueToReservation := False;
OldSyncWord := InterlockedExchangeAdd(SyncWord,FL_MREW_READ_DELTA);
{
  Do not mask or shift the read count. If there is any writer or reservation
  (which would manifest as count being above reader maximum), straight up fail.
}
If OldSyncWord >= FL_MREW_READ_MAX then
  begin
    InterlockedExchangeSub(SyncWord,FL_MREW_READ_DELTA);
    // indicate whether this failed solely due to reservation
    FailedDueToReservation := (((OldSyncWord and FL_MREW_WRITE_MASK) shr FL_MREW_WRITE_SHIFT) = 0) and
                              (((OldSyncWord and FL_MREW_RESERVE_MASK) shr FL_MREW_RESERVE_SHIFT) <> 0);
    Result := False;
  end
else Result := True;
end;
{$IFDEF FPCDWM}{$POP}{$ENDIF}

//------------------------------------------------------------------------------

Function _FastMREWWaitToRead(var SyncWord: TFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod; WaitSpinCount, SpinDelayCount: UInt32; CounterFrequency: Int64): TFLWaitResult;
var
  WaitParams: TFLWaitParams;
begin
WaitParams.SyncWordPtr := @SyncWord;
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

Function _FastMREWBeginWrite(var SyncWord: TFLSyncWord; Reserved: Boolean; out FailedDueToReservation: Boolean): Boolean;
var
  OldSyncWord:  TFLSyncWord;
begin
FailedDueToReservation := False;
OldSyncWord := InterlockedExchangeAdd(SyncWord,FL_MREW_WRITE_DELTA);
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
  InterlockedExchangeSub(SyncWord,FL_MREW_WRITE_DELTA);
end;

//------------------------------------------------------------------------------

Function _FastMREWWaitToWrite(var SyncWord: TFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod; WaitSpinCount, SpinDelayCount: UInt32; CounterFrequency: Int64): TFLWaitResult;
var
  WaitParams: TFLWaitParams;
begin
WaitParams.SyncWordPtr := @SyncWord;
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
    Fast MREW - public functions
-------------------------------------------------------------------------------}

procedure FastMREWInit(out SyncWord: TFLSyncWord);
begin
{$IFDEF SyncWord64}
InterlockedStore64(@SyncWord,FL_UNLOCKED);
{$ELSE}
InterlockedStore32(@SyncWord,FL_UNLOCKED);
{$ENDIF}
end;

//------------------------------------------------------------------------------

procedure FastMREWFinal(var SyncWord: TFLSyncWord);
begin
InterlockedStore(SyncWord,FL_INVALID);
end;

//------------------------------------------------------------------------------

Function FastMREWBeginRead(var SyncWord: TFLSyncWord): Boolean;
var
  FailedDueToReservation: Boolean;
begin
Result := _FastMREWBeginRead(SyncWord,False,FailedDueToReservation);
ReadWriteBarrier;
end;

//------------------------------------------------------------------------------

procedure FastMREWEndRead(var SyncWord: TFLSyncWord);
begin
ReadWriteBarrier;
InterlockedExchangeSub(SyncWord,FL_MREW_READ_DELTA);
end;

//------------------------------------------------------------------------------

Function FastMREWSpinToRead(var SyncWord: TFLSyncWord; SpinCount: UInt32; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
var
  SpinParams: TFLSpinParams;
begin
SpinParams.SyncWordPtr := @SyncWord;
SpinParams.SpinCount := SpinCount;
SpinParams.SpinDelayCount := SpinDelayCount;
SpinParams.Reserve := False;
SpinParams.Reserved := False;
SpinParams.FceReserve := _FastMREWReserveWrite;
SpinParams.FceUnreserve := _FastMREWUnreserveWrite;
SpinParams.FceAcquire := _FastMREWBeginRead;
Result := _DoSpin(SpinParams);
ReadWriteBarrier;
end;

//------------------------------------------------------------------------------

Function FastMREWWaitToRead(var SyncWord: TFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = dmSpin;
  WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
var
  CounterFrequency: Int64;
begin
If GetCounterFrequency(CounterFrequency) then
  begin
    Result := _FastMREWWaitToRead(SyncWord,Timeout,WaitDelayMethod,WaitSpinCount,SpinDelayCount,CounterFrequency);
    ReadWriteBarrier;
  end
else raise EFLCounterError.CreateFmt('FastMREWWaitToRead: Cannot obtain counter frequency (0x%.8x).',
                                     [{$IFDEF Windows}GetLastError{$ELSE}errno{$ENDIF}]);
end;

//------------------------------------------------------------------------------

Function FastMREWBeginWrite(var SyncWord: TFLSyncWord): Boolean;
var
  FailedDueToReservation: Boolean;
begin
Result := _FastMREWBeginWrite(SyncWord,False,FailedDueToReservation);
ReadWriteBarrier;
end;

//------------------------------------------------------------------------------

procedure FastMREWEndWrite(var SyncWord: TFLSyncWord);
begin
ReadWriteBarrier;
InterlockedExchangeSub(SyncWord,FL_MREW_WRITE_DELTA);
end;

//------------------------------------------------------------------------------

Function FastMREWSpinToWrite(var SyncWord: TFLSyncWord; SpinCount: UInt32; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
var
  SpinParams: TFLSpinParams;
begin
SpinParams.SyncWordPtr := @SyncWord;
SpinParams.SpinCount := SpinCount;
SpinParams.SpinDelayCount := SpinDelayCount;
SpinParams.Reserve := True;
SpinParams.Reserved := False;
SpinParams.FceReserve := _FastMREWReserveWrite;
SpinParams.FceUnreserve := _FastMREWUnreserveWrite;
SpinParams.FceAcquire := _FastMREWBeginWrite;
Result := _DoSpin(SpinParams);
ReadWriteBarrier;
end;

//------------------------------------------------------------------------------

Function FastMREWWaitToWrite(var SyncWord: TFLSyncWord; Timeout: UInt32; WaitDelayMethod: TFLWaitDelayMethod = dmSpin;
  WaitSpinCount: UInt32 = FL_DEF_WAIT_SPIN_CNT; SpinDelayCount: UInt32 = FL_DEF_SPIN_DELAY_CNT): TFLWaitResult;
var
  CounterFrequency: Int64;
begin
If GetCounterFrequency(CounterFrequency) then
  begin
    Result := _FastMREWWaitToWrite(SyncWord,Timeout,WaitDelayMethod,WaitSpinCount,SpinDelayCount,CounterFrequency);
    ReadWriteBarrier;
  end
else raise EFLCounterError.CreateFmt('FastMREWWaitToWrite: Cannot obtain counter frequency (0x%.8x).',
                                     [{$IFDEF Windows}GetLastError{$ELSE}errno{$ENDIF}]);
end;

{===============================================================================
--------------------------------------------------------------------------------
                                    TFastMREW
--------------------------------------------------------------------------------
===============================================================================}
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
  FastMREWInit(fSyncWordPtr^);
end;

//------------------------------------------------------------------------------

procedure TFastMREW.Finalize;
begin
If fOwnsSyncWord then
  FastMREWFinal(fSyncWordPtr^);
inherited;
end;

{-------------------------------------------------------------------------------
    TFastMREW - public methods
-------------------------------------------------------------------------------}

Function TFastMREW.BeginRead: Boolean;
begin
Result := FastMREWBeginRead(fSyncWordPtr^);
end;

//------------------------------------------------------------------------------

procedure TFastMREW.EndRead;
begin
FastMREWEndRead(fSyncWordPtr^);
end;

//------------------------------------------------------------------------------

Function TFastMREW.BeginWrite: Boolean;
begin
Result := FastMREWBeginWrite(fSyncWordPtr^);
end;

//------------------------------------------------------------------------------

procedure TFastMREW.EndWrite;
begin
FastMREWEndWrite(fSyncWordPtr^);
end;

//------------------------------------------------------------------------------

Function TFastMREW.SpinToRead(SpinCount: UInt32): TFLWaitResult;
begin
Result := FastMREWSpinToRead(fSyncWordPtr^,SpinCount,GetSpinDelayCount);
end;

//------------------------------------------------------------------------------

Function TFastMREW.WaitToRead(Timeout: UInt32): TFLWaitResult;
begin
Result := _FastMREWWaitToRead(fSyncWordPtr^,Timeout,GetWaitDelayMethod,GetWaitSpinCount,GetSpinDelayCount,fCounterFreq);
ReadWriteBarrier;
end;

//------------------------------------------------------------------------------

Function TFastMREW.SpinToWrite(SpinCount: UInt32): TFLWaitResult;
begin
Result := FastMREWSpinToWrite(fSyncWordPtr^,SpinCount,GetSpinDelayCount);
end;

//------------------------------------------------------------------------------

Function TFastMREW.WaitToWrite(Timeout: UInt32): TFLWaitResult;
begin
Result := _FastMREWWaitToWrite(fSyncWordPtr^,Timeout,GetWaitDelayMethod,GetWaitSpinCount,GetSpinDelayCount,fCounterFreq);
ReadWriteBarrier;
end;
*)
end.


