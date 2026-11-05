package dev;

import anyparse.format.WriteOptions;

/** Writer options of `GateRecordWriter`: the base `WriteOptions`, a distinct nominal type so the generated writer dispatches on it. */
typedef GateRecordWriteOptions = WriteOptions & {};
