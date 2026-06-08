package anyparse.query;

import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.Span;

using Lambda;

/**
 * Cursor-resolution and identifier/span primitives shared by the
 * scope-correct refactoring operations (`Rename`, `Inline`). Every
 * member is `public static` and behaviour-preserving: the bodies were
 * lifted verbatim out of `Rename` once a second consumer (`Inline`)
 * needed the same cursor-to-binding resolution and word-boundary
 * identifier-token logic. Keeping them here means the two operations
 * cannot drift apart.
 *
 * Coordinate convention: callers feed `cursor` as a raw UTF-16 offset
 * (the operations invert the `apq refs` printed column before calling).
 * The helpers never re-implement scope analysis — they ride on top of
 * the `Refs.find` resolver and operate on `QueryNode` spans only.
 */
@:nullSafety(Strict)
final class RefactorSupport {

	/**
	 * Class-member declaration kinds (fields / methods). A binding whose
	 * decl node carries one of these kinds is a class member, not a local
	 * — used to gate `this.<name>` augmentation in `Rename` and to refuse
	 * inlining a free identifier that may be a property getter in
	 * `Inline`.
	 */
	public static final FIELD_MEMBER_KINDS:Array<String> = [
		'VarMember', 'FinalMember', 'FnMember',
		'VarField', 'FinalField', 'FnField',
	];

	/**
	 * Resolve the cursor to the named occurrence node it sits on, in two
	 * tiers (innermost-wins within each):
	 *
	 *  1. A named node whose IDENTIFIER TOKEN contains the cursor — the
	 *     precise case (reads / writes whose span is the bare identifier,
	 *     params whose span starts at the name, a cursor placed directly
	 *     on a decl's name).
	 *  2. Failing that, a decl-host-shaped named node whose `span.from`
	 *     EQUALS the cursor — the `apq refs --decls` convention, where the
	 *     printed column maps to the decl's span start (the `var` / `for`
	 *     keyword), not the identifier inside it.
	 *
	 * Returns null when neither tier matches — a cursor on whitespace, a
	 * delimiter, or any non-identifier byte.
	 */
	public static function resolveCursorNode(tree:QueryNode, cursor:Int, source:String):Null<QueryNode> {
		final tokenHit:Null<QueryNode> = innermostWhere(tree, cursor, node -> identTokenContains(node, cursor, source));
		if (tokenHit != null) return tokenHit;
		return innermostWhere(tree, cursor, node -> {
			final span:Null<Span> = node.span;
			return span != null && span.from == cursor && isRenameableName(node.name);
		});
	}

