package unit.grammar.nativedoor;

/** The compact text of the records under `DoorRawRecord` that have one: `DoorInner`, not the raw root. */
@:build(anyparse.macro.Build.buildCompactWriter(unit.grammar.nativedoor.DoorRawRecord)) @:nullSafety(Strict)
class DoorRawRecordText {}
