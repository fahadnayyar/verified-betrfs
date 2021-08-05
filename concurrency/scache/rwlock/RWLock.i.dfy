include "Ext.i.dfy"
include "SimpleExtToken.i.dfy"
include "../Constants.i.dfy"
include "FullMap.i.dfy"
include "../../../lib/Base/Option.s.dfy"

module RWLock refines SimpleExt {
  import opened Constants
  import opened Options
  import opened FullMaps

  /*
   * We consider two bits of the status field, ExcLock and Writeback.
   *
   * ExcLock and Writeback. Of course, 'ExcLock'
   * and 'Writeback' should be exclusive operations;
   * When both flags are set,
   * it should be interpreted as the 'ExcLock' being
   * pending, with the 'Writeback' being active.
   *
   * Those 2 bits gives 2x2 = 4 states. We then have 2 more:
   * Unmapped and Reading.
   *
   * NOTE: in retrospect, it might have made sense to have this
   * just be a struct of 5-6 booleans.
   */
  datatype Flag =
    | Unmapped
    | Reading
    | Reading_ExcLock
    | Available
    | Writeback
    | Writeback_PendingExcLock
    | PendingExcLock
    | ExcLock_Clean
    | ExcLock_Dirty

  type ThreadId = nat

  // Standard flow for obtaining a 'shared' lock

  datatype SharedState =
    | SharedPending(t: ThreadId)              // inc refcount
    | SharedPending2(t: ThreadId)             // !free & !writelocked
    | SharedObtained(t: ThreadId, b: Base.G)  // !reading

  // Standard flow for obtaining an 'exclusive' lock

  datatype ExcState = 
    | ExcNone
      // set ExcLock bit:
    | ExcPendingAwaitWriteback(t: int, b: Base.G)
      // check Writeback bit unset
      //   and `visited` of the refcounts
    | ExcPending(t: int, visited: int, clean: bool, b: Base.G)
    | ExcObtained(t: int, clean: bool)

  datatype WritebackState =
    | WritebackNone
      // set Writeback status bit
    | WritebackObtained(b: Base.G)

  // Flow for the phase of reading in a page from disk.
  // This is a special-case flow, because it needs to be performed
  // on the way to obtaining a 'shared' lock, but it requires
  // exclusive access to the underlying memory and resources.
  // End-game for this flow is to become an ordinary 'shared' lock

  datatype ReadState =
    | ReadNone
    | ReadPending                        // set status bit to ExcLock | Reading
    | ReadPendingCounted(t: ThreadId)    // inc refcount
    | ReadObtained(t: ThreadId)          // clear ExcLock bit

  datatype CentralState =
    | CentralNone
    | CentralState(flag: Flag, stored_value: Base.G)

  datatype M = M(
    central: CentralState,
    refCounts: map<ThreadId, nat>,

    ghost sharedState: FullMap<SharedState>,
    exc: ExcState,
    read: ReadState,

    // Flow for the phase of doing a write-back.
    // Special case in part because it can be initiated by any thread
    // and completed by any thread (not necessarily the same one).
    
    writeback: WritebackState
  )

  type F = M

  function unit() : F
  {
    M(CentralNone, map[], zero_map(), ExcNone, ReadNone, WritebackNone)
  }

  predicate dot_defined(a: F, b: F)
  {
    && !(a.central.CentralState? && b.central.CentralState?)
    && a.refCounts.Keys !! b.refCounts.Keys
    && (a.exc.ExcNone? || b.exc.ExcNone?)
    && (a.read.ReadNone? || b.read.ReadNone?)
    && (a.writeback.WritebackNone? || b.writeback.WritebackNone?)
  }

  function dot(a: F, b: F) : F
    //requires dot_defined(a, b)
  {
    M(
      if a.central.CentralState? then a.central else b.central,
      (map k | k in a.refCounts.Keys + b.refCounts.Keys ::
          if k in a.refCounts.Keys then a.refCounts[k] else b.refCounts[k]),
      add_fns(a.sharedState, b.sharedState),
      if !a.exc.ExcNone? then a.exc else b.exc,
      if !a.read.ReadNone? then a.read else b.read,
      if !a.writeback.WritebackNone? then a.writeback else b.writeback
    ) 
  }

  lemma dot_unit(x: F)
  ensures dot_defined(x, unit())
  ensures dot(x, unit()) == x
  {
  }

  lemma commutative(x: F, y: F)
  //requires dot_defined(x, y)
  ensures dot_defined(y, x)
  ensures dot(x, y) == dot(y, x)
  {
  }

  lemma associative(x: F, y: F, z: F)
  //requires dot_defined(y, z)
  //requires dot_defined(x, dot(y, z))
  ensures dot_defined(x, y)
  ensures dot_defined(dot(x, y), z)
  ensures dot(x, dot(y, z)) == dot(dot(x, y), z)
  {
    assume false;
  }

  function IsSharedRefFor(t: int) : (SharedState) -> bool
  {
    (ss: SharedState) => ss.t == t
  }

  function CountSharedRefs(m: FullMap<SharedState>, t: int) : nat
  {
    SumFilter(IsSharedRefFor(t), m)
  }

  function CountAllRefs(state: F, t: int) : nat
  {
    CountSharedRefs(state.sharedState, t)

      + (if (state.exc.ExcPendingAwaitWriteback?
            || state.exc.ExcPending?
            || state.exc.ExcObtained?) && state.exc.t == t
         then 1 else 0)

      + (if (state.read.ReadPendingCounted?
            || state.read.ReadObtained?) && state.read.t == t
         then 1 else 0)
  }

  predicate Inv(state: F)
  {
    && state != unit() ==> (
      && state.central.CentralState?
      && (state.exc.ExcPendingAwaitWriteback? ==>
        && state.read.ReadNone?
        && -1 <= state.exc.t < NUM_THREADS
        && state.exc.b == state.central.stored_value
      )
      && (state.exc.ExcPending? ==>
        && state.read == ReadNone
        && state.writeback.WritebackNone?
        && 0 <= state.exc.visited <= NUM_THREADS
        && -1 <= state.exc.t < NUM_THREADS
        && state.exc.b == state.central.stored_value
      )
      && (state.exc.ExcObtained? ==>
        && state.read == ReadNone
        && state.writeback.WritebackNone?
        && -1 <= state.exc.t < NUM_THREADS
      )
      && (state.writeback.WritebackObtained? ==>
        && state.read == ReadNone
        && state.writeback.b == state.central.stored_value
      )
      && (state.read.ReadPending? ==>
        && state.writeback.WritebackNone?
      )
      && (state.read.ReadPendingCounted? ==>
        && state.writeback.WritebackNone?
        && 0 <= state.read.t < NUM_THREADS
      )
      && (state.read.ReadObtained? ==>
        && 0 <= state.read.t < NUM_THREADS
      )
      //&& (state.stored_value.Some? ==>
      //  state.stored_value.value.is_handle(key)
      //)
      && (forall t | 0 <= t < NUM_THREADS
        :: t in state.refCounts && state.refCounts[t] == CountAllRefs(state, t))

      && (state.central.flag == Unmapped ==>
        && state.writeback.WritebackNone?
        && state.read.ReadNone?
        && state.exc.ExcNone?
      )
      && (state.central.flag == Reading ==>
        && state.read.ReadObtained?
        && state.writeback.WritebackNone?
        && state.writeback.WritebackNone?
      )
      && (state.central.flag == Reading_ExcLock ==>
        && (state.read.ReadPending?
          || state.read.ReadPendingCounted?)
        && state.writeback.WritebackNone?
      )
      && (state.central.flag == Available ==>
        && state.exc.ExcNone?
        && state.read.ReadNone?
        && state.writeback.WritebackNone?
      )
      && (state.central.flag == Writeback ==>
        && state.exc.ExcNone?
        && state.read.ReadNone?
        && state.writeback.WritebackObtained?
      )
      && (state.central.flag == ExcLock_Clean ==>
        && (state.exc.ExcPending? || state.exc.ExcObtained?)
        && state.exc.clean
        && state.writeback.WritebackNone?
      )
      && (state.central.flag == ExcLock_Dirty ==>
        && (state.exc.ExcPending? || state.exc.ExcObtained?)
        && !state.exc.clean
        && state.writeback.WritebackNone?
      )
      && (state.central.flag == Writeback_PendingExcLock ==>
        && state.exc.ExcPendingAwaitWriteback?
        && state.writeback.WritebackObtained?
      )
      && (state.central.flag == PendingExcLock ==>
        && state.exc.ExcPendingAwaitWriteback?
        && state.writeback.WritebackNone?
      )
      && (forall ss: SharedState :: state.sharedState[ss] > 0 ==>
        && 0 <= ss.t < NUM_THREADS
        && (ss.SharedPending2? ==>
          && !state.exc.ExcObtained?
          && !state.read.ReadPending?
          && !state.read.ReadPendingCounted?
          && (state.exc.ExcPending? ==> state.exc.visited <= ss.t)
          && state.central.flag != Unmapped
        )
        && (ss.SharedObtained? ==>
          && ss.b == state.central.stored_value
          && !state.exc.ExcObtained?
          && state.read.ReadNone?
          && state.central.flag != Unmapped
          && (state.exc.ExcPending? ==> state.exc.visited <= ss.t)
        )
      )
    )
  }

