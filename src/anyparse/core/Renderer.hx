package anyparse.core;

import anyparse.format.IndentChar;

/**
	Layout mode for a `Doc` frame: flat (line breaks become their flat
	replacement) or broken (line breaks become real newlines).
**/
private enum Mode {
	MFlat;
	MBreak;
}

/**
	One frame on the rendering stack. Carries the indent and mode that applies
	to the doc it references.

	When `fillRest != null` the frame is a Fill continuation: the renderer
	resumes a `Doc.Fill` after `items[fillIdx-1]` has finished rendering and
	must decide how to lay out `items[fillIdx]` based on the current column.
	`doc` is `Empty` for these frames.
**/
private class Frame {
	public var indent:Int;
	public var mode:Mode;
	public var doc:Doc;
	public var fillRest:Null<Array<Doc>>;
	public var fillIdx:Int;
	public var fillSep:Null<Doc>;

	public inline function new(indent:Int, mode:Mode, doc:Doc) {
		this.indent = indent;
		this.mode = mode;
		this.doc = doc;
		this.fillRest = null;
		this.fillIdx = 0;
		this.fillSep = null;
	}

	public static inline function fillCont(indent:Int, rest:Array<Doc>, idx:Int, sep:Doc):Frame {
		final f:Frame = new Frame(indent, MBreak, Empty);
		f.fillRest = rest;
		f.fillIdx = idx;
		f.fillSep = sep;
		return f;
	}
}

/**
	Lays out a `Doc` into a string within a target line width.

	Algorithm: a single top-down traversal with an explicit stack. For each
	`Group`, the renderer runs `fitsFlat` — a fast simulation that counts the
	flat width of the group's content — and chooses between flat and broken
	mode based on whether it fits within `width - currentColumn`.

	This is simpler than Wadler's full continuation look-ahead and ignores
	what comes after a group when deciding; in exchange, it is straightforward
	and fast. Multi-group look-ahead can be added later if real-world
	grammars expose it as a problem.
**/
class Renderer {

