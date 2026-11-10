package unit.macro;

/**
 * A second extent shape, C-like: `defined(NAME)` (a blank may follow `defined`), else the rest of the line. Nothing
 * here is Haxe's, so `LineCondScan` proves `Build.buildExtentScan` reads only what a shape declares.
 */
@:peg
enum LineCond {
	@:lead('defined')
	Defined(arg: LineDefinedArg);
	Rest(text: LineRest);
}

/** The parenthesised name after `defined`, with the optional blank before it. */
@:peg
typedef LineDefinedArg = {
	@:optional
	var blank: Null<LineBlank>;
	@:lead('(')
	@:trail(')')
	var names: Array<LineName>;
}

/** Spaces or tabs, never a line break. */
@:re('[ \\t]+')
abstract LineBlank(String) from String to String {}

/** One identifier. */
@:re('[A-Za-z_][A-Za-z0-9_]*')
abstract LineName(String) from String to String {}

/** Everything up to the end of the line. */
@:re('[^\\r\\n]*')
abstract LineRest(String) from String to String {}

/** The reader generated from `LineCond`. */
@:build(anyparse.macro.Build.buildExtentScan(unit.macro.ExtentFixtures.LineCond))
final class LineCondScan {}
