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
	Classifies the last byte committed to the output buffer. Drives the
	collision/glue decisions made by `OptHardline` and
	`OptHardlineSkipAtOpenDelim` when their `\n+indent` would be redundant
	or would break a deliberate open-delim glue.

	The three states are mutually exclusive — replaces a prior pair of
	parallel `lastEmittedWasHardline`/`lastEmittedWasOpenDelim` Bool flags
	whose mutex was a convention, not type-enforced.

	- `Other` — initial state and after any non-hardline, non-open-delim
	  emit (Text not ending in `(`/`[`/`{`, in-flat `Line` content,
	  `OptSpace` flush). Both opt-hardline ctors emit `\n+indent`.
	- `Hardline` — a `\n` was just written (break-mode `Line`,
	  `OptHardline` emit, or `OptHardlineSkipAtOpenDelim` emit). Both
	  opt-hardline ctors drop their own `\n` (collision avoidance) but
	  may still update `pendingIndent`/`col` to the inner emitter's more-
	  specific indent.
	- `OpenDelim` — last byte is `(`, `[`, or `{`.
	  `OptHardlineSkipAtOpenDelim` drops its `\n+indent` so the next
	  emission glues directly to the open delim (used by chain shapes
	  to honour source `(<chain>` vs `(\n<chain>` distinctions).
**/
private enum LastEmit {
	Other;
	Hardline;
	OpenDelim;
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
	public var fillTailReserve:Int;

	/**
	 * Force-flat propagation flag (ω-force-flat-engine, slice B). When
	 * `true`, the renderer treats every `Group` / `BodyGroup` as if it
	 * had chosen `MFlat` (skipping `fitsFlat`), picks the flat branch of
	 * every `IfBreak` / `If*Exceeds`, collapses `Fill` to a plain sep-
	 * joined emit, drops `OptHardline*` entirely, and renders `Line(flat)`
	 * as plain text regardless of `mode`. Entered via `Doc.Flatten(inner)`;
	 * reset via `Doc.WrapBoundary(inner)` so nested wrap-cascade outputs
	 * decide independently inside a parent's force-flat region. Default
	 * `false` keeps every existing call-site unchanged.
	 */
	public var forceFlat:Bool;

	public inline function new(indent:Int, mode:Mode, doc:Doc, forceFlat:Bool = false) {
		this.indent = indent;
		this.mode = mode;
		this.doc = doc;
		this.forceFlat = forceFlat;
		this.fillRest = null;
		this.fillIdx = 0;
		this.fillSep = null;
		this.fillTailReserve = 0;
	}

	public static inline function fillCont(indent:Int, rest:Array<Doc>, idx:Int, sep:Doc, tailReserve:Int, forceFlat:Bool = false):Frame {
		final f:Frame = new Frame(indent, MBreak, Empty, forceFlat);
		f.fillRest = rest;
		f.fillIdx = idx;
		f.fillSep = sep;
		f.fillTailReserve = tailReserve;
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
		trailingWhitespace:Bool = false,
		maxConsecutiveBlanks:Int = -1
	):String {
		final buf:StringBuf = new StringBuf();
		final stack:Array<Frame> = [new Frame(0, MBreak, doc)];
		var col:Int = 0;
		var pendingIndent:Int = -1;
		var pendingOptSpace:Null<String> = null;
		// Three-state classifier of the last byte committed to `buf`.
		// Drives `OptHardline` collision drop and
		// `OptHardlineSkipAtOpenDelim` open-delim glue. See `LastEmit`
		// docblock for state transitions; semantics replace a prior
		// pair of parallel `lastEmittedWas{Hardline,OpenDelim}` Bools
		// whose mutex was conventional, not type-enforced.
		var lastEmit:LastEmit = Other;

		inline function endsWithOpenDelim(s:String):Bool {
			if (s.length == 0) return false;
			final c:Int = StringTools.fastCodeAt(s, s.length - 1);
			return c == '('.code || c == '['.code || c == '{'.code;
		}

		inline function lastEmitFromText(s:String):LastEmit {
			return endsWithOpenDelim(s) ? OpenDelim : Other;
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
				lastEmit = Other;
			}
		}

