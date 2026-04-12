package anyparse.grammar.haxe;

/**
 * Grammar type for an enum constructor with parameters.
 *
 * Shape: `Name(param1:Type, param2:Type)` — a name followed by a
 * parenthesised, comma-separated list of `HxParam` entries (reuses
 * the same typedef as function parameters).
 *
 * The `@:lead('(') @:trail(')') @:sep(',')` on `params` selects the
 * sep-peek termination mode in `emitStarFieldSteps`: peek close-char
 * for empty list, then sep-separated loop. Zero-param constructors
 * `Ctor()` parse as `params: []`.
 *
 * The trailing semicolon is NOT on this typedef — it lives on the
 * `HxEnumCtor.ParamCtor` enum branch via `@:trail(';')`.
 */
@:peg
typedef HxEnumCtorDecl = {
	var name:HxIdentLit;
	@:lead('(') @:trail(')') @:sep(',') var params:Array<HxParam>;
};