	/**
		Renders `doc` targeting `width` columns per line.

		Defaults (`Space`, `tabWidth=1`, `lineEnd="\n"`, `finalNewline=false`)
		preserve the behavior of pre-indent-aware callers that just pass
		`render(doc, width)`.

		Indent is emitted lazily: a break-mode `Line` appends `lineEnd` and
		stores the target indent in `pendingIndent`, flushed to the buffer
		only when the next content (Text or flat-mode Line) arrives. If
		another break-mode `Line` fires first, the prior pending indent is
		silently discarded — this is exactly what blank lines need (no
		trailing tabs on empty rows). Same effect every mature pretty-printer
		(prettier, black, rustfmt) achieves with a trailing-whitespace strip
		pass, but in O(1) extra space and a single traversal.

		`trailingWhitespace` inverts that blank-line discard: when `true`,
		a pending indent left by the prior break-mode `Line` is flushed
		before the next `lineEnd` instead of being overwritten, so blank
		rows carry the surrounding block's indent. Opt-in knob driven by
		`WriteOptions.trailingWhitespace` — haxe-formatter's
		`indentation.trailingWhitespace: true` layout.
	**/
	public static function render(
		doc:Doc,
		width:Int,
		indentChar:IndentChar = Space,
		tabWidth:Int = 1,
		lineEnd:String = '\n',
		finalNewline:Bool = false,
		trailingWhitespace:Bool = false
	):String {
		final buf:StringBuf = new StringBuf();
		final stack:Array<Frame> = [new Frame(0, MBreak, doc)];
		var col:Int = 0;
		var pendingIndent:Int = -1;
		var pendingOptSpace:Null<String> = null;
		// Tracks whether the last emitted byte was a hardline `\n`. Set
		// true on every break-mode `Line` / `OptHardline` that actually
		// writes `\n`; cleared on any subsequent non-hardline emit
		// (Text, OptSpace flush, in-flat Line content). `OptHardline`
		// reads this flag to decide whether to drop its `\n` (avoids
		// `\n\n` when two emitters independently push a leading
		// hardline at the same insertion point).
		var lastEmittedWasHardline:Bool = false;
		// Tracks whether the last emitted byte to `buf` was an open
		// delimiter (`(`, `[`, `{`). Set true on Text whose last char
		// is an open delim; cleared on any subsequent emit (Text not
		// ending in delim, Line, OptSpace flush, OptHardline emit, or
		// the new ctor's emit). `OptHardlineSkipAtOpenDelim` reads this
		// to drop its `\n+indent` when wrapped chain content sits
		// directly inside `(`/`[`/`{` so items[0] glues to the open
		// delim. Indent flush (whitespace) does not set the flag — its
		// last byte is a tab/space, not a delim.
		var lastEmittedWasOpenDelim:Bool = false;

		inline function endsWithOpenDelim(s:String):Bool {
			if (s.length == 0) return false;
			final c:Int = StringTools.fastCodeAt(s, s.length - 1);
			return c == '('.code || c == '['.code || c == '{'.code;
		}

		inline function flushOptSpace():Void {
			if (pendingOptSpace != null) {
				if (pendingIndent >= 0) {
					writeIndent(buf, pendingIndent, indentChar, tabWidth);
					pendingIndent = -1;
				}
				buf.add(pendingOptSpace);
				col += pendingOptSpace.length;
				pendingOptSpace = null;
				lastEmittedWasHardline = false;
				lastEmittedWasOpenDelim = false;
			}
		}

		while (stack.length > 0) {
			final f:Frame = stack.pop();
			final fillRest:Null<Array<Doc>> = f.fillRest;
			if (fillRest != null) {
				final fillSep:Doc = f.fillSep;
				final idx:Int = f.fillIdx;
				if (idx < fillRest.length) {
					final fits:Bool = fitsFlat(width - col, f.indent, Concat([fillSep, fillRest[idx]]));
					if (idx + 1 < fillRest.length)
						stack.push(Frame.fillCont(f.indent, fillRest, idx + 1, fillSep));
					stack.push(new Frame(f.indent, MBreak, fillRest[idx]));
					stack.push(new Frame(f.indent, fits ? MFlat : MBreak, fillSep));
				}
				continue;
			}
			switch (f.doc) {
				case Empty:
					// nothing
				case Text(s):
					if (s.length > 0) {
						flushOptSpace();
						if (pendingIndent >= 0) {
							writeIndent(buf, pendingIndent, indentChar, tabWidth);
							pendingIndent = -1;
						}
						buf.add(s);
						col += s.length;
						lastEmittedWasHardline = false;
						lastEmittedWasOpenDelim = endsWithOpenDelim(s);
					}
				case Line(flat):
					if (f.mode == MFlat) {
						flushOptSpace();
						if (flat.length > 0 && pendingIndent >= 0) {
							writeIndent(buf, pendingIndent, indentChar, tabWidth);
							pendingIndent = -1;
						}
						buf.add(flat);
						col += flat.length;
						if (flat.length > 0) {
							lastEmittedWasHardline = false;
							lastEmittedWasOpenDelim = endsWithOpenDelim(flat);
						}
					} else {
						// Break-mode hardline: drop pending OptSpace so the
						// lead's optional trailing space disappears before
						// the newline (no `var x = \n{...}` artifact).
						pendingOptSpace = null;
						if (trailingWhitespace && pendingIndent >= 0) {
							writeIndent(buf, pendingIndent, indentChar, tabWidth);
						}
						buf.add(lineEnd);
						pendingIndent = f.indent;
						col = f.indent;
						lastEmittedWasHardline = true;
						lastEmittedWasOpenDelim = false;
					}
				case OptSpace(s):
					// Defer; flushed by the next Text or in-flat Line, or
					// dropped by the next break-mode Line. Multiple
					// consecutive OptSpace nodes accumulate.
					if (s.length > 0) {
						pendingOptSpace = pendingOptSpace == null ? s : pendingOptSpace + s;
					}
				case OptHardline:
					// Optional break-mode hardline: drop if the previous
					// emit was already a `\n` (collision with sibling
					// hardline at the same insertion point), otherwise
					// emit `\n` + indent like a regular break-mode `Line`.
					// Both branches clear `pendingOptSpace` to mirror
					// real-hardline semantics. Even when dropped, update
					// `pendingIndent` to this node's own indent — the
					// dropping emitter is the "inner" one and its indent
					// is more specific (e.g. objectLit's leftCurly Next
					// inside a wrap-engine-driven multi-arg list).
					pendingOptSpace = null;
					if (lastEmittedWasHardline) {
						pendingIndent = f.indent;
						col = f.indent;
					} else {
						if (trailingWhitespace && pendingIndent >= 0) {
							writeIndent(buf, pendingIndent, indentChar, tabWidth);
						}
						buf.add(lineEnd);
						pendingIndent = f.indent;
						col = f.indent;
						lastEmittedWasHardline = true;
						lastEmittedWasOpenDelim = false;
					}
				case OptHardlineSkipAtOpenDelim:
					// Open-delim-aware leading hardline. Three branches:
					//  1. Last emit was an open delim (`(`/`[`/`{`):
					//     drop the `\n+indent` so items[0] glues to the
					//     open delim. Leave `col` and `pendingIndent`
					//     untouched — the open delim's text already set
					//     col, and the next continuation `\n` (later
					//     break-mode `Line` for items[1]) will set its
					//     own pendingIndent at frame time.
					//     `lastEmittedWasOpenDelim` stays true so a
					//     redundant follow-up of the same ctor (defensive
					//     case) keeps dropping.
					//  2. Last emit was a hardline: mirror `OptHardline`'s
					//     collision drop (update pendingIndent + col to
					//     the more-specific inner indent).
					//  3. Otherwise: emit `\n+indent` like a regular
					//     break-mode `Line`. Used by chain shapes for
					//     the leading `\n` before items[0] in
					//     outer-context cases (`dirty = chain`).
					pendingOptSpace = null;
					if (lastEmittedWasOpenDelim) {
						// drop, leave col / pendingIndent / flags as-is
					} else if (lastEmittedWasHardline) {
						pendingIndent = f.indent;
						col = f.indent;
					} else {
						if (trailingWhitespace && pendingIndent >= 0) {
							writeIndent(buf, pendingIndent, indentChar, tabWidth);
						}
						buf.add(lineEnd);
						pendingIndent = f.indent;
						col = f.indent;
						lastEmittedWasHardline = true;
						lastEmittedWasOpenDelim = false;
					}
				case Nest(n, inner):
					// Indent only matters when observed (i.e. on a hardline
					// in MBreak mode). Skip the bump in MFlat — otherwise a
					// nested Group inside a flat outer Group breaks at the
					// wrong indent (outer-flat-Nest + inner-Nest stacks).
					// haxe-formatter's chained-FitLine layout
					// (`for (...) if (...)\n\t\tbody;`) requires inner-only
					// indent; canonical Wadler cumulative nesting gives
					// outer+inner instead.
					final nextIndent:Int = f.mode == MBreak ? f.indent + n : f.indent;
					stack.push(new Frame(nextIndent, f.mode, inner));
				case Concat(items):
					var i:Int = items.length;
					while (--i >= 0) stack.push(new Frame(f.indent, f.mode, items[i]));
				case Group(inner) | BodyGroup(inner):
					if (fitsFlat(width - col, f.indent, inner)) {
						stack.push(new Frame(f.indent, MFlat, inner));
					} else {
						stack.push(new Frame(f.indent, MBreak, inner));
					}
				case IfBreak(breakDoc, flatDoc):
					stack.push(new Frame(f.indent, f.mode, f.mode == MBreak ? breakDoc : flatDoc));
				case IfWidthExceeds(n, breakDoc, flatDoc):
					// Column-aware probe: rule fires when `col +
					// flatTokenWidth(flatDoc) >= n` (matches the cascade
					// `lineLength >= n` predicate). The width measurement
					// treats forced hardlines as zero width (mirrors
					// `WrapList.flatTokenWidth`'s semantic) — the cascade
					// rule asks "does the natural inline width reach n",
					// not "does the flat shape budget-fit". Plain
					// `fitsFlat` would refuse-to-flatten on any hardline
					// inside flatDoc and incorrectly always pick brk;
					// here a chain-emit shape (OPLAfterFirst, contains
					// `Line('\n')` between operands) gets its real
					// flat-token width back, so cascade rule 5
					// (`itemCount>=4`) can win over rule 2
					// (`lineLength>=140`) when the rendered chain at the
					// current column wouldn't actually overflow.
					//
					// When `col >= n` already, the rule fires regardless
					// of width — short-circuited by the `>=` comparison.
					// The mode is propagated unchanged: this primitive is
					// independent of the enclosing Group's flat/break
					// choice; it answers a separate column-vs-threshold
					// question.
					final crosses:Bool = (col + flatTokenWidth(flatDoc) >= n);
					stack.push(new Frame(f.indent, f.mode, crosses ? breakDoc : flatDoc));
				case IfFirstLineExceeds(n, breakDoc, flatDoc):
					// First-line-aware probe: rule fires when `col +
					// flatTokenWidthFirstLine(flatDoc) >= n`. Differs from
					// `IfWidthExceeds` in measurement semantic — the first-
					// line walk caps at the first forced hardline inside
					// `flatDoc`, so a multi-line subtree whose first line
					// fits stays inline (this branch picks `flatDoc`) even
					// though its total flat width would exceed `n`. Used
					// by `bodyPolicyWrap`'s width-aware path: e.g. `return
					// <multi-line if-expr>` keeps the if-expr's head glued
					// to `return` when the head fits, while subsequent
					// `else` branches keep their own hardlines.
					//
					// Mode propagation matches `IfWidthExceeds` — both
					// primitives answer a column-vs-threshold question
					// independent of the enclosing Group's flat/break
					// choice.
					final firstLineCrosses:Bool = (col + flatTokenWidthFirstLine(flatDoc) >= n);
					stack.push(new Frame(f.indent, f.mode, firstLineCrosses ? breakDoc : flatDoc));
				case IfLineExceeds(n, breakDoc, flatDoc):
					// Line-length-aware probe: rule fires when `col +
					// flatTokenWidth(flatDoc) +
					// flatTokenWidthOfRestStack(stack) >= n`. The third term
					// is a lookahead over the rendering stack from this
					// point forward, summed up to the next forced hardline
					// — captures everything that would land on the SAME
					// rendered line if the flat branch fired here. Closes
					// the Wadler-style local-Group blindspot where an inner
					// `Group(IfBreak)` decides flat even though enclosing
					// expression pushes the line past threshold.
					//
					// Mode propagation matches `IfWidthExceeds` /
					// `IfFirstLineExceeds`: probe is independent of the
					// enclosing Group's flat/break choice. Slice
					// ω-iflineexceeds-infra.
					final lineCrosses:Bool = (col + flatTokenWidth(flatDoc) + flatTokenWidthOfRestStack(stack) >= n);
					stack.push(new Frame(f.indent, f.mode, lineCrosses ? breakDoc : flatDoc));
				case Fill(items, sep):
					if (items.length == 0) {
						// nothing
					} else if (f.mode == MFlat) {
						// All-flat: items joined by sep flat; reverse-push for
						// natural left-to-right pop order.
						var k:Int = items.length;
						while (k > 0) {
							k--;
							stack.push(new Frame(f.indent, MFlat, items[k]));
							if (k > 0) stack.push(new Frame(f.indent, MFlat, sep));
						}
					} else {
						// Per-item fill: push items[0] first, then a FillCont
						// that resumes for items[1..] once item[0]'s frames
						// have drained and `col` reflects the post-item[0]
						// pen position.
						if (items.length > 1)
							stack.push(Frame.fillCont(f.indent, items, 1, sep));
						stack.push(new Frame(f.indent, MBreak, items[0]));
					}
			}
		}

		final out:String = buf.toString();
		if (finalNewline && !StringTools.endsWith(out, lineEnd)) return out + lineEnd;
		return out;
	}

