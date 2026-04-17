package anyparse.grammar.haxe;

import anyparse.format.WriteOptions;

/**
 * Write options specific to the Haxe module grammar (`HxModule`).
 *
 * Empty extension in slice σ — the Haxe writer currently needs only the
 * base `WriteOptions` fields. Haxe-specific knobs (same-line policies
 * for `else`/`catch`, trailing-comma policy, etc.) are added to this
 * typedef in later slices as τ₁/τ₂ introduce them.
 */
typedef HxModuleWriteOptions = WriteOptions & {};