  function Interp(a: F) : Base.M
    //requires Inv(a)
  {
    if a == unit() || a.exc.ExcObtained? || !a.read.ReadNone? then (
      Base.unit()
    ) else (
      Base.one(a.central.stored_value)
    )
  }

  function dot3(a: F, b: F, c: F) : F
  requires dot_defined(a, b) && dot_defined(dot(a, b), c)
  {
    dot(dot(a, b), c)
  }

  ////// Handlers

  function CentralHandle(central: CentralState) : F {
    M(central, map[], zero_map(), ExcNone, ReadNone, WritebackNone)
  }

  function RefCount(t: ThreadId, count: nat) : F {
    M(CentralNone, map[t := count], zero_map(), ExcNone, ReadNone, WritebackNone)
  }

  function SharedHandle(ss: SharedState) : F {
    M(CentralNone, map[], unit_fn(ss), ExcNone, ReadNone, WritebackNone)
  }

  function ReadHandle(r: ReadState) : F {
    M(CentralNone, map[], zero_map(), ExcNone, r, WritebackNone)
  }

  function ExcHandle(e: ExcState) : F {
    M(CentralNone, map[], zero_map(), e, ReadNone, WritebackNone)
  }

  function WritebackHandle(wb: WritebackState) : F {
    M(CentralNone, map[], zero_map(), ExcNone, ReadNone, wb)
  }

  ////// Transitions

  predicate TakeWriteback(m: M, m': M)
  {
    && m.central.CentralState?
    && m.central.flag == Available

    && m == CentralHandle(m.central)
    && m' == dot(
      CentralHandle(m.central.(flag := Writeback)),
      WritebackHandle(WritebackObtained(m.central.stored_value))
    )
  }