	/**
		Emits `indent` columns worth of leading whitespace. When
		`indentChar=Tab`, this is `floor(indent / tabWidth)` tabs followed
		by `indent mod tabWidth` spaces — in the clean case where every
		`Nest` value is a multiple of `tabWidth`, the remainder is zero
		and output is pure tabs.
	**/
	private static inline function writeIndent(buf:StringBuf, indent:Int, indentChar:IndentChar, tabWidth:Int):Void {
		if (indentChar == Tab && tabWidth > 0) {
			final tabs:Int = Std.int(indent / tabWidth);
			final rem:Int = indent - tabs * tabWidth;
			for (_ in 0...tabs) buf.add('\t');
			for (_ in 0...rem) buf.add(' ');
		} else {
			for (_ in 0...indent) buf.add(' ');
		}
	}

	/**
		Returns `true` if rendering `d` in flat mode at the given indent
		consumes at most `remaining` columns. Used to choose between flat and
		broken layout for a `Group`/`BodyGroup`.
	**/
	static function fitsFlat(remaining:Int, indent:Int, d:Doc):Bool {
		if (remaining < 0) return false;
		final local:Array<Frame> = [new Frame(indent, MFlat, d)];
		var budget:Int = remaining;

		while (local.length > 0 && budget >= 0) {
			final f:Frame = local.pop();
			switch (f.doc) {
				case Empty:
					// nothing
				case Text(s):
					budget -= s.length;
				case Line(flat):
					// A hard line (flat starts with "\n") forces the
					// measurement to refuse flatten regardless of remaining
					// budget — short hardline-bearing content (a switch
					// with one case body) would otherwise pass the budget
					// check by length alone and the parent Group would
					// commit to MFlat, causing the renderer to emit
					// hardlines without any indent. ω-break-group.
					if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code) {
						budget = -1;
						break;
					}
					budget -= flat.length;
				case Nest(n, inner):
					local.push(new Frame(f.indent + n, MFlat, inner));
				case Concat(items):
					var j:Int = items.length;
					while (--j >= 0) local.push(new Frame(f.indent, MFlat, items[j]));
				case Group(inner):
					local.push(new Frame(f.indent, MFlat, inner));
				case BodyGroup(_):
					// Defer nested BodyGroups out of the parent's flat
					// measurement: a child BodyGroup decides its own
					// flat/break independently when the renderer reaches
					// it, so its content must not contribute to the parent
					// Group's fit budget. This is what lets
					// `bodyPolicyWrap`'s chained FitLines (e.g.
					// `forBody=fitLine + ifBody=fitLine`) keep the outer
					// body inline while the inner body breaks — and lets
					// `triviaBlockStarExpr`'s BG-wrapped block bodies sit
					// inside a call arg without forcing the call's parens
					// onto separate lines (ω-break-group).
				case IfBreak(_, flatDoc):
					local.push(new Frame(f.indent, MFlat, flatDoc));
				case IfWidthExceeds(_, _, flatDoc):
					// Forward to flat side: an enclosing Group's flat-width
					// measurement should ignore the column-aware decision.
					// The flat shape is what would render in MFlat — same
					// stable answer the IfBreak forward gives. Keeps wrap-
					// engine width measurements decoupled from threshold
					// probes that fire only at render time.
					local.push(new Frame(f.indent, MFlat, flatDoc));
				case IfFirstLineExceeds(_, _, flatDoc):
					// Same forwarding as `IfWidthExceeds`: enclosing Group's
					// `fitsFlat` measurement uses the flat shape; the first-
					// line probe is a render-time decision, transparent to
					// wrap-engine width measurement.
					local.push(new Frame(f.indent, MFlat, flatDoc));
				case IfLineExceeds(_, _, flatDoc):
					// Mirror `IfWidthExceeds` / `IfFirstLineExceeds`: the
					// rest-of-stack lookahead is a render-time decision.
					// Static `fitsFlat` walks see only the flat shape so
					// enclosing Group budget measurements stay stable.
					local.push(new Frame(f.indent, MFlat, flatDoc));
				case Fill(items, sep):
					// Flat measurement of Fill: items joined by sep flat.
					var k:Int = items.length;
					while (k > 0) {
						k--;
						local.push(new Frame(f.indent, MFlat, items[k]));
						if (k > 0) local.push(new Frame(f.indent, MFlat, sep));
					}
				case OptSpace(s):
					// In flat measurement, OptSpace contributes its length —
					// flat layout always flushes the lead's optional trailing
					// space (the suppression only happens at render time on
					// break-mode `Line`).
					budget -= s.length;
				case OptHardline | OptHardlineSkipAtOpenDelim:
					// Both opt-hardline variants are hardlines by intent
					// and can never flatten. Mirror the `Line('\n')`
					// budget=-1 path: any enclosing Group containing
					// either must commit to MBreak.
					budget = -1;
					break;
			}
		}

