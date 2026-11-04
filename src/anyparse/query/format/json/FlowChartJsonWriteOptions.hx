package anyparse.query.format.json;

import anyparse.format.WriteOptions;

/**
 * Writer options for `FlowChartJsonWriter` — the base `WriteOptions` with no format-specific
 * additions (the `& {}` keeps a distinct nominal type so the generated writer dispatches on it).
 */
typedef FlowChartJsonWriteOptions = WriteOptions & {};