		while (stack.length > 0) {
			final f:Frame = stack.pop();
			final fillRest:Null<Array<Doc>> = f.fillRest;
			if (fillRest != null) {
				final fillSep:Doc = f.fillSep;
				final idx:Int = f.fillIdx;
				final tailReserve:Int = f.fillTailReserve;
				if (idx < fillRest.length) {
					// `tailReserve` cols are reserved for post-Fill same-line
					// content (trailing comma + close delim emitted OUTSIDE
					// the Fill — see `Doc.Fill` doc-comment). Subtracting it
					// from the probe budget makes the LAST packed item leave
					// room for that tail, matching fork's `wrapFillLine2AfterLast`
					// `lineLength + tokenLength >= maxLineLength` accounting
					// where each item carries its trailing comma in
					// `firstLineLength` (slice ω-fill-tail-reserve).
					final fits:Bool = fitsFlat(width - col - tailReserve, f.indent, Concat([fillSep, fillRest[idx]]));
					if (idx + 1 < fillRest.length)
						stack.push(Frame.fillCont(f.indent, fillRest, idx + 1, fillSep, tailReserve, f.forceFlat));
					stack.push(new Frame(f.indent, MBreak, fillRest[idx], f.forceFlat));
					stack.push(new Frame(f.indent, fits ? MFlat : MBreak, fillSep, f.forceFlat));
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
						lastEmit = lastEmitFromText(s);
					}
				case Line(flat):
					if (f.forceFlat || f.mode == MFlat) {
						flushOptSpace();
						if (flat.length > 0 && pendingIndent >= 0) {
							writeIndent(buf, pendingIndent, indentChar, tabWidth);
							pendingIndent = -1;
						}
						buf.add(flat);
						col += flat.length;
						if (flat.length > 0) {
							lastEmit = lastEmitFromText(flat);
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
						lastEmit = Hardline;
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
					//
					// Force-flat (slice B): inside a `Flatten(...)` region,
					// every optional hardline is collapsed — `pendingOptSpace`
					// is cleared (mirror real-hardline) but no `\n` is
					// emitted and `pendingIndent`/`col`/`lastEmit` stay put.
					pendingOptSpace = null;
					if (f.forceFlat) {
						// drop entirely
					} else if (lastEmit == Hardline) {
						pendingIndent = f.indent;
						col = f.indent;
					} else {
						if (trailingWhitespace && pendingIndent >= 0) {
							writeIndent(buf, pendingIndent, indentChar, tabWidth);
						}
						buf.add(lineEnd);
						pendingIndent = f.indent;
						col = f.indent;
						lastEmit = Hardline;
					}
				case OptSpaceSkipAfterHardline:
					// Inline single space, dropped when the last emitted
					// output ended with a hardline. Mirror of
					// `OptHardlineSkipAtOpenDelim`'s drop-on-state pattern
					// for the trailing-side. Pending `OptSpace` cleared on
					// drop; on emit, the space prints at the current
					// (post-flush) position via the same `pendingOptSpace`
					// channel as `OptSpace(' ')` would, so the flat-mode
					// `Line(' ')` collapse ordering still holds.
					//
					// Force-flat (slice B): inside a `Flatten(...)` region,
					// every preceding `OptHardline*` was dropped, so a
					// `Hardline` lastEmit can only carry over from OUTSIDE
					// the region. Force the space unconditionally — the
					// drop-on-state semantic is moot inside force-flat.
					if (!f.forceFlat && lastEmit == Hardline) {
						pendingOptSpace = null;
					} else {
						pendingOptSpace = pendingOptSpace == null ? ' ' : pendingOptSpace + ' ';
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
					//     `lastEmit` stays `OpenDelim` so a redundant
					//     follow-up of the same ctor (defensive case)
					//     keeps dropping.
					//  2. Last emit was a hardline: mirror `OptHardline`'s
					//     collision drop (update pendingIndent + col to
					//     the more-specific inner indent).
					//  3. Otherwise: emit `\n+indent` like a regular
					//     break-mode `Line`. Used by chain shapes for
					//     the leading `\n` before items[0] in
					//     outer-context cases (`dirty = chain`).
					//
					// Force-flat (slice B): same drop-entirely behaviour as
					// `OptHardline` — `pendingOptSpace` cleared, no `\n`
					// emitted, surrounding state untouched.
					pendingOptSpace = null;
					if (f.forceFlat) {
						// drop entirely
					} else switch lastEmit {
						case OpenDelim:
							// drop, leave col / pendingIndent / lastEmit as-is
						case Hardline:
							pendingIndent = f.indent;
							col = f.indent;
						case Other:
							if (trailingWhitespace && pendingIndent >= 0) {
								writeIndent(buf, pendingIndent, indentChar, tabWidth);
							}
							buf.add(lineEnd);
							pendingIndent = f.indent;
							col = f.indent;
							lastEmit = Hardline;
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
					stack.push(new Frame(nextIndent, f.mode, inner, f.forceFlat));
				case Concat(items):
					var i:Int = items.length;
					while (--i >= 0) stack.push(new Frame(f.indent, f.mode, items[i], f.forceFlat));
				case Group(inner) | BodyGroup(inner):
					// Force-flat (slice B): skip `fitsFlat` entirely and push
					// the inner as MFlat with `forceFlat=true` propagated.
					// The `Flatten` region committed to flat for the whole
					// subtree at entry — local fit measurement is moot here.
					if (f.forceFlat) {
						stack.push(new Frame(f.indent, MFlat, inner, true));
					} else if (fitsFlat(width - col, f.indent, inner)) {
						stack.push(new Frame(f.indent, MFlat, inner));
					} else {
						stack.push(new Frame(f.indent, MBreak, inner));
					}
				case GroupWithRestProbe(inner):
					// ω-group-rest-probe: Group variant whose fit decision
					// subtracts `flatTokenWidthOfRestStack(stack)` from the
					// budget — same-line content emitted AFTER this Group by
					// parent frames is considered before committing to MFlat.
					// Mirrors fork's `wrapFillLine2AfterLast` `lengthAfter`
					// bias: when significant content trails on the same line
					// (e.g. typedef LHS typeParams followed by ` = RhsType<…>;`
					// on the same line), prefer MBreak over MFlat so the
					// trailing content has room. Sister to `IfLineExceeds`
					// rest-of-stack lookahead — same walker, different
					// consumer (Group-style fit instead of explicit branch).
					if (f.forceFlat) {
						stack.push(new Frame(f.indent, MFlat, inner, true));
					} else {
						final restW:Int = flatTokenWidthOfRestStack(stack);
						if (fitsFlat(width - col - restW, f.indent, inner)) {
							stack.push(new Frame(f.indent, MFlat, inner));
						} else {
							stack.push(new Frame(f.indent, MBreak, inner));
						}
					}
				case IfBreak(breakDoc, flatDoc):
					// Force-flat (slice B): always pick `flatDoc`, propagate
					// `forceFlat=true` so the chosen branch keeps the region
					// semantic for its own descendants.
					final picked:Doc = (f.forceFlat || f.mode == MFlat) ? flatDoc : breakDoc;
					stack.push(new Frame(f.indent, f.mode, picked, f.forceFlat));
				case IfWidthExceeds(n, breakDoc, flatDoc):
					// Column-aware probe: rule fires when `col +
					// DocMeasure.flatTokenWidth(flatDoc) >= n` (matches the
					// cascade `lineLength >= n` predicate). The width
					// measurement treats forced hardlines as zero width —
					// the cascade rule asks "does the natural inline width
					// reach n", not "does the flat shape budget-fit". Plain
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
					if (f.forceFlat) {
						stack.push(new Frame(f.indent, f.mode, flatDoc, true));
					} else {
						final crosses:Bool = (col + DocMeasure.flatTokenWidth(flatDoc) >= n);
						stack.push(new Frame(f.indent, f.mode, crosses ? breakDoc : flatDoc));
					}
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
					if (f.forceFlat) {
						stack.push(new Frame(f.indent, f.mode, flatDoc, true));
					} else {
						final firstLineCrosses:Bool = (col + flatTokenWidthFirstLine(flatDoc) >= n);
						stack.push(new Frame(f.indent, f.mode, firstLineCrosses ? breakDoc : flatDoc));
					}
				case IfLineExceeds(n, breakDoc, flatDoc):
					// Line-length-aware probe: rule fires when `col +
					// DocMeasure.flatTokenWidth(flatDoc) +
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
					if (f.forceFlat) {
						stack.push(new Frame(f.indent, f.mode, flatDoc, true));
					} else {
						final lineCrosses:Bool = (col + DocMeasure.flatTokenWidth(flatDoc) + flatTokenWidthOfRestStack(stack) >= n);
						stack.push(new Frame(f.indent, f.mode, lineCrosses ? breakDoc : flatDoc));
					}
				case IfFullLineExceeds(n, breakDoc, flatDoc):
					// Sibling of `IfLineExceeds` with asymmetric BG
					// semantic: the primitive's own subtree uses the
					// regular `flatTokenWidth` (defers BG — so a lambda
					// body BG inside one of `flatDoc`'s segments stays
					// deferred and doesn't inflate the chain probe),
					// but the rest-of-stack lookahead descends BG via
					// `flatTokenWidthOfRestStackFull` so a sibling body
					// BG that follows on the same source line (e.g.
					// `for (cond) BODY` with `forBody=fitLine` BG-wrap)
					// is visible to the probe. Closes the chain-emit
					// blindspot at `condition_wrapping_method_chain`
					// while avoiding the chain-of-lambdas over-fire
					// (regression class of the symmetric-descend
					// approach). Slice ω-iffulllineexceeds-primitive.
					if (f.forceFlat) {
						stack.push(new Frame(f.indent, f.mode, flatDoc, true));
					} else {
						final fullLineCrosses:Bool = (col + DocMeasure.flatTokenWidth(flatDoc) + flatTokenWidthOfRestStackFull(stack) >= n);
						stack.push(new Frame(f.indent, f.mode, fullLineCrosses ? breakDoc : flatDoc));
					}
				case Fill(items, sep, tailReserveOpt):
					if (items.length == 0) {
						// nothing
					} else if (f.forceFlat || f.mode == MFlat) {
						// All-flat: items joined by sep flat; reverse-push for
						// natural left-to-right pop order. Force-flat (slice B)
						// routes here too — items + sep propagate `forceFlat`
						// so nested wrap markers inside an item stay collapsed.
						var k:Int = items.length;
						while (k > 0) {
							k--;
							stack.push(new Frame(f.indent, MFlat, items[k], f.forceFlat));
							if (k > 0) stack.push(new Frame(f.indent, MFlat, sep, f.forceFlat));
						}
					} else {
						// Per-item fill: push items[0] first, then a FillCont
						// that resumes for items[1..] once item[0]'s frames
						// have drained and `col` reflects the post-item[0]
						// pen position. `tailReserve` (cols of post-Fill
						// same-line content; default 0) rides the FillCont
						// frame and tightens the per-item-fit budget on
						// each subsequent probe — see Fill case at the top
						// of the dispatch loop.
						final tailReserve:Int = tailReserveOpt ?? 0;
						if (items.length > 1)
							stack.push(Frame.fillCont(f.indent, items, 1, sep, tailReserve));
						stack.push(new Frame(f.indent, MBreak, items[0]));
					}
				case Flatten(inner):
					// ω-force-flat-engine slice B: enter force-flat region.
					// Push `inner` with `MFlat` mode and `forceFlat=true` so
					// every descendant Group/IfBreak/Fill/etc. follows the
					// flat dispatch path until a `WrapBoundary` resets the
					// flag (or the subtree drains). Nested `Flatten` is a
					// no-op — pushing `forceFlat=true` when already `true`
					// is idempotent. Note: no emitter constructs `Flatten`
					// yet (slice D opt-in); this arm is exercise-tested
					// only after slice C/D land.
					stack.push(new Frame(f.indent, MFlat, inner, true));
				case WrapBoundary(inner):
					// ω-force-flat-engine slice B: reset force-flat. Push
					// `inner` with the enclosing frame's mode preserved and
					// `forceFlat=false` so nested wrap-cascade outputs
					// evaluate their own conditions independently inside a
					// parent's force-flat region. When the enclosing context
					// did NOT have force-flat active, this is a no-op pass-
					// through (same shape as the prior slice-A arm).
					stack.push(new Frame(f.indent, f.mode, inner, false));
			}
		}

		final raw:String = buf.toString();
		final capped:String = maxConsecutiveBlanks >= 0 ? capConsecutiveBlanks(raw, lineEnd, maxConsecutiveBlanks) : raw;
		if (finalNewline && !StringTools.endsWith(capped, lineEnd)) return capped + lineEnd;
		return capped;
	}

	/**
		Collapses runs of consecutive `lineEnd` sequences down to
		`maxBlanks + 1` line-end occurrences — i.e. at most `maxBlanks`
		blank lines between any two non-empty lines. Drives the haxe-
		formatter `emptyLines.maxAnywhereInFile` knob (fed through
		`WriteOptions.maxConsecutiveBlanks`). With `maxBlanks = 0` the
		output has no blank lines at all; `maxBlanks = 1` allows one
		blank line at most, etc. Single-character `lineEnd` ("\n", "\r")
		and multi-character ("\r\n") are both handled.

		Pre-condition: `maxBlanks >= 0`; the caller guards `< 0` for
		unbounded (no-cap) mode.
	**/
	private static function capConsecutiveBlanks(s:String, lineEnd:String, maxBlanks:Int):String {
		final leLen:Int = lineEnd.length;
		if (leLen == 0) return s;
		final maxRunLen:Int = (maxBlanks + 1) * leLen;
		final buf:StringBuf = new StringBuf();
		final n:Int = s.length;
		var i:Int = 0;
		var segStart:Int = 0;
		while (i < n) {
			if (startsWithAt(s, i, lineEnd)) {
				if (i > segStart) buf.addSub(s, segStart, i - segStart);
				var runEnd:Int = i + leLen;
				while (runEnd <= n - leLen && startsWithAt(s, runEnd, lineEnd))
					runEnd += leLen;
				final runLen:Int = runEnd - i;
				final emitLen:Int = runLen < maxRunLen ? runLen : maxRunLen;
				buf.addSub(s, i, emitLen);
				i = runEnd;
				segStart = i;
			} else {
				i++;
			}
		}
		if (segStart < n) buf.addSub(s, segStart, n - segStart);
		return buf.toString();
	}

	/**
		Returns true iff `s` contains `needle` starting at index `at`.
		Helper for `capConsecutiveBlanks` lineEnd-run detection — operates
		on code-unit boundaries (works for both single-char `\n` / `\r`
		and multi-char `\r\n` line-ends, since the needle is matched
		verbatim).
	**/
	private static function startsWithAt(s:String, at:Int, needle:String):Bool {
		final needleLen:Int = needle.length;
		if (at + needleLen > s.length) return false;
		for (k in 0...needleLen)
			if (StringTools.fastCodeAt(s, at + k) != StringTools.fastCodeAt(needle, k))
				return false;
		return true;
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
				case Group(inner) | GroupWithRestProbe(inner):
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
				case IfFullLineExceeds(_, _, flatDoc):
					// Mirror `IfLineExceeds`: rest-of-stack BG-descend
					// is a render-time decision. `fitsFlat` sees only
					// the flat shape (slice ω-iffulllineexceeds-primitive).
					local.push(new Frame(f.indent, MFlat, flatDoc));
				case Fill(items, sep, _):
					// Flat measurement of Fill: items joined by sep flat.
					// `tailReserve` is a render-time per-item-fit knob, NOT
					// a flat-width adjustment — irrelevant when the enclosing
					// Group asks "does the whole Fill fit on one line".
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
				case OptSpaceSkipAfterHardline:
					// In flat measurement, treat as a single-byte space —
					// the runtime drop only fires when `lastEmit==Hardline`,
					// which by definition cannot happen inside a `fitsFlat`
					// probe (the probe walks pure flat shape).
					budget -= 1;
				case OptHardline | OptHardlineSkipAtOpenDelim:
					// Both opt-hardline variants are hardlines by intent
					// and can never flatten. Mirror the `Line('\n')`
					// budget=-1 path: any enclosing Group containing
					// either must commit to MBreak.
					budget = -1;
					break;
				case Flatten(inner) | WrapBoundary(inner):
					// ω-force-flat-engine slice A: pass-through. Both
					// markers are render-time state, transparent to flat-
					// width measurement — descend `inner` with the same
					// MFlat frame. Slice B's `forceFlat` dispatch lives in
					// `render()`, not in static `fitsFlat` walks.
					local.push(new Frame(f.indent, MFlat, inner));
			}
		}

		return budget >= 0;
	}

	/**
	 * First-line variant of `DocMeasure.flatTokenWidth`. Walks the same flat-shape
	 * tree but caps the measurement at the first forced hardline
	 * (`Line('\n')` or `OptHardline`): the running total at that point is
	 * returned and the rest of the tree is ignored. Used exclusively by
	 * the `IfFirstLineExceeds` probe to answer "would the first rendered
	 * line of `flatDoc` exceed `n` columns from the current pen?".
	 *
	 * Departure from `DocMeasure.flatTokenWidth`: forced hardlines abort the walk
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
				case Group(inner) | GroupWithRestProbe(inner):
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
				case IfFullLineExceeds(_, _, flatDoc):
					stack.push(flatDoc);
				case Fill(items, sep, _):
					var k:Int = items.length;
					while (k > 0) {
						k--;
						stack.push(items[k]);
						if (k > 0) stack.push(sep);
					}
				case OptSpace(s):
					total += s.length;
				case OptSpaceSkipAfterHardline:
					total += 1;
				case Flatten(inner) | WrapBoundary(inner):
					// ω-force-flat-engine slice A: transparent to first-
					// line walk. Both markers are render-time state; the
					// static first-line probe sees only structural width.
					stack.push(inner);
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
	 * Departures from `DocMeasure.flatTokenWidth`:
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
					case Group(innerDoc) | GroupWithRestProbe(innerDoc):
						// Static walk: descend in MFlat. Runtime Group
						// decision is unknowable here; flat-side measurement
						// matches the cascade rule semantic. GroupWithRestProbe
						// shares semantic at static walk — the rest-probe
						// affects render-time fit decision only.
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
					case IfFullLineExceeds(_, _, flatDoc):
						inner.push({doc: flatDoc, mode: MFlat});
					case Fill(items, sep, _):
						var k:Int = items.length;
						while (k > 0) {
							k--;
							inner.push({doc: items[k], mode: MFlat});
							if (k > 0) inner.push({doc: sep, mode: MFlat});
						}
					case OptSpace(s):
						total += s.length;
					case OptSpaceSkipAfterHardline:
						total += 1;
					case OptHardline | OptHardlineSkipAtOpenDelim:
						aborted = true;
					case Flatten(innerDoc) | WrapBoundary(innerDoc):
						// ω-force-flat-engine slice A: pass-through. The
						// rest-of-stack probe measures structural width;
						// force-flat markers add no width.
						inner.push({doc: innerDoc, mode: node.mode});
				}
			}
		}
		return total;
	}

	/**
	 * BG-descending sibling of `flatTokenWidthOfRestStack`. Identical
	 * stack-walk + abort-at-hardline semantic except the
	 * `BodyGroup(innerDoc)` arm descends in `MFlat` (mirrors `Group`)
	 * instead of being deferred. Used exclusively by the
	 * `IfFullLineExceeds` probe — chain-emit's wrap decision needs to
	 * see inline body content that follows on the same rendered line
	 * (e.g. `for (cond) BODY` where `BODY` lives inside a `BodyGroup`
	 * from `forBody=fitLine`).
	 *
	 * The sister `flatTokenWidthOfRestStack` stays unchanged
	 * (Departure 2) for the cond-wrap `IfLineExceeds` site whose probe
	 * must NOT include body content (else trailing-comment cond-wrap
	 * fixtures regress — see `feedback_bg_descend_reststack_*` memory).
	 */
	private static function flatTokenWidthOfRestStackFull(stack:Array<Frame>):Int {
		var total:Int = 0;
		var aborted:Bool = false;
		var i:Int = stack.length - 1;
		while (i >= 0 && !aborted) {
			final f:Frame = stack[i];
			i--;
			if (f.fillRest != null) {
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
					case Group(innerDoc) | BodyGroup(innerDoc) | GroupWithRestProbe(innerDoc):
						// BG-descend: chain-emit's full-line probe must
						// see inline body content (differentiator vs
						// sister `flatTokenWidthOfRestStack`).
						// GroupWithRestProbe shares semantic at static
						// walk — rest-probe is render-time only.
						inner.push({doc: innerDoc, mode: MFlat});
					case IfBreak(_, flatDoc):
						inner.push({doc: flatDoc, mode: MFlat});
					case IfWidthExceeds(_, _, flatDoc):
						inner.push({doc: flatDoc, mode: MFlat});
					case IfFirstLineExceeds(_, _, flatDoc):
						inner.push({doc: flatDoc, mode: MFlat});
					case IfLineExceeds(_, _, flatDoc):
						inner.push({doc: flatDoc, mode: MFlat});
					case IfFullLineExceeds(_, _, flatDoc):
						inner.push({doc: flatDoc, mode: MFlat});
					case Fill(items, sep, _):
						var k:Int = items.length;
						while (k > 0) {
							k--;
							inner.push({doc: items[k], mode: MFlat});
							if (k > 0) inner.push({doc: sep, mode: MFlat});
						}
					case OptSpace(s):
						total += s.length;
					case OptSpaceSkipAfterHardline:
						total += 1;
					case OptHardline | OptHardlineSkipAtOpenDelim:
						aborted = true;
					case Flatten(innerDoc) | WrapBoundary(innerDoc):
						// ω-force-flat-engine slice A: pass-through. Sister
						// of the `flatTokenWidthOfRestStack` arm.
						inner.push({doc: innerDoc, mode: node.mode});
				}
			}
		}
		return total;
	}
}