		return budget >= 0;
	}

	/**
	 * Walks a `Doc` tree and returns its visible-token width — the same
	 * width the renderer would emit in flat layout if forced hardlines
	 * didn't terminate that mode. Mirror of `WrapList.flatTokenWidth`,
	 * duplicated here to keep `core.Renderer` independent of `format.wrap`.
	 *
	 * Treats forced hardlines (`Line('\n')`, `OptHardline`) as zero width
	 * instead of aborting (which is what `fitsFlat`'s budget walk does).
	 * `BodyGroup` content is deferred (zero width) to mirror
	 * `fitsFlat`'s Departure 2.
	 *
	 * Used exclusively by the `IfWidthExceeds` probe to answer the
	 * cascade rule `lineLength >= n` predicate as `col +
	 * flatTokenWidth(flatDoc) >= n` — natural inline width, hardlines
	 * ignored.
	 */
	static function flatTokenWidth(d:Doc):Int {
		final stack:Array<Doc> = [d];
		var total:Int = 0;
		while (stack.length > 0) {
			final node:Doc = stack.pop();
			switch (node) {
				case Empty | OptHardline | OptHardlineSkipAtOpenDelim:
				case Text(s):
					total += s.length;
				case Line(flat):
					if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code) {
						// Forced hardline contributes 0 to token width.
					} else {
						total += flat.length;
					}
				case Nest(_, inner):
					stack.push(inner);
				case Concat(items):
					var i:Int = items.length;
					while (--i >= 0) stack.push(items[i]);
				case Group(inner):
					stack.push(inner);
				case BodyGroup(_):
					// Defer — BG decides its own flat/break independently.
				case IfBreak(_, flatDoc):
					stack.push(flatDoc);
				case IfWidthExceeds(_, _, flatDoc):
					stack.push(flatDoc);
				case IfFirstLineExceeds(_, _, flatDoc):
					// Mirror `IfWidthExceeds` semantic: descend into the
					// flat side. Chain consumers calling `flatTokenWidth`
					// keep their hardline-ignoring measurement intact —
					// the first-line cap is the renderer-side probe's
					// concern, not the chain cascade's.
					stack.push(flatDoc);
				case IfLineExceeds(_, _, flatDoc):
					// Forward to flat side: rest-of-stack lookahead is a
					// render-time decision (slice ω-iflineexceeds-infra).
					stack.push(flatDoc);
				case Fill(items, sep):
					var k:Int = items.length;
					while (k > 0) {
						k--;
						stack.push(items[k]);
						if (k > 0) stack.push(sep);
					}
				case OptSpace(s):
					total += s.length;
			}
		}
		return total;
	}

	/**
	 * First-line variant of `flatTokenWidth`. Walks the same flat-shape
	 * tree but caps the measurement at the first forced hardline
	 * (`Line('\n')` or `OptHardline`): the running total at that point is
	 * returned and the rest of the tree is ignored. Used exclusively by
	 * the `IfFirstLineExceeds` probe to answer "would the first rendered
	 * line of `flatDoc` exceed `n` columns from the current pen?".
	 *
	 * Departure from `flatTokenWidth`: forced hardlines abort the walk
	 * instead of contributing zero width. `BodyGroup` is still deferred
	 * (zero, no abort) — its content decides its own flat/break later
	 * and cannot be predicted at probe time. `Group` descends as usual;
	 * a forced hardline anywhere in its inner aborts the first-line walk
	 * because such a Group must commit to break mode.
	 *
	 * Stack-based walk — items pushed in reverse so pop order matches
	 * left-to-right traversal. The `aborted` flag short-circuits
	 * remaining work once a hardline is seen.
	 */
	static function flatTokenWidthFirstLine(d:Doc):Int {
		final stack:Array<Doc> = [d];
		var total:Int = 0;
		var aborted:Bool = false;
		while (stack.length > 0 && !aborted) {
			final node:Doc = stack.pop();
			switch (node) {
				case Empty:
				case OptHardline | OptHardlineSkipAtOpenDelim:
					aborted = true;
				case Text(s):
					total += s.length;
				case Line(flat):
					if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code) {
						aborted = true;
					} else {
						total += flat.length;
					}
				case Nest(_, inner):
					stack.push(inner);
				case Concat(items):
					var i:Int = items.length;
					while (--i >= 0) stack.push(items[i]);
				case Group(inner):
					stack.push(inner);
				case BodyGroup(_):
					// Defer — BG decides its own flat/break independently.
				case IfBreak(_, flatDoc):
					stack.push(flatDoc);
				case IfWidthExceeds(_, _, flatDoc):
					stack.push(flatDoc);
				case IfFirstLineExceeds(_, _, flatDoc):
					stack.push(flatDoc);
				case IfLineExceeds(_, _, flatDoc):
					stack.push(flatDoc);
				case Fill(items, sep):
					var k:Int = items.length;
					while (k > 0) {
						k--;
						stack.push(items[k]);
						if (k > 0) stack.push(sep);
					}
				case OptSpace(s):
					total += s.length;
			}
		}
		return total;
	}

	/**
	 * Sums the flat-mode token width of every frame currently on the
	 * rendering stack, walking from top (next to emit) downward, until
	 * a forced hardline is encountered. Hardline detection is mode-aware:
	 * a frame in `MBreak` treats every `Line(_)` as a hardline (the
	 * renderer would emit `\n + indent`); a frame in `MFlat` treats only
	 * `Line(flat)` whose `flat` starts with `\n` (and `OptHardline` /
	 * `OptHardlineSkipAtOpenDelim`) as hardlines. Once a hardline is
	 * hit, the running total is returned and the rest of the stack is
	 * ignored — the lookahead never crosses a line boundary.
	 *
	 * Used exclusively by the `IfLineExceeds` probe to answer "would
	 * the rendered current line, including everything after this
	 * primitive, reach `n` columns?" (slice ω-iflineexceeds-infra).
	 *
	 * Departures from `flatTokenWidth`:
	 *  - frames carry a mode (the mode they were pushed with) so MBreak
	 *    `Line` aborts immediately;
	 *  - nested `Group` content is descended in `MFlat` (static walk
	 *    can't predict the runtime Group decision; flat-side measurement
	 *    matches the cascade rule semantic "if everything stayed flat,
	 *    would the line exceed?");
	 *  - `BodyGroup` is deferred (zero width, no abort) — same Departure 2
	 *    as `fitsFlat`.
	 *
	 * Stack-based walk over a `(doc, mode)` pair list — items pushed in
	 * reverse so pop order matches left-to-right traversal of each
	 * frame's subtree.
	 */
	private static function flatTokenWidthOfRestStack(stack:Array<Frame>):Int {
		var total:Int = 0;
		var aborted:Bool = false;
		var i:Int = stack.length - 1;
		while (i >= 0 && !aborted) {
			final f:Frame = stack[i];
			i--;
			if (f.fillRest != null) {
				// FillCont frame: a `Doc.Fill` resumption point. In MBreak
				// mode (always — FillCont is constructed only for the
				// per-item path), the next emission likely starts with a
				// hardline at the Fill's indent. Treat as a hardline
				// boundary so the lookahead never crosses a Fill
				// continuation. Conservative under-count for the rare case
				// where Fill items still pack flat is acceptable here —
				// chain dispatch sites don't sit inside Fill primitives.
				aborted = true;
				continue;
			}
			final inner:Array<{doc:Doc, mode:Mode}> = [{doc: f.doc, mode: f.mode}];
			while (inner.length > 0 && !aborted) {
				final node:{doc:Doc, mode:Mode} = inner.pop();
				switch node.doc {
					case Empty:
					case Text(s):
						total += s.length;
					case Line(flat):
						if (node.mode == MBreak) {
							aborted = true;
						} else if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code) {
							aborted = true;
						} else {
							total += flat.length;
						}
					case Nest(_, innerDoc):
						inner.push({doc: innerDoc, mode: node.mode});
					case Concat(items):
						var k:Int = items.length;
						while (--k >= 0) inner.push({doc: items[k], mode: node.mode});
					case Group(innerDoc):
						// Static walk: descend in MFlat. Runtime Group
						// decision is unknowable here; flat-side measurement
						// matches the cascade rule semantic.
						inner.push({doc: innerDoc, mode: MFlat});
					case BodyGroup(_):
						// Deferred — BG decides own layout (Departure 2).
					case IfBreak(_, flatDoc):
						inner.push({doc: flatDoc, mode: MFlat});
					case IfWidthExceeds(_, _, flatDoc):
						inner.push({doc: flatDoc, mode: MFlat});
					case IfFirstLineExceeds(_, _, flatDoc):
						inner.push({doc: flatDoc, mode: MFlat});
					case IfLineExceeds(_, _, flatDoc):
						inner.push({doc: flatDoc, mode: MFlat});
					case Fill(items, sep):
						var k:Int = items.length;
						while (k > 0) {
							k--;
							inner.push({doc: items[k], mode: MFlat});
							if (k > 0) inner.push({doc: sep, mode: MFlat});
						}
					case OptSpace(s):
						total += s.length;
					case OptHardline | OptHardlineSkipAtOpenDelim:
						aborted = true;
				}
			}
		}
		return total;
	}
}
