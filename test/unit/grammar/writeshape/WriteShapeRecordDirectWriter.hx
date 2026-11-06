package unit.grammar.writeshape;

/** `WriteShapeRecord`'s writer with the compact writer appending to one buffer, the path of every target the door does not write. */
@:build(anyparse.macro.Build.buildWriter(
	unit.grammar.writeshape.WriteShapeRecord, unit.grammar.writeshape.WriteShapeWriteOptions, { direct: true }
)) @:nullSafety(Strict)
class WriteShapeRecordDirectWriter {}