  lemma TakeWriteback_Preserves(p: M, m: M, m': M)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires TakeWriteback(m, m')
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == Interp(dot(m', p))
  {
    //assert dot(m', p).refCounts == dot(m, p).refCounts;
    assert dot(m', p).sharedState == dot(m, p).sharedState;
    //assert forall t | 0 <= t < NUM_THREADS ::
    //    CountAllRefs(dot(m', p), t) == CountAllRefs(dot(m, p), t);
    /*var state := dot(m', p);
    forall t | 0 <= t <= NUM_THREADS
    ensures t in state.refCounts && state.refCounts[t] == CountAllRefs(state, t)
    {
      assert 
    }*/
  }

  predicate ReleaseWriteback(m: M, m': M)
  {
    && m.central.CentralState?
    && m.writeback.WritebackObtained?

    && m == dot(
      CentralHandle(m.central),
      WritebackHandle(m.writeback)
    )

    && (m.central.flag == Writeback ==>
      m' == CentralHandle(m.central.(flag := Available))
    )
    && (m.central.flag == Writeback_PendingExcLock ==>
      m' == CentralHandle(m.central.(flag := PendingExcLock))
    )
  }

  lemma ReleaseWriteback_Preserves(p: M, m: M, m': M)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires ReleaseWriteback(m, m')
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == Interp(dot(m', p))
  {
    assert m.central.flag == Writeback
        || m.central.flag == Writeback_PendingExcLock;
    assert dot(m', p).sharedState == dot(m, p).sharedState;
  }

  predicate ThreadlessExc(m: M, m': M)
  {
    && m.central.CentralState?
    && (m.central.flag == Available || m.central.flag == Writeback)

    && m == CentralHandle(m.central)
    && m' == dot(
      CentralHandle(m.central.(flag := 
          if m.central.flag == Available then PendingExcLock else Writeback_PendingExcLock)),
      ExcHandle(ExcPendingAwaitWriteback(-1, m.central.stored_value))
    )
  }

  lemma ThreadlessExc_Preserves(p: M, m: M, m': M)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires ThreadlessExc(m, m')
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == Interp(dot(m', p))
  {
    assert dot(m', p).sharedState == dot(m, p).sharedState;
  }

  predicate SharedToExc(m: M, m': M, ss: SharedState)
  {
    && m.central.CentralState?
    && (m.central.flag == Available || m.central.flag == Writeback)
    && ss.SharedObtained?

    && m == dot(
      CentralHandle(m.central),
      SharedHandle(ss)
    )
    && m' == dot(
      CentralHandle(m.central.(flag := 
          if m.central.flag == Available then PendingExcLock else Writeback_PendingExcLock)),
      ExcHandle(ExcPendingAwaitWriteback(ss.t, ss.b))
    )
  }

  lemma SharedToExc_Preserves(p: M, m: M, m': M, ss: SharedState)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires SharedToExc(m, m', ss)
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == Interp(dot(m', p))
  {
    SumFilterSimp<SharedState>();

    assert dot(m', p).refCounts == dot(m, p).refCounts;
    assert forall b | b != ss :: dot(m', p).sharedState[b] == dot(m, p).sharedState[b];
    assert dot(m', p).sharedState[ss] + 1 == dot(m, p).sharedState[ss];
    assert CountAllRefs(dot(m', p), ss.t) == CountAllRefs(dot(m, p), ss.t);
  }

  predicate TakeExcLockFinishWriteback(m: M, m': M, clean: bool)
  {
    && m.central.CentralState?
    && m.exc.ExcPendingAwaitWriteback?
    && m.central.flag != Writeback && m.central.flag != Writeback_PendingExcLock
    && m == dot(
      CentralHandle(m.central),
      ExcHandle(m.exc)
    )
    && m' == dot(
      CentralHandle(m.central.(flag :=
        if clean then ExcLock_Clean else ExcLock_Dirty)),
      ExcHandle(ExcPending(m.exc.t, 0, clean, m.exc.b))
    )
  }

  lemma TakeExcLockFinishWriteback_Preserves(p: M, m: M, m': M, clean: bool)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires TakeExcLockFinishWriteback(m, m', clean)
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == Interp(dot(m', p))
  {
    assert dot(m', p).sharedState == dot(m, p).sharedState;
  }

  predicate TakeExcLockCheckRefCount(m: M, m': M)
  {
    && m.exc.ExcPending?
    && m.exc.visited in m.refCounts
    && 0 <= m.exc.visited < NUM_THREADS

    && var expected_rc := (if m.exc.visited == m.exc.t then 1 else 0);

    && m == dot(
      ExcHandle(m.exc),
      RefCount(m.exc.visited, expected_rc)
    )
    && m' == dot(
      ExcHandle(m.exc.(visited := m.exc.visited + 1)),
      RefCount(m.exc.visited, expected_rc)
    )
  }

  lemma TakeExcLockCheckRefCount_Preserves(p: M, m: M, m': M)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires TakeExcLockCheckRefCount(m, m')
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == Interp(dot(m', p))
  {
    assert dot(m', p).sharedState == dot(m, p).sharedState;
    //assert dot(m, p).refCounts[m.exc.visited] == 0;
    var expected_rc := (if m.exc.visited == m.exc.t then 1 else 0);
    assert CountAllRefs(dot(m, p), m.exc.visited) == expected_rc;
    assert CountSharedRefs(dot(m, p).sharedState, m.exc.visited) == 0;
    UseZeroSum(IsSharedRefFor(m.exc.visited), dot(m, p).sharedState);
  }

  predicate Withdraw_TakeExcLockFinish(m: M, m': M, b: Base.M, b': Base.M)
  {
    && m.exc.ExcPending?
    && m.exc.visited == NUM_THREADS
    && m == ExcHandle(m.exc)
    && m' == ExcHandle(ExcObtained(m.exc.t, m.exc.clean))
    && b == Base.unit()
    && b' == Base.one(m.exc.b)
  }

  lemma Withdraw_TakeExcLockFinish_Preserves(p: M, m: M, m': M, b: Base.M, b': Base.M)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires Withdraw_TakeExcLockFinish(m, m', b, b')
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == b'
  ensures Interp(dot(m', p)) == b
  {
    assert dot(m', p).sharedState == dot(m, p).sharedState;
  }

  predicate Deposit_DowngradeExcLoc(m: M, m': M, b: Base.M, b': Base.M)
  {
    && m.exc.ExcObtained?
    && m.central.CentralState?
    && 0 <= m.exc.t < NUM_THREADS
    && m == dot(
      CentralHandle(m.central),
      ExcHandle(m.exc)
    )
    && Base.is_one(b)
    && m' == dot(
      CentralHandle(m.central
        .(flag := Available)
        .(stored_value := Base.get_one(b))
      ),
      SharedHandle(SharedObtained(m.exc.t, Base.get_one(b)))
    )
    && b' == Base.unit()
  }

  lemma Deposit_DowngradeExcLoc_Preserves(p: M, m: M, m': M, b: Base.M, b': Base.M)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires Deposit_DowngradeExcLoc(m, m', b, b')
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == b'
  ensures Interp(dot(m', p)) == b
  {
    SumFilterSimp<SharedState>();
    var ss := SharedObtained(m.exc.t, Base.get_one(b));
    assert forall b | b != ss :: dot(m', p).sharedState[b] == dot(m, p).sharedState[b];
    assert dot(m', p).sharedState[ss] == dot(m, p).sharedState[ss] + 1;

    var state' := dot(m', p);
    forall ss: SharedState | state'.sharedState[ss] > 0
    ensures 0 <= ss.t < NUM_THREADS
    ensures (ss.SharedObtained? ==> ss.b == state'.central.stored_value)
    {
    }
  }

  predicate Withdraw_Alloc(m: M, m': M, b: Base.M, b': Base.M)
  {
    && m.central.CentralState?
    && m.central.flag == Unmapped
    && m == CentralHandle(m.central)

    && m' == dot(
      CentralHandle(m.central.(flag := Reading_ExcLock)),
      ReadHandle(ReadPending)
    )

    && b == Base.unit()
    && b' == Base.one(m.central.stored_value)
  }

  lemma Withdraw_Alloc_Preserves(p: M, m: M, m': M, b: Base.M, b': Base.M)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires Withdraw_Alloc(m, m', b, b')
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == b'
  ensures Interp(dot(m', p)) == b
  {
    assert dot(m', p).sharedState == dot(m, p).sharedState;
  }

  predicate ReadingIncCount(m: M, m': M, t: int)
  {
    && t in m.refCounts
    && 0 <= t < NUM_THREADS
    && m == dot(
      ReadHandle(ReadPending),
      RefCount(t, m.refCounts[t])
    )
    && m' == dot(
      ReadHandle(ReadPendingCounted(t)),
      RefCount(t, m.refCounts[t] + 1)
    )
  }

  lemma ReadingIncCount_Preserves(p: M, m: M, m': M, t: int)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires ReadingIncCount(m, m', t)
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == Interp(dot(m', p))
  {
    SumFilterSimp<SharedState>();
    assert dot(m', p).sharedState == dot(m, p).sharedState;
    var state := dot(m, p);
    var state' := dot(m', p);
    forall t0 | 0 <= t0 < NUM_THREADS
    ensures t0 in state'.refCounts && state'.refCounts[t0] == CountAllRefs(state', t0)
    {
      if t == t0 {
        assert CountAllRefs(state', t0) == CountAllRefs(state, t0) + 1;
        assert t0 in state'.refCounts && state'.refCounts[t0] == CountAllRefs(state', t0);
      } else{
        assert CountAllRefs(state', t0) == CountAllRefs(state, t0);
        assert t0 in state'.refCounts && state'.refCounts[t0] == CountAllRefs(state', t0);
      }
    }
  }

  predicate ObtainReading(m: M, m': M)
  {
    && m.central.CentralState?
    && m.read.ReadPendingCounted?
    && m == dot(
      CentralHandle(m.central),
      ReadHandle(m.read)
    )
    && m' == dot(
      CentralHandle(m.central.(flag := Reading)),
      ReadHandle(ReadObtained(m.read.t))
    )
  }

  lemma ObtainReading_Preserves(p: M, m: M, m': M)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires ObtainReading(m, m')
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == Interp(dot(m', p))
  {
  }

  predicate Deposit_ReadingToShared(m: M, m': M, b: Base.M, b': Base.M)
  {
    && m.central.CentralState?
    && m.read.ReadObtained?
    && m == dot(
      CentralHandle(m.central),
      ReadHandle(m.read)
    )
    && Base.is_one(b)
    && m' == dot(
      CentralHandle(m.central.(flag := Available).(stored_value := Base.get_one(b))),
      SharedHandle(SharedObtained(m.read.t, Base.get_one(b)))
    )
    && b' == Base.unit()
  }

  lemma Deposit_ReadingToShared_Preserves(p: M, m: M, m': M, b: Base.M, b': Base.M)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires Deposit_ReadingToShared(m, m', b, b')
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == b'
  ensures Interp(dot(m', p)) == b
  {
    SumFilterSimp<SharedState>();
    var state := dot(m, p);
    var state' := dot(m', p);
    forall ss: SharedState | state'.sharedState[ss] > 0
    ensures 0 <= ss.t < NUM_THREADS
    ensures ss.SharedObtained? ==>
          && ss.b == state'.central.stored_value
          && !state'.exc.ExcObtained?
          && (state'.exc.ExcPending? ==> state'.exc.visited <= ss.t)
    {
      if ss.SharedObtained? {
        assert ss.b == state'.central.stored_value;
        assert !state'.exc.ExcObtained?;
        assert (state'.exc.ExcPending? ==> state'.exc.visited <= ss.t);
      }
    }
  }

  predicate SharedIncCount(m: M, m': M, t: int)
  {
    && 0 <= t < NUM_THREADS
    && t in m.refCounts
    && m == RefCount(t, m.refCounts[t])
    && m' == dot(
      RefCount(t, m.refCounts[t] + 1),
      SharedHandle(SharedPending(t))
    )
  }

  lemma SharedIncCount_Preserves(p: M, m: M, m': M, t: int)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires SharedIncCount(m, m', t)
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == Interp(dot(m', p))
  {
    SumFilterSimp<SharedState>();
    var state := dot(m, p);
    var state' := dot(m', p);
    forall t0 | 0 <= t0 < NUM_THREADS
    ensures t0 in state'.refCounts && state'.refCounts[t0] == CountAllRefs(state', t0)
    {
      if t == t0 {
        assert CountSharedRefs(state.sharedState, t) + 1
            == CountSharedRefs(state'.sharedState, t);
        assert CountAllRefs(state, t) + 1
            == CountAllRefs(state', t);
        assert t0 in state'.refCounts && state'.refCounts[t0] == CountAllRefs(state', t0);
      } else {
        assert CountSharedRefs(state.sharedState, t0) == CountSharedRefs(state'.sharedState, t0);
        assert CountAllRefs(state, t0) == CountAllRefs(state', t0);
        assert t0 in state'.refCounts && state'.refCounts[t0] == CountAllRefs(state', t0);
      }
    }
  }

  predicate SharedDecCountPending(m: M, m': M, t: int)
  {
    && 0 <= t < NUM_THREADS
    && t in m.refCounts
    && m == dot(
      RefCount(t, m.refCounts[t]),
      SharedHandle(SharedPending(t))
    )
    && (m.refCounts[t] >= 1 ==>
      m' == RefCount(t, m.refCounts[t] - 1)
    )
  }

  lemma SharedDecCountPending_Preserves(p: M, m: M, m': M, t: int)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires SharedDecCountPending(m, m', t)
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == Interp(dot(m', p))
  {
    var state := dot(m, p);

    SumFilterSimp<SharedState>();

    assert state.refCounts[t] >= 1 by {
      if state.refCounts[t] == 0 {
        assert CountAllRefs(state, t) == 0;
        assert CountSharedRefs(state.sharedState, t) == 0;
        UseZeroSum(IsSharedRefFor(t), state.sharedState);
        assert false;
      }
    }

    var state' := dot(m', p);

    forall t0 | 0 <= t0 < NUM_THREADS
    ensures t0 in state'.refCounts && state'.refCounts[t0] == CountAllRefs(state', t0)
    {
      if t == t0 {
        assert CountSharedRefs(state.sharedState, t)
            == CountSharedRefs(state'.sharedState, t) + 1;
        assert CountAllRefs(state, t)
            == CountAllRefs(state', t) + 1;
        assert t0 in state'.refCounts && state'.refCounts[t0] == CountAllRefs(state', t0);
      } else {
        assert CountSharedRefs(state.sharedState, t0) == CountSharedRefs(state'.sharedState, t0);
        assert CountAllRefs(state, t0) == CountAllRefs(state', t0);
        assert t0 in state'.refCounts && state'.refCounts[t0] == CountAllRefs(state', t0);
      }
    }
  } 

  predicate SharedDecCountObtained(m: M, m': M, t: int, b: Base.G)
  {
    && 0 <= t < NUM_THREADS
    && t in m.refCounts
    && m == dot(
      RefCount(t, m.refCounts[t]),
      SharedHandle(SharedObtained(t, b))
    )
    && (m.refCounts[t] >= 1 ==>
      m' == RefCount(t, m.refCounts[t] - 1)
    )
  }

  lemma SharedDecCountObtained_Preserves(p: M, m: M, m': M, t: int, b: Base.G)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires SharedDecCountObtained(m, m', t, b)
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == Interp(dot(m', p))
  {
    var state := dot(m, p);

    SumFilterSimp<SharedState>();

    assert state.refCounts[t] >= 1 by {
      if state.refCounts[t] == 0 {
        assert CountAllRefs(state, t) == 0;
        assert CountSharedRefs(state.sharedState, t) == 0;
        UseZeroSum(IsSharedRefFor(t), state.sharedState);
        assert false;
      }
    }

    var state' := dot(m', p);

    forall t0 | 0 <= t0 < NUM_THREADS
    ensures t0 in state'.refCounts && state'.refCounts[t0] == CountAllRefs(state', t0)
    {
      if t == t0 {
        assert CountSharedRefs(state.sharedState, t)
            == CountSharedRefs(state'.sharedState, t) + 1;
        assert CountAllRefs(state, t)
            == CountAllRefs(state', t) + 1;
        assert t0 in state'.refCounts && state'.refCounts[t0] == CountAllRefs(state', t0);
      } else {
        assert CountSharedRefs(state.sharedState, t0) == CountSharedRefs(state'.sharedState, t0);
        assert CountAllRefs(state, t0) == CountAllRefs(state', t0);
        assert t0 in state'.refCounts && state'.refCounts[t0] == CountAllRefs(state', t0);
      }
    }
  } 

  predicate SharedCheckExc(m: M, m': M, t: int)
  {
    //&& 0 <= t < NUM_THREADS
    && m.central.CentralState?
    && (m.central.flag == Available
        || m.central.flag == Writeback
        || m.central.flag == Reading)
    && m == dot(
      CentralHandle(m.central),
      SharedHandle(SharedPending(t))
    )
    && m' == dot(
      CentralHandle(m.central),
      SharedHandle(SharedPending2(t))
    )
  }

  lemma SharedCheckExc_Preserves(p: M, m: M, m': M, t: int)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires SharedCheckExc(m, m', t)
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == Interp(dot(m', p))
  {
    SumFilterSimp<SharedState>();

    var state := dot(m, p);
    var state' := dot(m', p);

    assert CountAllRefs(state, t) == CountAllRefs(state', t);
    //assert forall t0 | t0 != t :: CountAllRefs(state, t) == CountAllRefs(state', t);
  }

  predicate SharedCheckReading(m: M, m': M, t: int)
  {
    && 0 <= t < NUM_THREADS
    && m.central.CentralState?
    && m.central.flag != Reading
    && m.central.flag != Reading_ExcLock
    && m == dot(
      CentralHandle(m.central),
      SharedHandle(SharedPending2(t))
    )
    && m' == dot(
      CentralHandle(m.central),
      SharedHandle(SharedObtained(t, m.central.stored_value))
    )
  }

  lemma SharedCheckReading_Preserves(p: M, m: M, m': M, t: int)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires SharedCheckReading(m, m', t)
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == Interp(dot(m', p))
  {
    SumFilterSimp<SharedState>();

    var state := dot(m, p);
    var state' := dot(m', p);

    assert CountAllRefs(state, t) == CountAllRefs(state', t);
    //assert forall t0 | t0 != t :: CountAllRefs(state, t) == CountAllRefs(state', t);
  }

  predicate Deposit_Unmap(m: M, m': M, b: Base.M, b': Base.M)
  {
    && m.exc.ExcObtained?
    && m.exc.t == -1
    && m.central.CentralState?
    && m == dot(
      CentralHandle(m.central),
      ExcHandle(m.exc)
    )
    && Base.is_one(b)
    && m' == CentralHandle(
      m.central.(flag := Unmapped).(stored_value := Base.get_one(b))
    )
    && b' == Base.unit()
  }

  lemma Deposit_Unmap_Preserves(p: M, m: M, m': M, b: Base.M, b': Base.M)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires Deposit_Unmap(m, m', b, b')
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == b'
  ensures Interp(dot(m', p)) == b
  {
    assert dot(m', p).sharedState == dot(m, p).sharedState;
  }

  predicate AbandonExcPending(m: M, m': M)
  {
    && m.exc.ExcPending?
    && m.exc.t == -1
    && m.central.CentralState?
    && m == dot(
      CentralHandle(m.central),
      ExcHandle(m.exc)
    )
    && m' == CentralHandle(m.central.(flag := Available))
  }

  lemma AbandonExcPending_Preserves(p: M, m: M, m': M)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires AbandonExcPending(m, m')
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == Interp(dot(m', p))
  {
    assert dot(m', p).sharedState == dot(m, p).sharedState;
  }

  predicate Deposit_AbandonReadPending(m: M, m': M, b: Base.M, b': Base.M)
  {
    && m.read.ReadPending?
    && m.central.CentralState?
    && m == dot(
      CentralHandle(m.central),
      ReadHandle(m.read)
    )
    && Base.is_one(b)
    && m' == CentralHandle(m.central.(flag := Unmapped).(stored_value := Base.get_one(b)))
    && b' == Base.unit()
  }

  lemma Deposit_AbandonReadPending_Preserves(p: M, m: M, m': M, b: Base.M, b': Base.M)
  requires dot_defined(m, p)
  requires Inv(dot(m, p))
  requires Deposit_AbandonReadPending(m, m', b, b')
  ensures dot_defined(m', p)
  ensures Inv(dot(m', p))
  ensures Interp(dot(m, p)) == b'
  ensures Interp(dot(m', p)) == b
  {
    assert dot(m', p).sharedState == dot(m, p).sharedState;
  }

  ///// 

  datatype InternalStep =
      | TakeWritebackStep
      | ReleaseWritebackStep
      | ThreadlessExcStep
      | SharedToExcStep(ss: SharedState)
      | TakeExcLockFinishWritebackStep(clean: bool)
      | TakeExcLockCheckRefCountStep
      | ReadingIncCountStep(t: int)
      | ObtainReadingStep
      | SharedIncCountStep(t: int)
      | SharedDecCountPendingStep(t: int)
      | SharedDecCountObtainedStep(t: int, b: Base.G)
      | SharedCheckExcStep(t: int)
      | SharedCheckReadingStep(t: int)
      | AbandonExcPendingStep

  datatype CrossStep =
      | Deposit_DowngradeExcLoc_Step
      | Deposit_ReadingToShared_Step
      | Deposit_Unmap_Step
      | Deposit_AbandonReadPending_Step
      | Withdraw_TakeExcLockFinish_Step
      | Withdraw_Alloc_Step

  predicate InternalNextStep(f: F, f': F, step: InternalStep) {
    match step {
      case TakeWritebackStep => TakeWriteback(f, f')
      case ReleaseWritebackStep => ReleaseWriteback(f, f')
      case ThreadlessExcStep => ThreadlessExc(f, f')
      case SharedToExcStep(ss: SharedState) => SharedToExc(f, f', ss)
      case TakeExcLockFinishWritebackStep(clean) => TakeExcLockFinishWriteback(f, f', clean)
      case TakeExcLockCheckRefCountStep => TakeExcLockCheckRefCount(f, f')
      case ReadingIncCountStep(t) => ReadingIncCount(f, f', t)
      case ObtainReadingStep => ObtainReading(f, f')
      case SharedIncCountStep(t) => SharedIncCount(f, f', t)
      case SharedDecCountPendingStep(t) => SharedDecCountPending(f, f', t)
      case SharedDecCountObtainedStep(t, b) => SharedDecCountObtained(f, f', t, b)
      case SharedCheckExcStep(t) => SharedCheckExc(f, f', t)
      case SharedCheckReadingStep(t) => SharedCheckReading(f, f', t)
      case AbandonExcPendingStep => AbandonExcPending(f, f')
    }
  }

  predicate InternalNext(f: F, f': F) {
    exists step :: InternalNextStep(f, f', step)
  }

  predicate CrossNextStep(f: F, f': F, b: Base.M, b': Base.M, step: CrossStep) {
    match step {
      case Deposit_DowngradeExcLoc_Step => Deposit_DowngradeExcLoc(f, f', b, b')
      case Deposit_ReadingToShared_Step => Deposit_ReadingToShared(f, f', b, b')
      case Deposit_Unmap_Step => Deposit_Unmap(f, f', b, b')
      case Deposit_AbandonReadPending_Step => Deposit_AbandonReadPending(f, f', b, b')
      case Withdraw_TakeExcLockFinish_Step => Withdraw_TakeExcLockFinish(f, f', b, b')
      case Withdraw_Alloc_Step => Withdraw_Alloc(f, f', b, b')
    }
  }

  predicate CrossNext(f: F, f': F, b: Base.M, b': Base.M) {
    exists step :: CrossNextStep(f, f', b, b', step)
  }

  lemma interp_unit()
  ensures Inv(unit()) && Interp(unit()) == Base.unit()
  {
  }

  lemma internal_step_preserves_interp(p: F, f: F, f': F)
  //requires InternalNext(f, f')
  //requires dot_defined(f, p)
  //requires Inv(dot(f, p))
  ensures dot_defined(f', p)
  ensures Inv(dot(f', p))
  ensures Interp(dot(f', p)) == Interp(dot(f, p))
  {
    var step :| InternalNextStep(f, f', step);
    match step {
      case TakeWritebackStep => TakeWriteback_Preserves(p, f,f');
      case ReleaseWritebackStep => ReleaseWriteback_Preserves(p, f,f');
      case ThreadlessExcStep => ThreadlessExc_Preserves(p, f,f');
      case SharedToExcStep(ss: SharedState) => SharedToExc_Preserves(p, f,f', ss);
      case TakeExcLockFinishWritebackStep(clean) => TakeExcLockFinishWriteback_Preserves(p, f,f', clean);
      case TakeExcLockCheckRefCountStep => TakeExcLockCheckRefCount_Preserves(p, f,f');
      case ReadingIncCountStep(t) => ReadingIncCount_Preserves(p, f,f', t);
      case ObtainReadingStep => ObtainReading_Preserves(p, f,f');
      case SharedIncCountStep(t) => SharedIncCount_Preserves(p, f,f', t);
      case SharedDecCountPendingStep(t) => SharedDecCountPending_Preserves(p, f,f', t);
      case SharedDecCountObtainedStep(t, b) => SharedDecCountObtained_Preserves(p, f,f', t, b);
      case SharedCheckExcStep(t) => SharedCheckExc_Preserves(p, f,f', t);
      case SharedCheckReadingStep(t) => SharedCheckReading_Preserves(p, f,f', t);
      case AbandonExcPendingStep => AbandonExcPending_Preserves(p, f,f');
    }
  }

  lemma cross_step_preserves_interp(p: F, f: F, f': F, b: Base.M, b': Base.M)
  //requires CrossNext(f, f', b, b')
  //requires dot_defined(f, p)
  //requires Inv(dot(f, p))
  //requires Base.dot_defined(Interp(dot(f, p)), b)
  ensures dot_defined(f', p)
  ensures Inv(dot(f', p))
  ensures Base.dot_defined(Interp(dot(f', p)), b')
  ensures Base.dot(Interp(dot(f', p)), b')
       == Base.dot(Interp(dot(f, p)), b)
  {
    var step :| CrossNextStep(f, f', b, b', step);
    match step {
      case Deposit_DowngradeExcLoc_Step => Deposit_DowngradeExcLoc_Preserves(p, f, f', b, b');
      case Deposit_ReadingToShared_Step => Deposit_ReadingToShared_Preserves(p, f, f', b, b');
      case Deposit_Unmap_Step => Deposit_Unmap_Preserves(p, f, f', b, b');
      case Deposit_AbandonReadPending_Step => Deposit_AbandonReadPending_Preserves(p, f, f', b, b');
      case Withdraw_TakeExcLockFinish_Step => Withdraw_TakeExcLockFinish_Preserves(p, f, f', b, b');
      case Withdraw_Alloc_Step => Withdraw_Alloc_Preserves(p, f, f', b, b');
    }
    Base.commutative(Interp(dot(f, p)), b);
  }

  /*predicate easy_le(a: F, b: F) {
    && (a.central.CentralNone? || a.central == b.central)
    && (forall t :: t in a.refCounts ==> t in b.refCounts && b.refCounts[t] == a.refCounts[t])
    && (forall ss :: a.sharedState[ss] <= b.sharedState[ss])
    && (a.exc.ExcNone? || a.exc == b.exc)
    && (a.read.ReadNone? || a.read == b.read)
    && (a.writeback.WritebackNone? || a.writeback == b.writeback)
  }*/
}

/*module RWLockExtToken refines SimpleExtToken {
  import SEPCM = RWLockSimpleExtPCM
  import opened RWLockExt

  glinear method ReleaseWriteback(central: Token, handle: Token)
  requires central.loc == handle.loc
  requires
    && central.central.CentralState?
    && handle.writeback.WritebackObtained?
    && central == CentralHandle(central.central)
    && handle == WritebackHandle()

}*/

module RWLockSimpleExtPCM refines SimpleExtPCM {
  import SE = RWLock
}

module RWLockExtToken refines SimpleExtToken {
  import SEPCM = RWLockSimpleExtPCM
  import opened RWLock
  import opened Constants

  glinear datatype CentralToken = CentralToken(
    ghost flag: Flag,
    ghost stored_value: Base.G,
    glinear token: Token)
  {
    predicate has_flag(flag: Flag) {
      && this.flag == flag
      && token.val == CentralHandle(CentralState(flag, stored_value))
    }
    predicate is_handle(flag: Flag, stored_value: Base.G) {
      && this.flag == flag
      && this.stored_value == stored_value
      && token.val == CentralHandle(CentralState(flag, stored_value))
    }
  }

  glinear datatype WritebackObtainedToken = WritebackObtainedToken(
    ghost b: Base.Handle,
    glinear token: Token)
  {
    predicate has_state(b: Base.G) {
      && this.b == b
      && token.val == WritebackHandle(WritebackObtained(b))
    }
    predicate is_handle(key: Base.Key) {
      && b.is_handle(key)
      && token.val == WritebackHandle(WritebackObtained(b))
    }
  }

  glinear datatype SharedPendingToken = SharedToken(
    ghost t: ThreadId,
    glinear token: Token)
  {
    predicate is_handle(t: ThreadId) {
      && this.t == t
      && token.val == SharedHandle(SharedPending(t))
    }
  }

  glinear datatype SharedPending2Token = SharedToken(
    ghost t: ThreadId,
    glinear token: Token)
  {
    predicate is_handle(t: ThreadId) {
      && this.t == t
      && token.val == SharedHandle(SharedPending2(t))
    }
  }

  glinear datatype SharedObtainedToken = SharedToken(
    ghost t: ThreadId,
    ghost b: Base.G,
    glinear token: Token)
  {
    predicate is_handle(t: ThreadId, b: Base.G) {
      && this.t == t
      && this.b == b
      && token.val == SharedHandle(SharedObtained(t, b))
    }
  }

  glinear method do_internal_step_1(glinear f: Token,
      ghost f1: F,
      ghost step: InternalStep)
  returns (glinear f': Token)
  requires InternalNextStep(f.val, f1, step)
  ensures f'.loc == f.loc
  ensures f'.val == f1
  {
    assert InternalNext(f.val, f1);
    glinear var f_out := do_internal_step(f, f1);
    f' := f_out;
  }

  glinear method do_internal_step_2(glinear f: Token,
      ghost f1: F, ghost g1: F,
      ghost step: InternalStep)
  returns (glinear f': Token, glinear g': Token)
  requires dot_defined(f1, g1)
  requires InternalNextStep(f.val, dot(f1, g1), step)
  ensures g'.loc == f'.loc == f.loc
  ensures f'.val == f1 && g'.val == g1
  {
    assert InternalNext(f.val, dot(f1, g1));
    glinear var f_out := do_internal_step(f, dot(f1, g1));
    f', g' := split(f_out, f1, g1);
  }

  glinear method do_cross_step_1_withdraw(glinear f: Token,
      ghost f1: F,
      ghost b1: Base.Handle,
      ghost step: CrossStep)
  returns (glinear f': Token, glinear b': Base.Handle)
  requires CrossNextStep(f.val, f1, Base.unit(), Base.one(b1), step)
  requires f.loc.ExtLoc? && f.loc.base_loc == Base.singleton_loc()
  ensures f'.loc == f.loc
  ensures f'.val == f1
  ensures b' == b1
  {
    assert CrossNext(f.val, f1, Base.unit(), Base.one(b1));
    glinear var f_out, b_out := do_cross_step(f, f1, Base.get_unit(Base.singleton_loc()), Base.one(b1));
    f' := f_out;
    b' := Base.unwrap(b_out);
  }

  glinear method do_cross_step_2_withdraw(glinear f: Token,
      ghost f1: F, ghost f2: F,
      ghost b1: Base.Handle,
      ghost step: CrossStep)
  returns (glinear f1': Token, glinear f2': Token, glinear b': Base.Handle)
  requires dot_defined(f1, f2)
  requires CrossNextStep(f.val, dot(f1, f2), Base.unit(), Base.one(b1), step)
  requires f.loc.ExtLoc? && f.loc.base_loc == Base.singleton_loc()
  ensures f1'.loc == f.loc
  ensures f1'.val == f1
  ensures f2'.loc == f.loc
  ensures f2'.val == f2
  ensures b' == b1
  {
    assert CrossNext(f.val, dot(f1, f2), Base.unit(), Base.one(b1));
    glinear var f_out, b_out := do_cross_step(f, dot(f1, f2), Base.get_unit(Base.singleton_loc()), Base.one(b1));
    f1', f2' := split(f_out, f1, f2);
    b' := Base.unwrap(b_out);
  }

  glinear method do_cross_step_1_deposit(glinear f: Token, glinear b: Base.Handle,
      ghost f1: F,
      ghost step: CrossStep)
  returns (glinear f': Token)
  requires CrossNextStep(f.val, f1, Base.one(b), Base.unit(), step)
  requires f.loc.ExtLoc? && f.loc.base_loc == Base.singleton_loc()
  ensures f'.loc == f.loc
  ensures f'.val == f1
  {
    assert CrossNext(f.val, f1, Base.one(b), Base.unit());
    glinear var f_out, b_out := do_cross_step(f, f1, Base.wrap(b), Base.unit());
    f' := f_out;
    Base.dispose(b_out);
  }

  glinear method do_cross_step_2_deposit(glinear f: Token, glinear b: Base.Handle,
      ghost f1: F,
      ghost f2: F,
      ghost step: CrossStep)
  returns (glinear f1': Token, glinear f2': Token)
  requires dot_defined(f1, f2)
  requires CrossNextStep(f.val, dot(f1, f2), Base.one(b), Base.unit(), step)
  requires f.loc.ExtLoc? && f.loc.base_loc == Base.singleton_loc()
  ensures f1'.loc == f2'.loc == f.loc
  ensures f1'.val == f1
  ensures f2'.val == f2
  {
    assert CrossNext(f.val, dot(f1, f2), Base.one(b), Base.unit());
    glinear var f_out, b_out := do_cross_step(f, dot(f1, f2), Base.wrap(b), Base.unit());
    f1', f2' := split(f_out, f1, f2);
    Base.dispose(b_out);
  }

  /*glinear method perform_TakeWriteback(glinear c: CentralToken)
  returns (glinear c': CentralToken, glinear handle': WritebackObtainedToken)
  requires c.has_flag(Available)
  ensures c'.token.loc == handle'.token.loc == c.token.loc
  ensures c'.is_handle(Writeback, c.stored_value)
  ensures handle'.has_state(c.stored_value)
  {
    glinear var c_token;
    glinear match c { case CentralToken(_, _, token) => {c_token := token;} }
    glinear var c'_token, handle'_token := do_internal_step_2(c_token,
        CentralHandle(c_token.val.central.(flag := Writeback)),
        WritebackHandle(WritebackObtained(c_token.val.central.stored_value)),
        TakeWritebackStep);
    c' := CentralToken(c'_token.val.central.flag,
        c'_token.val.central.stored_value, c'_token);
    handle' := WritebackObtainedToken(handle'_token.val.writeback.b, handle'_token);
  }*/

  glinear method perform_TakeWriteback(glinear c: Token)
  returns (glinear c': Token, glinear handle': Token)
  requires var m := c.val;
    && m.central.CentralState?
    && m.central.flag == Available
    && m == CentralHandle(m.central)
  ensures c'.loc == handle'.loc == c.loc
  ensures c'.val == CentralHandle(c.val.central.(flag := Writeback))
  ensures handle'.val == WritebackHandle(WritebackObtained(c.val.central.stored_value))
  {
    c', handle' := do_internal_step_2(c,
        CentralHandle(c.val.central.(flag := Writeback)),
        WritebackHandle(WritebackObtained(c.val.central.stored_value)),
        TakeWritebackStep);
  }

  glinear method pre_ReleaseWriteback(glinear c: Token, glinear handle: Token)
  returns (glinear c': Token, glinear handle': Token)
  requires var m := c.val;
    && m.central.CentralState?
    && m == CentralHandle(m.central)
  requires var m := handle.val;
    && m.writeback.WritebackObtained?
    && m == WritebackHandle(m.writeback)
  requires c.loc == handle.loc
  ensures c.val == c'.val && handle'.val == handle.val
  ensures c.loc == c'.loc && handle'.loc == handle.loc
  ensures c.val.central.flag == Writeback
       || c.val.central.flag == Writeback_PendingExcLock
  {
    glinear var x := SEPCM.join(c, handle);
    c', handle' := SEPCM.split(x, c.val, handle.val);
  }

  glinear method perform_ReleaseWriteback(glinear c: Token, glinear handle: Token)
  returns (glinear c': Token)
  requires var m := c.val;
    && m.central.CentralState?
    && m == CentralHandle(m.central)
  requires var m := handle.val;
    && m.writeback.WritebackObtained?
    && m == WritebackHandle(m.writeback)
  requires c.loc == handle.loc
  ensures c'.loc == c.loc
  ensures c.val.central.flag == Writeback
       || c.val.central.flag == Writeback_PendingExcLock
  ensures c.val.central.flag == Writeback ==>
      c'.val == CentralHandle(c.val.central.(flag := Available))
  ensures c.val.central.flag == Writeback_PendingExcLock ==>
      c'.val == CentralHandle(c.val.central.(flag := PendingExcLock))
  {
    glinear var x := SEPCM.join(c, handle);
    c' := do_internal_step_1(x,
        CentralHandle(c.val.central.(flag :=
            if c.val.central.flag == Writeback then Available else PendingExcLock)),
        ReleaseWritebackStep);
  }

  glinear method perform_ThreadlessExc(glinear c: Token)
  returns (glinear c': Token, glinear handle': Token)
  requires var m := c.val;
    && m.central.CentralState?
    && m.central.flag == Available
    && m == CentralHandle(m.central)
  ensures c'.loc == handle'.loc == c.loc
  ensures c'.val == CentralHandle(c.val.central.(flag :=
      if c.val.central.flag == Available then PendingExcLock else Writeback_PendingExcLock))
  ensures handle'.val == ExcHandle(ExcPendingAwaitWriteback(-1, c.val.central.stored_value))
  {
    c', handle' := do_internal_step_2(c,
        CentralHandle(c.val.central.(flag :=
      if c.val.central.flag == Available then PendingExcLock else Writeback_PendingExcLock)),
      ExcHandle(ExcPendingAwaitWriteback(-1, c.val.central.stored_value)),
        ThreadlessExcStep);
  }

  glinear method perform_SharedToExc(glinear c: Token, glinear handle: Token,
      ghost ss: SharedState)
  returns (glinear c': Token, glinear handle': Token)
  requires ss.SharedObtained?
  requires var m := c.val;
    && m.central.CentralState?
    && (m.central.flag == Available || m.central.flag == Writeback)
    && m == CentralHandle(m.central)
  requires handle.val == SharedHandle(ss)
  requires c.loc == handle.loc
  ensures c'.loc == handle'.loc == c.loc
  ensures c'.val == CentralHandle(c.val.central.(flag := 
          if c.val.central.flag == Available then PendingExcLock else Writeback_PendingExcLock))
  ensures handle'.val == ExcHandle(ExcPendingAwaitWriteback(ss.t, ss.b))
  {
    glinear var x := SEPCM.join(c, handle);
    c', handle' := do_internal_step_2(x,
        CentralHandle(c.val.central.(flag := 
          if c.val.central.flag == Available then PendingExcLock else Writeback_PendingExcLock)),
          ExcHandle(ExcPendingAwaitWriteback(ss.t, ss.b)),
        SharedToExcStep(ss));
  }

  glinear method perform_TakeExcLockFinishWriteback(glinear c: Token, glinear handle: Token, ghost clean: bool)
  returns (glinear c': Token, glinear handle': Token)
  requires var m := c.val;
    && m.central.CentralState?
    && m.central.flag != Writeback && m.central.flag != Writeback_PendingExcLock
    && m == CentralHandle(m.central)
  requires var m := handle.val;
    && m.exc.ExcPendingAwaitWriteback?
    && m == ExcHandle(m.exc)
  requires c.loc == handle.loc
  ensures c.val.central.flag == PendingExcLock
  ensures c'.loc == handle'.loc == c.loc
  ensures c'.val == 
      CentralHandle(c.val.central.(flag :=
        if clean then ExcLock_Clean else ExcLock_Dirty))
  ensures handle'.val == 
      ExcHandle(ExcPending(handle.val.exc.t, 0, clean, handle.val.exc.b))
  {
    glinear var x := SEPCM.join(c, handle);
    c', handle' := do_internal_step_2(x,
      CentralHandle(c.val.central.(flag :=
        if clean then ExcLock_Clean else ExcLock_Dirty)),
      ExcHandle(ExcPending(handle.val.exc.t, 0, clean, handle.val.exc.b)),
        TakeExcLockFinishWritebackStep(clean));
  }

  glinear method perform_TakeExcLockCheckRefCount(glinear handle: Token, glinear rc: Token)
  returns (glinear handle': Token, glinear rc': Token)
  requires var m := handle.val;
    && m.exc.ExcPending?
    && m == ExcHandle(m.exc)
    && 0 <= m.exc.visited < NUM_THREADS
  requires var expected_rc := (if handle.val.exc.visited == handle.val.exc.t then 1 else 0);
    && rc.val == RefCount(handle.val.exc.visited, expected_rc)
  requires rc.loc == handle.loc
  ensures rc'.loc == handle'.loc == rc.loc
  ensures handle'.val == ExcHandle(handle.val.exc.(visited := handle.val.exc.visited + 1))
  ensures rc'.val == rc.val
  {
    glinear var x := SEPCM.join(handle, rc);
    handle', rc' := do_internal_step_2(x,
        ExcHandle(handle.val.exc.(visited := handle.val.exc.visited + 1)),
        rc.val,
        TakeExcLockCheckRefCountStep);
  }

  glinear method perform_ReadingIncCount(glinear handle: Token, glinear rc: Token, ghost t: int)
  returns (glinear handle': Token, glinear rc': Token)
  requires handle.val == ReadHandle(ReadPending)
  requires var m := rc.val;
      && t in m.refCounts
      && 0 <= t < NUM_THREADS
      && m == RefCount(t, m.refCounts[t])
  requires handle.loc == rc.loc
  ensures rc'.loc == handle'.loc == rc.loc
  ensures handle'.val == ReadHandle(ReadPendingCounted(t))
  ensures rc'.val == RefCount(t, rc.val.refCounts[t] + 1)
  {
    glinear var x := SEPCM.join(handle, rc);
    handle', rc' := do_internal_step_2(x,
        ReadHandle(ReadPendingCounted(t)),
        RefCount(t, rc.val.refCounts[t] + 1),
        ReadingIncCountStep(t));
  }

  glinear method perform_ObtainReading(glinear c: Token, glinear handle: Token)
  returns (glinear c': Token, glinear handle': Token)
  requires var m := c.val;
    && m.central.CentralState?
    && m == CentralHandle(m.central)
  requires var m := handle.val;
    && m.read.ReadPendingCounted?
    && m == ReadHandle(m.read)
  requires c.loc == handle.loc
  ensures c.val.central.flag == Reading_ExcLock
  ensures c'.loc == handle'.loc == c.loc
  ensures c'.val == CentralHandle(c.val.central.(flag := Reading))
  ensures handle'.val == ReadHandle(ReadObtained(handle.val.read.t))
  {
    glinear var x := SEPCM.join(c, handle);
    c', handle' := do_internal_step_2(x,
        CentralHandle(c.val.central.(flag := Reading)),
        ReadHandle(ReadObtained(handle.val.read.t)),
        ObtainReadingStep);
  }

  glinear method perform_SharedIncCount(glinear rc: Token, ghost t: int)
  returns (glinear rc': Token, glinear handle': Token)
  requires var m := rc.val;
    && 0 <= t < NUM_THREADS
    && t in m.refCounts
    && m == RefCount(t, m.refCounts[t])
  ensures rc'.loc == handle'.loc == rc.loc
  ensures rc'.val == RefCount(t, rc.val.refCounts[t] + 1)
  ensures handle'.val == SharedHandle(SharedPending(t))
  {
    rc', handle' := do_internal_step_2(rc,
        RefCount(t, rc.val.refCounts[t] + 1),
        SharedHandle(SharedPending(t)),
        SharedIncCountStep(t));
  }

  glinear method pre_SharedDecCountPending(glinear x: Token, ghost t: int)
  returns (glinear x': Token)
  requires t in x.val.refCounts
  requires x.val.sharedState[SharedPending(t)] >= 1
  ensures x.val.refCounts[t] >= 1
  ensures x' == x
  {
    x' := x;
    ghost var p, state := get_completion(inout x');
    var m := x'.val;
    if CountSharedRefs(state.sharedState, t) == 0 {
      assert state.sharedState[SharedPending(t)] >= 1;
      FullMaps.UseZeroSum(IsSharedRefFor(t), state.sharedState);
      assert false;
    }
    assert state.refCounts[t] >= 1;
    assert m.refCounts[t] == state.refCounts[t];
  }

  glinear method perform_SharedDecCountPending(glinear rc: Token, glinear handle: Token, ghost t: int)
  returns (glinear rc': Token)
  requires var m := rc.val;
    && 0 <= t < NUM_THREADS
    && t in m.refCounts
    && m == RefCount(t, m.refCounts[t])
  requires var m := handle.val;
    && m == SharedHandle(SharedPending(t))
  requires rc.loc == handle.loc
  ensures rc'.loc == rc.loc
  ensures rc.val.refCounts[t] >= 1
  ensures rc'.val == RefCount(t, rc.val.refCounts[t] - 1)
  {
    glinear var x := SEPCM.join(rc, handle);
    x := pre_SharedDecCountPending(x, t);
    rc' := do_internal_step_1(x,
        RefCount(t, rc.val.refCounts[t] - 1),
        SharedDecCountPendingStep(t));
  }

  glinear method pre_SharedDecCountObtained(glinear x: Token, ghost t: int, ghost b: Base.G)
  returns (glinear x': Token)
  requires t in x.val.refCounts
  requires x.val.sharedState[SharedObtained(t, b)] >= 1
  ensures x.val.refCounts[t] >= 1
  ensures x' == x
  {
    x' := x;
    ghost var p, state := get_completion(inout x');
    var m := x'.val;
    if CountSharedRefs(state.sharedState, t) == 0 {
      assert state.sharedState[SharedObtained(t, b)] >= 1;
      FullMaps.UseZeroSum(IsSharedRefFor(t), state.sharedState);
      assert false;
    }
    assert state.refCounts[t] >= 1;
    assert m.refCounts[t] == state.refCounts[t];
  }

  glinear method perform_SharedDecCountObtained(glinear rc: Token, glinear handle: Token,
      ghost t: int, ghost b: Base.G)
  returns (glinear rc': Token)
  requires var m := rc.val;
    && 0 <= t < NUM_THREADS
    && t in m.refCounts
    && m == RefCount(t, m.refCounts[t])
  requires var m := handle.val;
    && m == SharedHandle(SharedObtained(t, b))
  requires rc.loc == handle.loc
  ensures rc'.loc == rc.loc
  ensures rc.val.refCounts[t] >= 1
  ensures rc'.val == RefCount(t, rc.val.refCounts[t] - 1)
  {
    glinear var x := SEPCM.join(rc, handle);
    x := pre_SharedDecCountObtained(x, t, b);
    rc' := do_internal_step_1(x,
        RefCount(t, rc.val.refCounts[t] - 1),
        SharedDecCountObtainedStep(t, b));
  }

  glinear method perform_SharedCheckExc(glinear c: Token, glinear handle: Token, ghost t: int)
  returns (glinear c': Token, glinear handle': Token)
  //requires 0 <= t < NUM_THREADS
  requires var m := c.val;
    && m.central.CentralState?
    && (m.central.flag == Available
        || m.central.flag == Writeback
        || m.central.flag == Reading)
    && m == CentralHandle(m.central)
  requires handle.val == SharedHandle(SharedPending(t))
  requires c.loc == handle.loc
  ensures c'.loc == handle'.loc == c.loc
  ensures c'.val == c.val
  ensures handle'.val == SharedHandle(SharedPending2(t))
  {
    glinear var x := SEPCM.join(c, handle);
    c', handle' := do_internal_step_2(x,
        c.val,
        SharedHandle(SharedPending2(t)),
        SharedCheckExcStep(t));
  }

  glinear method perform_SharedCheckReading(glinear c: Token, glinear handle: Token, ghost t: int)
  returns (glinear c': Token, glinear handle': Token)
  requires 0 <= t < NUM_THREADS
  requires var m := c.val;
    && m.central.CentralState?
    && m.central.flag != Reading
    && m.central.flag != Reading_ExcLock
    && m == CentralHandle(m.central)
  requires handle.val == SharedHandle(SharedPending2(t))
  requires c.loc == handle.loc
  ensures c'.loc == handle'.loc == c.loc
  ensures c'.val == c.val
  ensures handle'.val == SharedHandle(SharedObtained(t, c.val.central.stored_value))
  {
    glinear var x := SEPCM.join(c, handle);
    c', handle' := do_internal_step_2(x,
        c.val,
        SharedHandle(SharedObtained(t, c.val.central.stored_value)),
        SharedCheckReadingStep(t));
  }

  glinear method perform_AbandonExcPending(glinear c: Token, glinear handle: Token)
  returns (glinear c': Token)
  requires var m := c.val;
    && m.central.CentralState?
    && m == CentralHandle(m.central)
  requires var m := handle.val;
    && m.exc.ExcPending?
    && m.exc.t == -1
    && m == ExcHandle(m.exc)
  requires c.loc == handle.loc
  ensures c'.loc == c.loc
  ensures c'.val == CentralHandle(c.val.central.(flag := Available))
  {
    glinear var x := SEPCM.join(c, handle);
    c' := do_internal_step_1(x,
        CentralHandle(c.val.central.(flag := Available)),
        AbandonExcPendingStep);
  }

  glinear method perform_Withdraw_TakeExcLockFinish(glinear handle: Token)
  returns (glinear handle': Token, glinear b': Base.Handle)
  requires var m := handle.val;
    && m.exc.ExcPending?
    && m.exc.visited == NUM_THREADS
    && m == ExcHandle(m.exc)
  requires handle.loc.ExtLoc? && handle.loc.base_loc == Base.singleton_loc()
  ensures handle'.val == ExcHandle(ExcObtained(handle.val.exc.t, handle.val.exc.clean))
  ensures b' == handle.val.exc.b
  {
    handle', b' := do_cross_step_1_withdraw(handle,
        ExcHandle(ExcObtained(handle.val.exc.t, handle.val.exc.clean)),
        handle.val.exc.b,
        Withdraw_TakeExcLockFinish_Step);
  }

  glinear method perform_Withdraw_Alloc(glinear c: Token)
  returns (glinear c': Token, glinear handle': Token, glinear b': Base.Handle)
  requires var m := c.val;
    && m.central.CentralState?
    && m.central.flag == Unmapped
    && m == CentralHandle(m.central)
  requires c.loc.ExtLoc? && c.loc.base_loc == Base.singleton_loc()
  ensures handle'.loc == c'.loc == c.loc
  ensures c'.val == CentralHandle(c.val.central.(flag := Reading_ExcLock))
  ensures handle'.val == ReadHandle(ReadPending)
  ensures b' == c.val.central.stored_value
  {
    c', handle', b' := do_cross_step_2_withdraw(c,
        CentralHandle(c.val.central.(flag := Reading_ExcLock)),
        ReadHandle(ReadPending),
        c.val.central.stored_value,
        Withdraw_Alloc_Step);
  }

  glinear method perform_Deposit_DowngradeExcLoc(
      glinear c: Token, glinear handle: Token, glinear b: Base.Handle)
  returns (glinear c': Token, glinear handle': Token)
  requires var m := c.val;
    && m.central.CentralState?
    && m == CentralHandle(m.central)
  requires var m := handle.val;
    && m.exc.ExcObtained?
    && 0 <= m.exc.t < NUM_THREADS
    && m == ExcHandle(m.exc)
  requires c.loc.ExtLoc? && c.loc.base_loc == Base.singleton_loc()
  requires c.loc == handle.loc
  ensures handle'.loc == c'.loc == c.loc
  ensures c'.val == 
      CentralHandle(c.val.central
        .(flag := Available)
        .(stored_value := b)
      )
  ensures handle'.val ==
      SharedHandle(SharedObtained(handle.val.exc.t, b))
  {
    glinear var x := SEPCM.join(c, handle);
    c', handle' := do_cross_step_2_deposit(x, b,
      CentralHandle(c.val.central
        .(flag := Available)
        .(stored_value := b)
      ),
      SharedHandle(SharedObtained(handle.val.exc.t, b)),
        Deposit_DowngradeExcLoc_Step);
  }

  glinear method perform_Deposit_ReadingToShared(
      glinear c: Token, glinear handle: Token, glinear b: Base.Handle)
  returns (glinear c': Token, glinear handle': Token)
  requires var m := c.val;
    && m.central.CentralState?
    && m == CentralHandle(m.central)
  requires var m := handle.val;
    && m.read.ReadObtained?
    && m == ReadHandle(m.read)
  requires c.loc.ExtLoc? && c.loc.base_loc == Base.singleton_loc()
  requires c.loc == handle.loc
  ensures handle'.loc == c'.loc == c.loc
  ensures c.val.central.flag == Reading
  ensures c'.val == 
      CentralHandle(c.val.central.(flag := Available).(stored_value := b))
  ensures handle'.val ==
      SharedHandle(SharedObtained(handle.val.read.t, b))
  {
    glinear var x := SEPCM.join(c, handle);
    c', handle' := do_cross_step_2_deposit(x, b,
      CentralHandle(c.val.central.(flag := Available).(stored_value := b)),
      SharedHandle(SharedObtained(handle.val.read.t, b)),
        Deposit_ReadingToShared_Step);
  }

  glinear method perform_Deposit_Unmap(
      glinear c: Token, glinear handle: Token, glinear b: Base.Handle)
  returns (glinear c': Token)
  requires var m := c.val;
    && m.central.CentralState?
    && m == CentralHandle(m.central)
  requires var m := handle.val;
    && m.exc.ExcObtained?
    && m.exc.t == -1
    && m == ExcHandle(m.exc)
  requires c.loc.ExtLoc? && c.loc.base_loc == Base.singleton_loc()
  requires c.loc == handle.loc
  ensures c'.loc == c.loc
  ensures c'.val == 
    CentralHandle(
      c.val.central.(flag := Unmapped).(stored_value := b)
    )
  {
    glinear var x := SEPCM.join(c, handle);
    c' := do_cross_step_1_deposit(x, b,
      CentralHandle(
        c.val.central.(flag := Unmapped).(stored_value := b)
      ),
        Deposit_Unmap_Step);
  }

  glinear method perform_Deposit_AbandonReadPending(
      glinear c: Token, glinear handle: Token, glinear b: Base.Handle)
  returns (glinear c': Token)
  requires var m := c.val;
    && m.central.CentralState?
    && m == CentralHandle(m.central)
  requires var m := handle.val;
    && m.read.ReadPending?
    && m == ExcHandle(m.exc)
  requires c.loc.ExtLoc? && c.loc.base_loc == Base.singleton_loc()
  requires c.loc == handle.loc
  ensures c'.loc == c.loc
  ensures c'.val == 
    CentralHandle(c.val.central.(flag := Unmapped).(stored_value := b))
  {
    glinear var x := SEPCM.join(c, handle);
    c' := do_cross_step_1_deposit(x, b,
        CentralHandle(c.val.central.(flag := Unmapped).(stored_value := b)),
        Deposit_AbandonReadPending_Step);
  }

  /*lemma impl_le()
  ensures forall a: M, b: SEPCM.M {:trigger SEPCM.le(a, b)}
      :: easy_le(a, b) ==> SEPCM.Valid(a) && SEPCM.le(a, b)
  {
    forall a: M, b: SEPCM.M | easy_le(a, b)
    ensures SEPCM.Valid(a) && SEPCM.le(a, b)
    {
      var t := M(
        if a.central.CentralNone? then b.central else CentralNone,
        (map t | t in b.refCounts && t !in a.refCounts :: b.refCounts[t]),
        FullMaps.sub_fns(b.sharedState, a.sharedState),
        if a.exc.ExcNone? then b.exc else ExcNone,
        if a.read.ReadNone? then b.read else ReadNone,
        if a.writeback.WritebackNone? then b.writeback else WritebackNone
      );
      assert dot_defined(a, t);
      assert dot(a, t) == b by {
        assert dot(a, t).central == b.central;
        assert dot(a, t).refCounts == b.refCounts;
        assert dot(a, t).sharedState == b.sharedState;
        assert dot(a, t).exc == b.exc;
        assert dot(a, t).read == b.read;
        assert dot(a, t).writeback == b.writeback;
      }
      var a' :| SEPCM.SE.dot_defined(b, a') && SEPCM.SE.Inv(SEPCM.SE.dot(b, a'));
      commutative(a, t);
      SEPCM.SE_assoc_general(t, a, a');
      SEPCM.SE_assoc_general(a, t, a');
      assert SEPCM.SE.Inv(SEPCM.SE.dot(t, SEPCM.SE.dot(a, a')));
      assert SEPCM.dot_defined(a, t);
      assert SEPCM.SE.Inv(SEPCM.SE.dot(a, SEPCM.SE.dot(t, a')));
    }
  }*/

  function method {:opaque} borrow_wb(gshared f: Token) : (gshared b: Base.Handle)
  requires f.loc.ExtLoc?
  requires f.loc.base_loc == Base.singleton_loc()
  requires f.val.writeback.WritebackObtained?
  ensures b == f.val.writeback.b
  {
    ghost var b := Base.one(f.val.writeback.b);
    Base.unwrap_borrow( borrow_back_interp_exact(f, b) )
  }
}
