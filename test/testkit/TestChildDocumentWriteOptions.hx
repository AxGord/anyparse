package testkit;

import anyparse.format.WriteOptions;

/**
 * Writer options of `TestChildDocumentWriter`: the base `WriteOptions`,
 * a distinct nominal type so the generated writer dispatches on it.
 */
typedef TestChildDocumentWriteOptions = WriteOptions & {};
