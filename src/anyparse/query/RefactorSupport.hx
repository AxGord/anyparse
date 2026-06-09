package anyparse.query;

import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * Outcome of a source-mutation operation: `Ok` carries the rewritten
 * source, `Err` a human-readable diagnostic. Shared by the structural
 * INSERT / REPLACE ops (`AddMember` / `AddImport` / `ReplaceNode`),
 * which all funnel their finalize through `RefactorSupport.canonicalize`
 * and therefore return the same shape.
 */
enum EditResult {
	Ok(text:String);
	Err(message:String);
}

/**
 * One resolved top-level type declaration, normalised across the plain
 * and `final`-wrapped grammar shapes so every consumer compares uniformly.
 *
 *  - A plain `class C {}` parses as a single `ClassDecl C` node — `name`
 *    and `kind` come from the node, `nameNode` IS the node, and `fullSpan`
 *    is the node's own span.
 *  - A `final class C {}` parses as `FinalDecl(ClassForm C …)` — the OUTER
 *    `FinalDecl` carries NO name and a span that INCLUDES the `final `
 *    keyword; the INNER `ClassForm` carries the name `C` and a span that
 *    EXCLUDES `final `. For this shape `kind` is normalised to `ClassDecl`
 *    (a final class IS a class), `nameNode` is the inner `ClassForm` (it
 *    holds the name token, so `identTokenContains` and the decl-name
 *    occurrence anchor on it), and `fullSpan` is the OUTER `FinalDecl`
 *    span so a move cuts `final class C {…}` WITH its `final ` keyword.
 *
 * `final` is the only modifier that WRAPS a decl (it is legal in Haxe
 * only on `class` — `final interface` / `final abstract` are parse
 * errors). Every other modifier (`private` / `public` / `extern`) is a
 * SEPARATE preceding sibling node (`Private` / `Extern`) that leaves the
 * named decl node a plain `ClassDecl` / … — those already resolve through
 * the node-on-node branch, so no wrapper handling is needed for them.
 */
