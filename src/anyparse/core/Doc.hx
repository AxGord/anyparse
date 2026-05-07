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
	- `IfWidthExceeds(n, br, fl)` — column-aware sibling of `IfBreak`. At
	                     render time, the renderer probes whether the
	                     current column plus `flatWidth(fl)` reaches `n`.
	                     If yes → emit `br`; else → `fl`. Independent of
	                     the surrounding Group's flat/break mode. Used by
	                     `WrapList.emit` to honour `LineLengthLargerThan`
	                     cascade conditions whose threshold differs from
	                     `WriteOptions.lineWidth` (the standard `IfBreak`
	                     pivot) — e.g. opBool's `lineLength >= 140` when
	                     `maxLineLength = 160`. For threshold equal to
	                     `lineWidth`, prefer `IfBreak` (cheaper, no per-
	                     primitive column probe). `fitsFlat` (used by
	                     enclosing `Group` measurement) forwards to `fl`
	                     so flat-mode width estimation stays stable
	                     regardless of the column-aware decision.
	- `IfFirstLineExceeds(n, br, fl)` — first-line-aware sibling of
	                     `IfWidthExceeds`. Probes `col + firstLineWidth(fl)`
	                     against `n` instead of total flat width: forced
	                     hardlines inside `fl` cap the measurement at the
	                     first line rather than collapsing to zero. Used
	                     when the layout decision depends on whether the
	                     first rendered line of a multi-line subtree
	                     overflows — e.g. `return <multi-line if-expr>`
	                     wants the if-expr's HEAD inline with `return`
	                     when the head fits, even though subsequent
	                     branches break. The full-width sibling
	                     `IfWidthExceeds` answers "would the whole flat
	                     subtree fit", which over-fires for multi-line
	                     bodies; this sibling answers "would the first
	                     rendered line fit", matching haxe-formatter's
	                     `sameLine.returnBody: same` semantics. Group's
	                     `fitsFlat` forwards to `fl` (same as
	                     `IfWidthExceeds`) so chain consumers' cascade
	                     semantic stays unchanged.
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
	- `OptSpace(s)`    — optional inline whitespace, dropped when
	                     immediately followed by a break-mode `Line`
	                     (hardline). Used by lead emission to keep the
	                     "lead literal + trailing space" pair byte-
	                     identical when the value lays out flat, but
	                     suppress the trailing space when the value
	                     emits a leading hardline (e.g. `leftCurly=Next`
	                     on an object literal). Treated as `Text(s)` for
	                     flat-mode `fitsFlat` measurement so wrapping
	                     decisions don't shift. Renderer holds OptSpace
	                     in a small pending buffer; it's flushed before
	                     any `Text` (or in-flat `Line`) and discarded
	                     right before a break-mode `Line` writes the
	                     newline. At end of render any unflushed
	                     OptSpace is silently dropped (no trailing
	                     whitespace at EOF).
	- `OptHardline`    — optional break-mode newline, dropped when the
	                     last emit was already a hardline (`Line('\n')`
	                     or another `OptHardline`). Used to coordinate
	                     between two independent emitters that each want
	                     a leading newline at the same insertion point —
	                     e.g. wrap-engine sep `\n` between call args
	                     followed by the next arg's `leftCurly=Next`
	                     leading `\n`. Without `OptHardline` the two
	                     hardlines collide and produce `\n\n` (a
	                     spurious blank line). Like `Line('\n')`, it
	                     forces `fitsFlat` to refuse flatten — never
	                     fits in flat mode. The dropped variant still
	                     updates `pendingIndent` to the OptHardline's
	                     own indent, so the next `Text` lands at the
	                     more-specific (inner) position. Intentional
	                     blank lines must use plain `Line('\n')` pairs;
	                     OptHardline is opt-in at the producer site.
	- `OptHardlineSkipAtOpenDelim` — break-mode newline that drops when
	                     the last emitted byte is an open delimiter
	                     (`(`, `[`, `{`), or a prior hardline (mirrors
	                     `OptHardline`'s collision drop). Used by chain
	                     shapes (`BinaryChainEmit.shapeOnePerLine`) for
	                     the leading hardline before items[0]: keeps
	                     the chain's first operand glued to the
	                     enclosing open delim (`(items[0]...`) while
	                     still emitting `\n+indent` in outer-context
	                     cases (`dirty = chain`, `return chain`) where
	                     the previous byte is `=` / `n` / etc. Like
	                     `Line('\n')` and `OptHardline`, forces
	                     `fitsFlat` to refuse flatten so the enclosing
	                     Group commits MBreak. The dropped variant
	                     updates `pendingIndent` to the node's own
	                     indent so following `Text` lands at the
	                     correct column.

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
	IfWidthExceeds(n:Int, breakDoc:Doc, flatDoc:Doc);
	IfFirstLineExceeds(n:Int, breakDoc:Doc, flatDoc:Doc);
	Fill(items:Array<Doc>, sep:Doc);
	OptSpace(s:String);
	OptHardline;
	OptHardlineSkipAtOpenDelim;
}
