package anyparse.core;

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
	/** Renders `doc` targeting `width` columns per line. **/
	public static function render(doc:Doc, width:Int):String {
		var buf = new StringBuf();
		var stack:Array<Frame> = [new Frame(0, MBreak, doc)];
		var col = 0;

		while (stack.length > 0) {
			var f = stack.pop();
			switch (f.doc) {
				case Empty:
					// nothing
				case Text(s):
					buf.add(s);
					col += s.length;
				case Line(flat):
					if (f.mode == MFlat) {
						buf.add(flat);
						col += flat.length;
					} else {
						buf.add("\n");
						for (_ in 0...f.indent) buf.add(" ");
						col = f.indent;
					}
				case Nest(n, inner):
					stack.push(new Frame(f.indent + n, f.mode, inner));
				case Concat(items):
					var i = items.length;
					while (--i >= 0) stack.push(new Frame(f.indent, f.mode, items[i]));
				case Group(inner):
					if (fitsFlat(width - col, f.indent, inner)) {
						stack.push(new Frame(f.indent, MFlat, inner));
					} else {
						stack.push(new Frame(f.indent, MBreak, inner));
					}
			}
		}

		return buf.toString();
	}

	/**
		Returns `true` if rendering `d` in flat mode at the given indent
		consumes at most `remaining` columns. Used to choose between flat and
		broken layout for a `Group`.
	**/
	static function fitsFlat(remaining:Int, indent:Int, d:Doc):Bool {
		if (remaining < 0) return false;
		var local:Array<Frame> = [new Frame(indent, MFlat, d)];
		var budget = remaining;

		while (local.length > 0 && budget >= 0) {
			var f = local.pop();
			switch (f.doc) {
				case Empty:
					// nothing
				case Text(s):
					budget -= s.length;
				case Line(flat):
					// In flat measurement mode we always use the flat
					// replacement. A hard line (flat == "\n") makes the
					// measurement "overflow" only if it is longer than the
					// remaining budget — which is almost always the case —
					// so groups containing hard lines will correctly refuse
					// to flatten.
					budget -= flat.length;
				case Nest(n, inner):
					local.push(new Frame(f.indent + n, MFlat, inner));
				case Concat(items):
					var j = items.length;
					while (--j >= 0) local.push(new Frame(f.indent, MFlat, items[j]));
				case Group(inner):
					local.push(new Frame(f.indent, MFlat, inner));
			}
		}

		return budget >= 0;
	}
}
