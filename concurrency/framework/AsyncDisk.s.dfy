include "../../lib/Lang/NativeTypes.s.dfy"
include "StateMachines.s.dfy"

module DiskIfc refines Ifc {
  import opened NativeTypes
  import opened RequestIds

  datatype ReqRead = ReqRead(addr: int, len: int)
  datatype ReqWrite = ReqWrite(addr: int, bytes: seq<byte>)
  datatype RespRead = RespRead(addr: int, bytes: seq<byte>)
  datatype RespWrite = RespWrite(addr: int, len: int)

  datatype DiskOp =
    | ReqReadOp(id: RequestId, reqRead: ReqRead)
    | ReqWriteOp(id: RequestId, reqWrite: ReqWrite)
    | RespReadOp(id: RequestId, respRead: RespRead)
    | RespWriteOp(id: RequestId, respWrite: RespWrite)

  type Op = DiskOp
}

module AsyncDisk refines StateMachine(DiskIfc) {
  import opened NativeTypes
  import opened DiskIfc
  import opened RequestIds

  datatype Variables = Variables(
    // Queue of requests and responses:
    reqReads: map<RequestId, ReqRead>,
    reqWrites: map<RequestId, ReqWrite>,
    respReads: map<RequestId, RespRead>,
    respWrites: map<RequestId, RespWrite>,

    // The disk:
    contents: seq<byte>
  )

  predicate Init(s: Variables)
  {
    && s.reqReads == map[]
    && s.reqWrites == map[]
    && s.respReads == map[]
    && s.respWrites == map[]
  }

  datatype Step =
    | RecvReadStep
    | RecvWriteStep
    | AckReadStep
    | AckWriteStep

  predicate RecvRead(s: Variables, s': Variables, dop: DiskOp)
  {
    && dop.ReqReadOp?
    && dop.id !in s.reqReads
    && dop.id !in s.respReads
    && s' == s.(reqReads := s.reqReads[dop.id := dop.reqRead])
  }

  predicate RecvWrite(s: Variables, s': Variables, dop: DiskOp)
  {
    && dop.ReqWriteOp?
    && dop.id !in s.reqWrites
    && dop.id !in s.respWrites
    && s' == s.(reqWrites := s.reqWrites[dop.id := dop.reqWrite])
  }

  predicate AckRead(s: Variables, s': Variables, dop: DiskOp)
  {
    && dop.RespReadOp?
    && dop.id in s.respReads
    && s.respReads[dop.id] == dop.respRead
    && s' == s.(respReads := s.respReads - {dop.id})
  }

  predicate AckWrite(s: Variables, s': Variables, dop: DiskOp)
  {
    && dop.RespWriteOp?
    && dop.id in s.respWrites
    && s.respWrites[dop.id] == dop.respWrite
    && s' == s.(respWrites := s.respWrites - {dop.id})
  }

  predicate NextStep(s: Variables, s': Variables, dop: DiskOp, step: Step) {
    match step {
      case RecvReadStep => RecvRead(s, s', dop)
      case RecvWriteStep => RecvWrite(s, s', dop)
      case AckReadStep => AckRead(s, s', dop)
      case AckWriteStep => AckWrite(s, s', dop)
    }
  }

  predicate Next(s: Variables, s': Variables, op: ifc.Op) {
    exists step :: NextStep(s, s', op, step)
  }

  datatype InternalStep =
    | ProcessReadStep(id: RequestId)
    | ProcessWriteStep(id: RequestId)
    | HavocConflictingWritesStep(id: RequestId, id': RequestId)
    | HavocConflictingWriteReadStep(id: RequestId, id': RequestId)

  predicate ProcessRead(s: Variables, s': Variables, id: RequestId)
  {
    && id in s.reqReads
    && var req := s.reqReads[id];
    && 0 <= req.addr as int <= req.addr as int + req.len as int <= |s.contents|
    && s' == s.(reqReads := s.reqReads - {id})
              .(respReads := s.respReads[id := RespRead(req.addr, s.contents[req.addr .. req.addr as int + req.len as int])])
  }

  function {:opaque} splice(bytes: seq<byte>, start: int, ins: seq<byte>) : seq<byte>
  requires 0 <= start
  requires start + |ins| <= |bytes|
  {
    bytes[.. start] + ins + bytes[start + |ins| ..]
  }

  predicate ProcessWrite(s: Variables, s': Variables, id: RequestId)
  {
    && id in s.reqWrites
    && var req := s.reqWrites[id];
    && 0 <= req.addr
    && |req.bytes| < 0x1_0000_0000_0000_0000
    && req.addr as int + |req.bytes| <= |s.contents|
    && s' == s.(reqWrites := s.reqWrites - {id})
              .(respWrites := s.respWrites[id := RespWrite(req.addr, |req.bytes| as int)])
              .(contents := splice(s.contents, req.addr as int, req.bytes))
  }

  // We assume the disk makes ABSOLUTELY NO GUARANTEES about what happens
  // when there are conflicting reads or writes.

  predicate overlap(start: int, len: int, start': int, len': int)
  {
    && start + len > start'
    && start' + len' > start
  }

  predicate HavocConflictingWrites(s: Variables, s': Variables, id: RequestId, id': RequestId)
  {
    && id != id'
    && id in s.reqWrites
    && id' in s.reqWrites
    && overlap(
        s.reqWrites[id].addr as int, |s.reqWrites[id].bytes|,
        s.reqWrites[id'].addr as int, |s.reqWrites[id'].bytes|)
  }

  predicate HavocConflictingWriteRead(s: Variables, s': Variables, id: RequestId, id': RequestId)
  {
    && id in s.reqWrites
    && id' in s.reqReads
    && overlap(
        s.reqWrites[id].addr as int, |s.reqWrites[id].bytes|,
        s.reqReads[id'].addr as int, s.reqReads[id'].len as int)
  }

  predicate NextInternalStep(s: Variables, s': Variables, step: InternalStep)
  {
    match step {
      case ProcessReadStep(id) => ProcessRead(s, s', id)
      case ProcessWriteStep(id) => ProcessWrite(s, s', id)
      case HavocConflictingWritesStep(id, id') => HavocConflictingWrites(s, s', id, id')
      case HavocConflictingWriteReadStep(id, id') => HavocConflictingWriteRead(s, s', id, id')
    }
  }

  predicate NextInternal(s: Variables, s': Variables)
  {
    exists step :: NextInternalStep(s, s', step)
  }

  predicate Crash(s: Variables, s': Variables)
  {
    s' == Variables(map[], map[], map[], map[], s.contents)
  }
}
