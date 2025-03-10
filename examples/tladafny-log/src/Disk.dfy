// Copyright 2018-2021 VMware, Inc., Microsoft Inc., Carnegie Mellon University, ETH Zurich, and University of Washington
// SPDX-License-Identifier: BSD-2-Clause

module Disk {
  datatype DiskOp<LBA(==), Sector> =
    | WriteOp(lba: LBA, sector: Sector)
    | ReadOp(lba: LBA, sector: Sector)
    | NoDiskOp

  datatype Constants = Constants()
  datatype Variables<LBA, Sector> = Variables(blocks: map<LBA, Sector>)

  datatype Step =
    | WriteStep
    | ReadStep
    | StutterStep

  predicate Write(k: Constants, s: Variables, s': Variables, dop: DiskOp) {
    && dop.WriteOp?
    && s'.blocks == s.blocks[dop.lba := dop.sector]
  }

  predicate Read(k: Constants, s: Variables, s': Variables, dop: DiskOp) {
    && dop.ReadOp?
    && s' == s
    && dop.lba in s.blocks && s.blocks[dop.lba] == dop.sector
  }

  predicate Stutter(k: Constants, s: Variables, s': Variables, dop: DiskOp) {
    && dop.NoDiskOp?
    && s' == s
  }

  predicate NextStep(k: Constants, s: Variables, s': Variables, dop: DiskOp, step: Step) {
    match step {
      case WriteStep => Write(k, s, s', dop)
      case ReadStep => Read(k, s, s', dop)
      case StutterStep => Stutter(k, s, s', dop)
    }
  }

  predicate Next(k: Constants, s: Variables, s': Variables, dop: DiskOp) {
    exists step :: NextStep(k, s, s', dop, step)
  }
}
