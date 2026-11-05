package dev;

/** Marker class for the macro-generated parser of `ReportRecords`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.ReportRecords))
@:nullSafety(Strict)
class ReportRecordsParser {}
