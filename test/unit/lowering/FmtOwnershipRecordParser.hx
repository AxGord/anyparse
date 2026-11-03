package unit.lowering;

/** Marker class for the macro-generated parser of `FmtOwnershipRecord`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(unit.lowering.FmtOwnershipRecord))
@:nullSafety(Strict)
class FmtOwnershipRecordParser {}
