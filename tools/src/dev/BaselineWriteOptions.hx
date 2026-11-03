package dev;

import anyparse.format.WriteOptions;

/** Writer options for `BaselineWriter`: the base `WriteOptions`, a distinct nominal type so the generated writer dispatches on it. */
typedef BaselineWriteOptions = WriteOptions & {};
