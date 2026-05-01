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
	- `BodyGroup(inner)` — body-level fit decision. Renderer treats
	                     `BodyGroup` identically to `Group` for its own
	                     flat/break choice. `fitsFlat` differs: when
	                     measuring an outer Group that contains a
	                     `BodyGroup`, the BG is DEFERRED — its content does
	                     not contribute to the parent's measurement. The
	                     parent therefore stays inline even when the inner
	                     BG would break, which is what lets a multi-line
	                     block body sit inside a call argument without
	                     forcing the call's `(...)` onto separate lines,
	                     and what lets chained FitLines keep the outer body
	                     inline while the inner body breaks. The trivia
	                     writer's trailing-comment folder looks specifically
	                     for `BodyGroup` when splicing a trailing line
	                     comment.
	- `Concat(items)`  — sequential concatenation.
	- `IfBreak(br, fl)`— emit `br` if the enclosing Group is in break mode,
	                     `fl` if in flat mode. Used for trailing separators
	                     that should appear only when the list breaks.
	- `Fill(items, sep)` — Wadler `fillSep`. In flat mode, emits items
	                     joined by `sep` flat. In break mode, packs items
	                     left-to-right: before each `items[i]` (i > 0),
	                     measures `sep + items[i]` flat from the current
	                     column; if it fits, emits `sep` flat then the
	                     item; if it doesn't fit, emits `sep` in break
	                     mode (so its inner `Line` becomes a hardline at
	                     the Fill's indent) and starts the item on the
	                     new line. Items[0] is always emitted at the
	                     entry column. `BodyGroup` deferral applies inside
	                     per-item flat measurements, so an item containing
	                     a multi-line block body still measures by its
	                     "header" width and packs cleanly with siblings.

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
	Fill(items:Array<Doc>, sep:Doc);
}
