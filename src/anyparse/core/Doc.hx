package anyparse.core;

/**
	Pretty-printer document IR.

	A `Doc` represents a structured document that the `Renderer` lays out
	within a target line width. The renderer decides for each `Group` whether
	to emit it flat (all `Line` nodes become their flat replacement) or broken
	(all `Line` nodes become real newlines with indentation).

	Based on Wadler's "A prettier printer" with adjustments for strict
	evaluation and Haxe ergonomics.

	Primitives:

	- `Empty`          — nothing.
	- `Text(s)`        — literal string without line breaks.
	- `Line(flat)`     — a potential line break. In flat mode it becomes `flat`
	                     (usually `" "` or `""`); in break mode it becomes a
	                     newline followed by the current indent.
	- `Nest(n, inner)` — increases the current indent by `n` for breaks inside
	                     `inner`.
	- `Group(inner)`   — a unit of fit decision. The renderer measures the flat
	                     width of `inner` and commits to flat if it fits within
	                     the remaining width, otherwise to break.
	- `BodyGroup(inner)` — structurally identical to `Group` but marks a
	                     "body-level" fit decision emitted by
	                     `WriterLowering.bodyPolicyWrap`'s `FitLine` branch.
	                     The trivia writer's trailing-comment folder looks
	                     specifically for `BodyGroup` when splicing a
	                     trailing line comment into the body's measured
	                     content so the Group's flat/break decision
	                     accounts for the trailing comment width. Renderer
	                     and `fitsFlat` treat `BodyGroup` identically to
	                     `Group` — the distinction exists only as a
	                     semantic marker for consumer-side Doc surgery.
	- `Concat(items)`  — sequential concatenation.
	- `IfBreak(br, fl)`— emit `br` if the enclosing Group is in break mode,
	                     `fl` if in flat mode. Used for trailing separators
	                     that should appear only when the list breaks.

	See `D` for builder helpers and `Renderer` for the layout algorithm.
**/
enum Doc {
	Empty;
	Text(s:String);
	Line(flat:String);
	Nest(indent:Int, inner:Doc);
	Group(inner:Doc);
	BodyGroup(inner:Doc);
	Concat(items:Array<Doc>);
	IfBreak(breakDoc:Doc, flatDoc:Doc);
}