typedef TypeDeclMatch = {
	var name:String;
	var kind:String;
	var nameNode:QueryNode;
	var fullSpan:Span;
}

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
	 * `Inline`. `FinalModifiedMember` is the `final` METHOD form
	 * (`final function f()`); the query projection surfaces its name off
	 * the inner `HxFinalModifierMember.fn`, so it is a member like
	 * `FnMember` for `this.<name>` purposes.
	 */
	public static final FIELD_MEMBER_KINDS:Array<String> = [
		'VarMember', 'FinalMember', 'FnMember', 'FinalModifiedMember',
		'VarField', 'FinalField', 'FnField',
	];

	/**
	 * Function-declaration kinds — class methods (`FnMember`, plus the
	 * `final` method form `FinalModifiedMember`) and named local functions
	 * (`LocalFnStmt`). All expose their parameter list as the leading
	 * `Required` / `Optional` children of the decl node. Shared by
	 * `AddParam`, `ExtractVar`, and `ChangeSig` so the three operations
	 * recognise the same set of function declarations. A `final` method's
	 * name is surfaced by the query projection (off the inner
	 * `HxFinalModifierMember.fn`), so it resolves through `resolveCursorNode`
	 * / `innermostWhere` exactly like a plain method.
	 */
	public static final FN_DECL_KINDS:Array<String> = [
		'FnMember', 'FinalModifiedMember', 'LocalFnStmt',
	];

	/**
	 * The grammar decl-node kinds that count as a top-level type
	 * declaration in their PLAIN (non-`final`) shape. A `final class`'s
	 * named node is a `ClassForm` — NOT in this list — so callers that
	 * need to recognise a final class must go through `typeDeclOf`, which
	 * handles the `FinalDecl` wrapper. Shared by `SymbolIndex`,
	 * `CrossRename`, and `MoveSymbol`.
	 */
	public static final TYPE_DECL_KINDS:Array<String> = [
		'ClassDecl', 'InterfaceDecl', 'EnumDecl', 'TypedefDecl', 'AbstractDecl',
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
	 * Recognise `node` as a top-level type declaration, normalised across
	 * the plain and `final`-wrapped shapes (see `TypeDeclMatch`). Returns
	 * null when `node` is neither a plain type-decl nor a `final class`
	 * wrapper, or when the resolved decl has no name / no span.
	 *
	 *  - `node.kind` ∈ `TYPE_DECL_KINDS` with a name → the node names
	 *    itself (`kind` = the node kind, `fullSpan` = the node's span).
	 *  - `node.kind == 'FinalDecl'` wrapping a named `ClassForm` first
	 *    child → the inner `ClassForm` names the decl; `kind` normalises to
	 *    `ClassDecl` and `fullSpan` is the OUTER span (includes `final `).
	 */
	public static function typeDeclOf(node:QueryNode):Null<TypeDeclMatch> {
		final span:Null<Span> = node.span;
		if (span == null) return null;

		final name:Null<String> = node.name;
		if (name != null && TYPE_DECL_KINDS.contains(node.kind))
			return {name: name, kind: node.kind, nameNode: node, fullSpan: span};

		if (node.kind == 'FinalDecl' && node.children.length > 0) {
			final inner:QueryNode = node.children[0];
			final innerName:Null<String> = inner.name;
			if (inner.kind == 'ClassForm' && innerName != null)
				return {name: innerName, kind: 'ClassDecl', nameNode: inner, fullSpan: span};
		}
		return null;
	}

	/**
	 * Resolve the cursor to the type declaration it sits on: the
	 * innermost (deepest pre-order) decl whose `fullSpan` contains the
	 * cursor and whose name identifier-token contains the cursor OR whose
	 * `fullSpan.from == cursor` (the `apq refs --decls` convention, where
	 * the printed column maps to the decl's span start — the `final` /
	 * `class` / `enum` keyword). Final-aware via `typeDeclOf`. Returns
	 * null when the cursor is not on a type declaration.
	 */
	public static function resolveTypeDeclAtCursor(tree:QueryNode, cursor:Int, source:String):Null<TypeDeclMatch> {
		var best:Null<TypeDeclMatch> = null;
		function walk(node:QueryNode):Void {
			final m:Null<TypeDeclMatch> = typeDeclOf(node);
			if (m != null) {
				final span:Span = m.fullSpan;
				if (cursor >= span.from && cursor < span.to
					&& (identTokenContains(m.nameNode, cursor, source) || span.from == cursor)) best = m;
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/** File basename: the path tail after the last `/`, with a `.hx` suffix removed. */
	public static function baseNameOf(file:String):String {
		final slash:Int = file.lastIndexOf('/');
		final tail:String = slash < 0 ? file : file.substr(slash + 1);
		return StringTools.endsWith(tail, '.hx') ? tail.substr(0, tail.length - '.hx'.length) : tail;
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

	/**
	 * Finalize a structural mutation through the WRITER, so inserted /
	 * replaced code is formatted by the grammar's own rules rather than
	 * kept as-is. The shared tail of `AddMember` / `AddImport` /
	 * `ReplaceNode`:
	 *
	 *  1. Canonical gate — unless `reformat`, the source must already be
	 *     writer-canonical (`writeRoundTrip(source) == source`). A
	 *     non-canonical file is refused, because a whole-file rewrite would
	 *     also reflow its unrelated hand-wrapping into a surprise diff.
	 *     `--reformat` opts into that whole-file canonicalisation.
	 *  2. Splice the caller's edits (raw text) into the source.
	 *  3. Re-emit the WHOLE spliced file through `writeRoundTrip` (the
	 *     trivia / comment-preserving pipeline). This BOTH validates (an
	 *     unparseable splice throws → `Err`) AND canonically formats the
	 *     inserted code together with the rest of the file.
	 *
	 * The caller supplies only the edit position + raw text; indentation
	 * and layout of the result are the writer's job. Requires a grammar
	 * with a writer (`writeRoundTrip` non-null); a writer-less grammar is
	 * refused.
	 */
	public static function canonicalize(source:String, edits:Array<{span:Span, text:String}>, reformat:Bool, plugin:GrammarPlugin):EditResult {
		if (!reformat) {
			final canon:Null<String> = try plugin.writeRoundTrip(source)
				catch (exception:ParseError) return Err('source does not parse: ${exception.toString()}')
				catch (exception:Exception) return Err('source does not parse: ${exception.message}');
			if (canon == null)
				return Err('the "${plugin.langName()}" grammar has no writer — cannot writer-format the result');
			if (canon != source)
				return Err('file is not in canonical form — re-run with --reformat to canonicalise the whole file, or format it first');
		}

		final spliced:String = applyEdits(source, edits);
		final result:Null<String> = try plugin.writeRoundTrip(spliced)
			catch (exception:ParseError) return Err('result does not parse: ${exception.toString()}')
			catch (exception:Exception) return Err('result does not parse: ${exception.message}');
		if (result == null)
			return Err('the "${plugin.langName()}" grammar has no writer — cannot writer-format the result');
		return Ok(result);
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

	/** Is `c` an ASCII space / tab / newline / carriage return? */
	public static inline function isSpace(c:Int):Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
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
