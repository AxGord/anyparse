package unit.grammar.writeshape;

/** `WriteShapeList`'s writer with the compact writer appending to one buffer, the path of every target the door does not write. */
@:build(anyparse.macro.Build.buildWriter(
	unit.grammar.writeshape.WriteShapeList, unit.grammar.writeshape.WriteShapeWriteOptions, { direct: true }
)) @:nullSafety(Strict)
class WriteShapeListDirectWriter {}
