package unit;

/**
 * Pilot schema for the recursive-typedef JSON path that `apq ast`
 * plans to use. Separate top-level module so the macro pipeline's
 * `optionsComplexType` path resolution does not hit the sub-module
 * gotcha.
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef ApqProbeNode = {
	var kind:String;
	@:optional var name:String;
	var children:Array<ApqProbeNode>;
};
