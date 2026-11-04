package unit.grammar.nativedoor;

/** `DoorRecord`'s writer with the compact writer appending to one buffer, the path of every target the door does not write. */
@:build(anyparse.macro.Build.buildWriter(
	unit.grammar.nativedoor.DoorRecord, unit.grammar.nativedoor.DoorRecordWriteOptions, { direct: true }
)) @:nullSafety(Strict)
class DoorRecordDirectWriter {}
