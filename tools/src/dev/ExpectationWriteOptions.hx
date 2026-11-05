package dev;

import anyparse.format.WriteOptions;

/** Writer options of `ExpectationWriter`: the base `WriteOptions`, a distinct nominal type so the generated writer dispatches on it. */
typedef ExpectationWriteOptions = WriteOptions & {};