	/**
	 * Innermost (deepest, last-starting) named node satisfying `pred`
	 * whose span contains `cursor`. Descends the whole tree, keeping the
	 * last match in pre-order — a tighter enclosing node is visited after
	 * its ancestors, so the final assignment is the innermost. `module` /
	 * receiver `this` nodes are excluded via `isRenameableName`.
	 */
	public static function innermostWhere(tree:QueryNode, cursor:Int, pred:QueryNode -> Bool):Null<QueryNode> {
		var best:Null<QueryNode> = null;
		function walk(node:QueryNode):Void {
			final span:Null<Span> = node.span;
			if (span != null && cursor >= span.from && cursor < span.to && isRenameableName(node.name) && pred(node)) best = node;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/**
	 * Does the identifier token of `node` (the first word-boundary
	 * occurrence of its name within its span) contain `cursor`?
	 */
	public static function identTokenContains(node:QueryNode, cursor:Int, source:String):Bool {
		final span:Null<Span> = node.span;
		final name:Null<String> = node.name;
		if (span == null || name == null) return false;
		final identFrom:Int = identTokenOffset(source, span, name);
		if (identFrom < 0) return false;
		return cursor >= identFrom && cursor < identFrom + name.length;
	}

	/**
	 * Resolve which binding the cursor node belongs to, as the `from`
	 * offset of that binding's declaration:
	 *
	 *  - The cursor node sits on a Decl hit (`span.from` matches) → the
	 *    decl binds itself.
	 *  - It sits on a Read / Write hit → follow the hit's `bindingSpan`.
	 *  - It is a `this.<field>` field access (no matching ref hit) → the
	 *    member decl of the same name.
	 *
	 * Returns null when nothing resolves (e.g. an unbound cross-file
	 * read).
	 */
	public static function resolveBindingFrom(node:QueryNode, hits:Array<RefHit>):Null<Int> {
		final span:Null<Span> = node.span;
		if (span == null) return null;
		final nodeFrom:Int = span.from;

		final hit:Null<RefHit> = hits.find(h -> h.span.from == nodeFrom);
		if (hit != null) {
			if (hit.kind == RefKind.Decl) return hit.span.from;
			final boundTo:Null<Span> = hit.bindingSpan;
			return boundTo == null ? null : boundTo.from;
		}

		// Cursor is on a node that the resolver does not emit as a ref
		// hit — the `this.<field>` field-access case. Bind it to the sole
		// member decl of the same name.
		if (node.kind == 'FieldAccess') {
			final memberDecl:Null<RefHit> = hits.find(h -> h.kind == RefKind.Decl);
			return memberDecl == null ? null : memberDecl.span.from;
		}
		return null;
	}

	/**
	 * The node in `tree` whose `span.from == from` (first in pre-order).
	 * Drives "what kind of declaration does this binding offset name?" —
	 * `Inline` reads the kind (must be a local `var` / `final`) and the
	 * initializer child off the returned node. Null when no node starts
	 * exactly at `from`.
	 */
	public static function nodeAtFrom(tree:QueryNode, from:Int):Null<QueryNode> {
		var found:Null<QueryNode> = null;
		function walk(node:QueryNode):Void {
			if (found != null) return;
			final span:Null<Span> = node.span;
			if (span != null && span.from == from) {
				found = node;
				return;
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return found;
	}

	/** Is `kind` a class-member declaration (field / method)? */
	public static inline function isFieldMemberKind(kind:String):Bool {
		return FIELD_MEMBER_KINDS.contains(kind);
	}

	/**
	 * Offset of the first word-boundary occurrence of `name` within
	 * `[span.from, span.to)`, or -1 when not found. A word boundary
	 * requires the characters immediately before and after the match to
	 * be non-identifier characters (or the span edge), so renaming `x`
	 * inside `var x = xs[0]` matches the binding `x`, not the `x` inside
	 * `xs`.
	 */
	public static function identTokenOffset(source:String, span:Span, name:String):Int {
		final from:Int = span.from < 0 ? 0 : span.from;
		final to:Int = span.to <= source.length ? span.to : source.length;
		var i:Int = from;
		while (i + name.length <= to) {
			final at:Int = source.indexOf(name, i);
			if (at < 0 || at + name.length > to) return -1;
			final beforeOk:Bool = at == 0 || !isIdentChar(StringTools.fastCodeAt(source, at - 1));
			final afterIdx:Int = at + name.length;
			final afterOk:Bool = afterIdx >= source.length || !isIdentChar(StringTools.fastCodeAt(source, afterIdx));
			if (beforeOk && afterOk) return at;
			i = at + 1;
		}
		return -1;
	}

	/**
	 * Apply a set of source edits, end-to-start. Edits are sorted
	 * descending by `span.from` and spliced from the highest offset down,
	 * so each splice leaves all lower offsets valid. The caller guarantees
	 * the edits do not overlap. Each edit replaces `[span.from, span.to)`
	 * with `text` (empty `text` deletes the range). Generalises the
	 * splice loop both refactoring operations need.
	 */
	public static function applyEdits(source:String, edits:Array<{span:Span, text:String}>):String {
		final sorted:Array<{span:Span, text:String}> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var result:String = source;
		for (edit in sorted)
			result = result.substring(0, edit.span.from) + edit.text + result.substring(edit.span.to);
		return result;
	}

	/** A name is renameable when it is a valid identifier and not `this`. */
	public static inline function isRenameableName(name:Null<String>):Bool {
		return name != null && name != 'this' && isIdentifier(name);
	}

	/** Whole-string check: a non-empty identifier (`[A-Za-z_][A-Za-z0-9_]*`). */
	public static function isIdentifier(s:String):Bool {
		if (s.length == 0) return false;
		final first:Int = StringTools.fastCodeAt(s, 0);
		if (!isIdentStartChar(first)) return false;
		for (i in 1...s.length) if (!isIdentChar(StringTools.fastCodeAt(s, i))) return false;
		return true;
	}

	public static inline function isIdentStartChar(c:Int):Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code;
	}

	public static inline function isIdentChar(c:Int):Bool {
		return isIdentStartChar(c) || (c >= '0'.code && c <= '9'.code);
	}

	/**
	 * Parse a non-negative decimal integer, returning null when the string
	 * has any non-digit character — so a coordinate like `3:1x` or a
	 * permutation index `2x` is rejected rather than silently resolving to
	 * the leading digits. Shared by the CLI coordinate parser and the
	 * change-signature permutation parser.
	 */
	public static function parseStrictInt(s:String):Null<Int> {
		if (s.length == 0) return null;
		for (j in 0...s.length) {
			final c:Int = StringTools.fastCodeAt(s, j);
			if (c < '0'.code || c > '9'.code) return null;
		}
		return Std.parseInt(s);
	}

	/**
	 * Push a `[from, from+length)` span into `out`, deduped by `from`: a
	 * non-negative `from` not already in `seen` is recorded and appended.
	 * The dedup-and-collect idiom shared by the occurrence collectors of
	 * `Rename` and `CrossRename` (the same identifier-token offset can be
	 * surfaced by more than one walker).
	 */
	public static function pushUniqueSpan(out:Array<Span>, seen:Array<Int>, from:Int, length:Int):Void {
		if (from >= 0 && !seen.contains(from)) {
			seen.push(from);
			out.push(new Span(from, from + length));
		}
	}
}
