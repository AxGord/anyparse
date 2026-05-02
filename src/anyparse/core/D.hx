package anyparse.core;

/**
	Builder helpers for `Doc`.

	Kept as a short `D` class so that grammar writers can write
	`D.group(D.concat([D.text("["), ...]))` without ceremony. All helpers
	are `inline`, so at the call site they compile into direct `Doc`
	constructor applications — no runtime cost.
**/
class D {
	/** Nothing. **/
	public static inline function empty():Doc
		return Empty;

	/** Literal string with no line breaks. **/
	public static inline function text(s:String):Doc
		return Text(s);

	/** A potential break. In flat mode becomes a single space. **/
	public static inline function line():Doc
		return Line(" ");

	/** A potential break. In flat mode collapses to nothing. **/
	public static inline function softline():Doc
		return Line("");

	/** A mandatory break. Always forces a newline, even in flat mode. **/
	public static inline function hardline():Doc
		return Line("\n");

	/** Adds `n` columns of indentation to breaks inside `inner`. **/
	public static inline function nest(n:Int, inner:Doc):Doc
		return Nest(n, inner);

	/** Wraps `inner` as a unit that the renderer will try to flatten. **/
	public static inline function group(inner:Doc):Doc
		return Group(inner);

	/** Concatenates several docs in order. **/
	public static inline function concat(items:Array<Doc>):Doc
		return Concat(items);

	/**
		Wadler `fillSep`. Packs `items` left-to-right joined by `sep`, breaking
		before any item that would overflow the current line. The `sep`'s
		`Line` becomes a hardline at the Fill's indent on overflow, and stays
		flat between items that fit.
	**/
	public static inline function fill(items:Array<Doc>, sep:Doc):Doc
		return Fill(items, sep);

	/**
		Optional inline whitespace, dropped when immediately followed by a
		break-mode `Line`. Used for lead trailing spaces that must vanish
		before a hardline (e.g. `leftCurly=Next`).
	**/
	public static inline function optSpace(s:String):Doc
		return OptSpace(s);

	/** Places `sep` between each item of `items`. Returns a fresh array. **/
	public static function intersperse(items:Array<Doc>, sep:Doc):Array<Doc> {
		if (items.length <= 1) return items.copy();
		var result = [];
		for (i in 0...items.length) {
			if (i > 0) result.push(sep);
			result.push(items[i]);
		}
		return result;
	}
}
