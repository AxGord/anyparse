package devkit;

import anyparse.format.WriteOptions;

/**
 * Writer options of `BranchReportJsonWriter`: the base `WriteOptions`,
 * a distinct nominal type so the generated writer dispatches on it.
 */
typedef BranchReportJsonWriteOptions = WriteOptions & {};
