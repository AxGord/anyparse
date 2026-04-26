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
**/
private class Frame {
	public var indent:Int;
	public var mode:Mode;
	public var doc:Doc;

	public inline function new(indent:Int, mode:Mode, doc:Doc) {
		this.indent = indent;
		this.mode = mode;
		this.doc = doc;
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

		while (stack.length > 0) {
			final f:Frame = stack.pop();
			switch (f.doc) {
				case Empty:
					// nothing
				case Text(s):
					if (s.length > 0 && pendingIndent >= 0) {
						writeIndent(buf, pendingIndent, indentChar, tabWidth);
						pendingIndent = -1;
					}
					buf.add(s);
					col += s.length;
				case Line(flat):
					if (f.mode == MFlat) {
						if (flat.length > 0 && pendingIndent >= 0) {
							writeIndent(buf, pendingIndent, indentChar, tabWidth);
							pendingIndent = -1;
						}
						buf.add(flat);
						col += flat.length;
					} else {
						if (trailingWhitespace && pendingIndent >= 0) {
							writeIndent(buf, pendingIndent, indentChar, tabWidth);
						}
						buf.add(lineEnd);
						pendingIndent = f.indent;
						col = f.indent;
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
			}
		}

		return budget >= 0;
	}
}
