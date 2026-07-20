package anyparse.grammar.sexpr;

import anyparse.format.WriteOptions;

/**
 * Writer options for the S-expression `SValue` writer — the base `WriteOptions` with no format-specific additions (the `& {}` keeps a distinct nominal type so the generated writer dispatches on it).
 */
typedef SValueWriteOptions = WriteOptions & {};
