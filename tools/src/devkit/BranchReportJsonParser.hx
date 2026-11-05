package devkit;

/** Marker class for the macro-generated parser of `BranchReportJson`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(devkit.BranchReportJson))
@:nullSafety(Strict)
class BranchReportJsonParser {}
