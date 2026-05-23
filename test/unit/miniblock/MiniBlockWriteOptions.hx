package unit.miniblock;

import anyparse.format.WriteOptions;

/**
 * Write options for the `MiniBlock` pilot writer. No grammar-specific
 * knobs needed — pure pass-through to the base `WriteOptions`.
 */
typedef MiniBlockWriteOptions = WriteOptions & {};
