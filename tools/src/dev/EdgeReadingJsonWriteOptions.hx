package dev;

import anyparse.format.WriteOptions;

/** Writer options of `EdgeReadingJsonWriter`: the base `WriteOptions`, a distinct nominal type so the generated writer dispatches on it. */
typedef EdgeReadingJsonWriteOptions = WriteOptions & {};
