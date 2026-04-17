package anyparse.grammar.json;

import anyparse.format.WriteOptions;

/**
 * Write options specific to the JSON grammar (`JValue`).
 *
 * Empty extension in slice σ — the JSON writer currently needs only the
 * base `WriteOptions` fields. JSON-specific knobs (e.g. trailing-comma
 * policy for JSON5-style output) are added to this typedef in later
 * slices as their use cases arrive.
 */
typedef JValueWriteOptions = WriteOptions & {};
