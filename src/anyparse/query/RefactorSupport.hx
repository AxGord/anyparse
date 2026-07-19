package anyparse.query;

import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

import anyparse.query.GrammarPlugin.RefShape;

/**
 * Outcome of a source-mutation operation: `Ok` carries the rewritten
 * source, `Err` a human-readable diagnostic. Shared by the structural
 * INSERT / REPLACE ops (`AddMember` / `AddImport` / `ReplaceNode`),
 * which all funnel their finalize through `RefactorSupport.canonicalize`
 * and therefore return the same shape.
 */
enum EditResult {

	Ok(text: String);
	Err(message: String);

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
	var name: String;
	var kind: String;
	var nameNode: QueryNode;
	var fullSpan: Span;
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
	public static final FIELD_MEMBER_KINDS: Array<String> = [
		'VarMember',
		'FinalMember',
		'FnMember',
		'FinalModifiedMember',
		'VarField',
		'FinalField',
		'FnField',
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
	public static final FN_DECL_KINDS: Array<String> = [
		'FnMember',
		'FinalModifiedMember',
		'LocalFnStmt',
	];

	/**
	 * The grammar decl-node kinds that count as a top-level type
	 * declaration in their PLAIN (non-`final`) shape. A `final class`'s
	 * named node is a `ClassForm` — NOT in this list — so callers that
	 * need to recognise a final class must go through `typeDeclOf`, which
	 * handles the `FinalDecl` wrapper. Shared by `SymbolIndex`,
	 * `CrossRename`, and `MoveSymbol`.
	 */
	public static final TYPE_DECL_KINDS: Array<String> = [
		'ClassDecl',
		'InterfaceDecl',
		'EnumDecl',
		'EnumAbstractDecl',
		'TypedefDecl',
		'AbstractDecl',
	];

	/**
	 * Expression-list container kinds whose direct children are
	 * comma-separated. When an element's parent is one of these, an insert
	 * joins with a `,` and a remove swallows one. `Call` / `NewExpr` carry a
	 * leading non-element child (callee / constructed type), harmless here
	 * because the targeted element is an actual argument, never the callee.
	 * Shared by `add-element` (insert) and `deleteNode` (remove) so the two
	 * agree on which slots are comma lists.
	 */
	public static final COMMA_CONTAINER_KINDS: Array<String> = ['ArrayExpr', 'ObjectLit', 'Call', 'NewExpr'];

	/**
	 * The sibling node kinds `@:meta` annotations project to: `Meta` for the
	 * paren-less `@:name`, `MetaCall` for `@:name(args)`, `PlainMeta` for the
	 * verbatim raw catch-all (mirrors the grammar's `metaShape().metaKinds`).
	 * Shared by `MODIFIER_META_KINDS` and the ops that must skip a leading meta
	 * run (e.g. MoveMember's visibility promotion).
	 */
	public static final META_KINDS: Array<String> = ['Meta', 'MetaCall', 'PlainMeta'];

	/**
	 * Sibling node kinds a declaration's modifiers and metadata project to —
	 * emitted BEFORE the decl they modify (`public static function` is
	 * `(Public)(Static)(FnMember)`; annotations are the `META_KINDS` forms).
	 * `declGroupSpan` folds a run of these plus the decl into one logical
	 * element so a structural edit treats the whole `[@:meta modifiers… decl]`
	 * as a unit, not the decl keyword alone. The member-level `abstract`
	 * modifier (Haxe 4.2 abstract classes) projects as its own `(Abstract)`
	 * sibling and IS here. `final` is NOT — it WRAPS its decl (`FinalDecl` /
	 * `FinalModifiedMember` / `FinalMember`) instead of projecting to a
	 * separate sibling.
	 */
	private static final MODIFIER_META_KINDS: Array<String> = META_KINDS.concat([
		'Public',
		'Private',
		'Static',
		'Inline',
		'Override',
		'Macro',
		'Extern',
		'Dynamic',
		'Abstract'
	]);

	/**
	 * Node kinds an expression subtree may contain and still be
	 * SIDE-EFFECT-FREE: literals, bare identifiers, parenthesised groups, and
	 * the pure binary / unary / ternary operators. The string-payload leaf
	 * `Literal` is included so a plain (non-interpolated) string passes — an
	 * INTERPOLATED string instead nests `Ident` / `Block` children (the
	 * spliced expression / variable), neither of which is whitelisted, so it
	 * is correctly excluded. The increment / decrement ctors are deliberately
	 * absent — they mutate their operand. Shared by `Inline` (inline-var
	 * substitution safety) and the `unused-local` check (delete-fix safety).
	 */
	private static final SAFE_KINDS: Array<String> = [
		// Literals + the plain-string content leaf.
		'IntLit',
		'FloatLit',
		'BoolLit',
		'NullLit',
		'DoubleStringExpr',
		'SingleStringExpr',
		'Literal',
		// Bare identifier + paren group.
		'IdentExpr',
		'ParenExpr',
		// Binary operators (HxExpr Pratt set, mutating assigns excluded).
		'Add',
		'Sub',
		'Mul',
		'Div',
		'Mod',
		'And',
		'Or',
		'Eq',
		'NotEq',
		'Lt',
		'Gt',
		'LtEq',
		'GtEq',
		'BitAnd',
		'BitOr',
		'BitXor',
		'Shl',
		'Shr',
		'UShr',
		'NullCoal',
		// Unary operators + ternary.
		'Neg',
		'Not',
		'BitNot',
		'Ternary',
	];

	/**
	 * Simple names of stdlib value / container types whose methods never reassign an
	 * abstract `this`, so a method call on a binding of one is not a write that blocks
	 * `final`: `String` is immutable; `Array` / `Map` and the others mutate their
	 * contents, not the binding. The `final`-conversion checks keep suggesting `final`
	 * for such bindings even when their type is not resolvable in the lint scope.
	 */
	private static final finalSafeStdlibTypes: Array<String> = [
		'String',
		'Array',
		'Map',
		'List',
		'Vector',
		'StringBuf',
		'StringMap',
		'IntMap',
		'ObjectMap',
		'EnumValueMap',
		'Bytes',
		'BytesBuffer',
		'EReg',
		'Date',
		'Xml'
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
	public static function resolveCursorNode(tree: QueryNode, cursor: Int, source: String): Null<QueryNode> {
		final tokenHit: Null<QueryNode> = innermostWhere(tree, cursor, node -> identTokenContains(node, cursor, source));
		return tokenHit ?? innermostWhere(tree, cursor, node -> {
			final span: Null<Span> = node.span;
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
	public static function innermostWhere(tree: QueryNode, cursor: Int, pred: QueryNode -> Bool): Null<QueryNode> {
		var best: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
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
	public static function identTokenContains(node: QueryNode, cursor: Int, source: String): Bool {
		final span: Null<Span> = node.span;
		final name: Null<String> = node.name;
		if (span == null || name == null) return false;
		final identFrom: Int = identTokenOffset(source, span, name);
		return identFrom >= 0 && cursor >= identFrom && cursor < identFrom + name.length;
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
	public static function resolveBindingFrom(node: QueryNode, hits: Array<RefHit>): Null<Int> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final nodeFrom: Int = span.from;

		final hit: Null<RefHit> = hits.find(h -> h.span.from == nodeFrom);
		if (hit != null) {
			if (hit.kind == RefKind.Decl) return hit.span.from;
			final boundTo: Null<Span> = hit.bindingSpan;
			return boundTo == null ? null : boundTo.from;
		}

		// Cursor is on a node that the resolver does not emit as a ref
		// hit — the `this.<field>` field-access case. Bind it to the sole
		// member decl of the same name.
		if (node.kind == 'FieldAccess') {
			final memberDecl: Null<RefHit> = hits.find(h -> h.kind == RefKind.Decl);
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
	public static function nodeAtFrom(tree: QueryNode, from: Int): Null<QueryNode> {
		var found: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			if (found != null) return;
			final span: Null<Span> = node.span;
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
	public static inline function isFieldMemberKind(kind: String): Bool {
		return FIELD_MEMBER_KINDS.contains(kind);
	}

	/**
	 * Whether a `macro` modifier (kind `macroKind`) precedes the sibling at `index`
	 * within its modifier run. A member's modifiers project as separate childless,
	 * nameless sibling nodes immediately before it (`public static macro function f`
	 * → `(Public)(Static)(Macro)(FnMember f)`), so the run is scanned BACKWARD from
	 * `index`: a `macroKind` sibling means the member is macro-modified; a sibling for
	 * which `isResetBoundary` holds ends the run — the previous member or annotation,
	 * whose modifiers are not this one's. Pure modifier nodes (childless, nameless,
	 * non-boundary) are skipped over. `macroKind` null → always false.
	 *
	 * The reset boundary is the caller's, because it differs by intent: the call graph
	 * ends a run at ANY named or child-bearing node, the void-return check at a member
	 * declaration. Both agree for every valid Haxe modifier arrangement (the macro
	 * modifier always sits in a contiguous childless run right before its function), so
	 * the parameter preserves each caller's exact policy rather than unifying them.
	 */
	public static function macroModifierPrecedes(
		siblings: Array<QueryNode>, index: Int, macroKind: Null<String>, isResetBoundary: QueryNode -> Bool
	): Bool {
		if (macroKind == null) return false;
		var i: Int = index - 1;
		while (i >= 0) {
			final sib: QueryNode = siblings[i];
			if (sib.kind == macroKind) return true;
			if (isResetBoundary(sib)) return false;
			i--;
		}
		return false;
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
	public static function typeDeclOf(node: QueryNode): Null<TypeDeclMatch> {
		final span: Null<Span> = node.span;
		if (span == null) return null;

		final name: Null<String> = node.name;
		if (name != null && TYPE_DECL_KINDS.contains(node.kind)) return {
			name: name,
			kind: node.kind,
			nameNode: node,
			fullSpan: span
		};

		if (node.kind == 'FinalDecl' && node.children.length > 0) {
			final inner: QueryNode = node.children[0];
			final innerName: Null<String> = inner.name;
			if (inner.kind == 'ClassForm' && innerName != null) return {
				name: innerName,
				kind: 'ClassDecl',
				nameNode: inner,
				fullSpan: span
			};
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
	public static function resolveTypeDeclAtCursor(tree: QueryNode, cursor: Int, source: String): Null<TypeDeclMatch> {
		var best: Null<TypeDeclMatch> = null;
		function walk(node: QueryNode): Void {
			final m: Null<TypeDeclMatch> = typeDeclOf(node);
			if (m != null) {
				final span: Span = m.fullSpan;
				if (cursor >= span.from && cursor < span.to && (identTokenContains(m.nameNode, cursor, source) || span.from == cursor))
					best = m;
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/** File basename: the path tail after the last `/`, with a `.hx` suffix removed. */
	public static function baseNameOf(file: String): String {
		final slash: Int = file.lastIndexOf('/');
		final tail: String = slash < 0 ? file : file.substr(slash + 1);
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
	public static function identTokenOffset(source: String, span: Span, name: String): Int {
		final from: Int = span.from < 0 ? 0 : span.from;
		final to: Int = span.to <= source.length ? span.to : source.length;
		var i: Int = from;
		while (i + name.length <= to) {
			final at: Int = source.indexOf(name, i);
			if (at < 0 || at + name.length > to) return -1;
			final beforeOk: Bool = at == 0 || !isIdentChar(StringTools.fastCodeAt(source, at - 1));
			final afterIdx: Int = at + name.length;
			final afterOk: Bool = afterIdx >= source.length || !isIdentChar(StringTools.fastCodeAt(source, afterIdx));
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
	public static function applyEdits(source: String, edits: Array<{ span: Span, text: String }>): String {
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var result: String = source;
		for (edit in sorted) result = result.substring(0, edit.span.from) + edit.text + result.substring(edit.span.to);
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
	 *
	 * `optsJson` is the project's writer-config JSON (an `hxformat.json`
	 * discovered near the edited file); passed to BOTH `writeRoundTrip`
	 * calls so the canonical gate and the result agree on the project
	 * style. `null` → the plugin's compiled defaults.
	 */
	public static function canonicalize(
		source: String, edits: Array<{ span: Span, text: String }>, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		if (!reformat) {
			final canon: Null<String> =
				try plugin.writeRoundTrip(
					source, optsJson
				) catch (exception: ParseError) return Err('source does not parse: ${exception.toString()}')
				catch (exception: Exception) return Err('source does not parse: ${exception.message}');
			if (canon == null) return Err('the "${plugin.langName()}" grammar has no writer — cannot writer-format the result');
			if (canon != source)
				return Err('file is not in canonical form — re-run with --reformat to canonicalise the whole file, or format it first');
		}

		final spliced: String = applyEdits(source, edits);
		final result: Null<String> =
			try plugin.writeRoundTrip(
				spliced, optsJson
			) catch (exception: ParseError) return Err('result does not parse: ${exception.toString()}')
			catch (exception: Exception) return Err('result does not parse: ${exception.message}');
		return result == null ? Err('the "${plugin.langName()}" grammar has no writer — cannot writer-format the result') : Ok(result);
	}

	/** A name is renameable when it is a valid identifier and not `this`. */
	public static inline function isRenameableName(name: Null<String>): Bool {
		return name != null && name != 'this' && isIdentifier(name);
	}

	/** Whole-string check: a non-empty identifier (`[A-Za-z_][A-Za-z0-9_]*`). */
	public static function isIdentifier(s: String): Bool {
		if (s.length == 0) return false;
		final first: Int = StringTools.fastCodeAt(s, 0);
		if (!isIdentStartChar(first)) return false;
		for (i in 1...s.length) if (!isIdentChar(StringTools.fastCodeAt(s, i))) return false;
		return true;
	}

	public static inline function isIdentStartChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code;
	}

	/** Does `s` begin with an upper-case ASCII letter — the Haxe convention a type name follows, distinguishing a type reference from a lower-case value / package segment? */
	public static inline function isUpperInitial(s: String): Bool {
		final c: Int = StringTools.fastCodeAt(s, 0);
		return c >= 'A'.code && c <= 'Z'.code;
	}

	public static inline function isIdentChar(c: Int): Bool {
		return isIdentStartChar(c) || (c >= '0'.code && c <= '9'.code);
	}

	/** Is `c` an ASCII space / tab / newline / carriage return? */
	public static inline function isSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

	/**
	 * Parse a non-negative decimal integer, returning null when the string
	 * has any non-digit character — so a coordinate like `3:1x` or a
	 * permutation index `2x` is rejected rather than silently resolving to
	 * the leading digits. Shared by the CLI coordinate parser and the
	 * change-signature permutation parser.
	 */
	public static function parseStrictInt(s: String): Null<Int> {
		if (s.length == 0) return null;
		for (j in 0...s.length) {
			final c: Int = StringTools.fastCodeAt(s, j);
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
	public static function pushUniqueSpan(out: Array<Span>, seen: Array<Int>, from: Int, length: Int): Void {
		if (from >= 0 && !seen.contains(from)) {
			seen.push(from);
			out.push(new Span(from, from + length));
		}
	}

	/**
	 * The source span of the LOGICAL declaration at `node` — a decl together
	 * with the modifier / metadata sibling nodes that precede it. Modifiers
	 * (`public` / `private` / `static` / `inline` / `override` / `macro` /
	 * `extern` / `dynamic`) and `@:meta` project to separate siblings BEFORE
	 * the decl they modify, so an edit on the whole declaration must span from
	 * the FIRST of them, and a cursor that resolves to a modifier sibling
	 * targets the decl that follows it. Any element that is not part of a
	 * modifier-decl group (a statement, an array / call element, a package
	 * decl) keeps its own span.
	 *
	 * Shared by `add-element` (insert OUTSIDE the group) and `replace-node`
	 * (replace the WHOLE declaration, modifiers included).
	 */
	public static function declGroupSpan(node: QueryNode, parent: Null<QueryNode>, nodeSpan: Span): Span {
		if (parent == null) return nodeSpan;
		final siblings: Array<QueryNode> = parent.children;
		final i: Int = siblings.indexOf(node);
		if (i < 0) return nodeSpan;

		// The decl is the cursor node, or — when the cursor is on a modifier /
		// meta sibling — the first following sibling that is not one.
		var declIndex: Int = i;
		while (declIndex < siblings.length && MODIFIER_META_KINDS.contains(siblings[declIndex].kind)) declIndex++;
		if (declIndex >= siblings.length) return nodeSpan;

		// Walk back over the modifier / meta run that precedes the decl.
		var startIndex: Int = declIndex;
		while (startIndex > 0 && MODIFIER_META_KINDS.contains(siblings[startIndex - 1].kind)) startIndex--;

		// No modifier / meta run AND the cursor is the decl itself → not a
		// group; leave the span untouched (statements, list elements).
		if (startIndex == declIndex && declIndex == i) return nodeSpan;

		final startSpan: Null<Span> = siblings[startIndex].span;
		final declSpan: Null<Span> = siblings[declIndex].span;
		return startSpan == null || declSpan == null ? nodeSpan : new Span(startSpan.from, declSpan.to);
	}

	/**
	 * The parent of `target` within `root`'s subtree (by reference identity),
	 * or null when `target` is `root` itself or is absent. A depth-first walk
	 * — the query trees the ops resolve against are shallow, so this is cheap;
	 * it gives `declGroupSpan` the sibling context a `--select` / `--at`
	 * resolved node does not carry on its own.
	 */
	public static function parentOf(root: QueryNode, target: QueryNode): Null<QueryNode> {
		for (child in root.children) {
			if (child == target) return root;
			final found: Null<QueryNode> = parentOf(child, target);
			if (found != null) return found;
		}
		return null;
	}

	/**
	 * Remove `node` (with its modifier / meta group, via `declGroupSpan`)
	 * from `source` — the shared DELETE core, the structural inverse of
	 * `AddElement`. `parent` gives the sibling context `declGroupSpan` and
	 * the comma check need. The deletion span is the decl group, extended to
	 * swallow ONE separating comma when the slot is a comma list (a comma
	 * adjacent in source, or `parent` is a `COMMA_CONTAINER_KINDS`) — else
	 * (statement / case / member / import lists) just the group, since each
	 * element is self-terminated and the whole-file re-emit fixes residual
	 * whitespace. Funnels through `canonicalize` with an empty replacement,
	 * so the result is writer-formatted and re-parse-validated exactly like
	 * the insert ops; the source is canonical-gated unless `reformat`.
	 */
	public static function deleteNode(
		source: String, node: QueryNode, parent: Null<QueryNode>, reformat: Bool, plugin: GrammarPlugin, withDoc: Bool = false,
		?optsJson: String
	): EditResult {
		final nodeSpan: Null<Span> = node.span;
		if (nodeSpan == null) return Err('the node to remove has no source span');
		final group: Span = declGroupSpan(node, parent, nodeSpan);
		// `--with-doc` extends the removed range back over a leading doc / block
		// comment so a documented member's `/** */` is removed with it (else the
		// comment is orphaned). The line/comma extension then runs on top.
		final span: Span = withDoc ? docExtendedSpan(source, group) : group;

		var isComma: Bool = adjacentToComma(source, span);
		if (!isComma && parent != null) isComma = COMMA_CONTAINER_KINDS.contains(parent.kind);

		final delSpan: Span = isComma ? commaExtendedSpan(source, span) : lineExtendedSpan(source, span);
		return canonicalize(source, [{ span: delSpan, text: '' }], reformat, plugin, optsJson);
	}

	/**
			 * Extend `span` backward to include an immediately-preceding block / doc
			 * comment (a `/*`-opened comment, including the `/**` doc form) — the
			 * leading trivia the grammar attaches to a declaration but keeps OUTSIDE
			 * its node span, so a replace / remove can carry (or rewrite) the
			 * declaration's documentation. Scans back over whitespace from `span.from`;
			 * if the preceding token closes a block comment, extends to that comment's
			 * `/**
		 * Extend `span` backward to include the whole run of immediately-preceding
		 * block / doc comments (each a `/*`-opened comment, including the `/**` doc
		 * form) — the leading trivia the grammar attaches to a declaration but keeps
		 * OUTSIDE its node span, so a replace / remove can carry (or rewrite) the
		 * declaration's documentation. Scans back over whitespace from `span.from`;
		 * while the preceding token closes a block comment it extends to that
		 * comment's `/**
	 * Extend `span` backward over the declaration's leading doc / block comment —
	 * the trivia the grammar attaches to a declaration but keeps OUTSIDE its node
	 * span, so a replace / remove can carry (or rewrite) the documentation. Scans
	 * back over whitespace from `span.from`; the comment immediately above the node
	 * (a `/*`-opened comment, doc or plain block) is absorbed as before, then the
	 * walk keeps going back ONLY across further `/**` DOC comments — a stray
	 * duplicate doc left by an earlier edit — so a stacked duplicate is cleaned up
	 * as one unit while a DISTINCT preceding block comment (a license header or
	 * section banner above the doc) is left intact. Returns the span unchanged when
	 * only whitespace or a non-comment token precedes. Line-comment (double-slash)
	 * doc runs are not handled (v1); the re-parse gate validates the result either
	 * way.
	 */
	public static function docExtendedSpan(source: String, span: Span): Span {
		var from: Int = span.from;
		var first: Bool = true;
		while (true) {
			var i: Int = from - 1;
			while (i >= 0 && isSpace(StringTools.fastCodeAt(source, i))) i--;
			// The last non-space byte before this point must be the `/` of a `*/` close.
			if (i < 1 || StringTools.fastCodeAt(source, i) != '/'.code || StringTools.fastCodeAt(source, i - 1) != '*'.code) break;
			final open: Int = source.lastIndexOf('/*', i - 1);
			if (open < 0) break;
			// First comment (the decl's own doc) is absorbed unconditionally; any
			// further comment back is absorbed only if it too is a `/**` doc, so a
			// plain `/*` license / section block above the doc survives.
			if (!first && !(open + 2 < source.length && StringTools.fastCodeAt(source, open + 2) == '*'.code)) break;
			from = open;
			first = false;
		}
		return from == span.from ? span : new Span(from, span.to);
	}

	/**
	 * Extend `span` to the whole physical line when the element is ALONE on
	 * it — swallow the leading indentation (same-line whitespace back to the
	 * line start) and the trailing newline. Without this, deleting a
	 * statement / member / import leaves its line as blank whitespace, which
	 * the trivia-preserving writer keeps as an empty line. When the element
	 * shares its line with other content (it does not start AND end the line)
	 * the span is returned unchanged, so a sibling on the same line is not
	 * touched — the writer re-emit then tidies the residual spacing.
	 */
	public static function lineExtendedSpan(source: String, span: Span): Span {
		var from: Int = span.from;
		while (from > 0) {
			final c: Int = StringTools.fastCodeAt(source, from - 1);
			if (c == ' '.code || c == '\t'.code)
				from--
			else
				break;
		}
		final startsLine: Bool = from == 0 || StringTools.fastCodeAt(source, from - 1) == '\n'.code;

		var to: Int = span.to;
		while (to < source.length) {
			final c: Int = StringTools.fastCodeAt(source, to);
			if (c == ' '.code || c == '\t'.code || c == '\r'.code)
				to++
			else
				break;
		}
		final endsLine: Bool = to >= source.length || StringTools.fastCodeAt(source, to) == '\n'.code;
		if (endsLine && to < source.length) to++;

		return startsLine && endsLine ? new Span(from, to) : span;
	}

	/**
	 * Is the element at `span` immediately adjacent to a `,` — the next
	 * non-whitespace byte after `span.to`, or the previous before `span.from`,
	 * is a comma? True ⇒ the element sits in a comma-separated list (catches a
	 * comma container not in `COMMA_CONTAINER_KINDS`, for any list with at
	 * least two elements). Shared by `add-element` and `deleteNode`.
	 */
	public static function adjacentToComma(source: String, span: Span): Bool {
		var i: Int = span.to;
		while (i < source.length && isSpace(StringTools.fastCodeAt(source, i))) i++;
		if (i < source.length && StringTools.fastCodeAt(source, i) == ','.code) return true;

		var j: Int = span.from - 1;
		while (j >= 0 && isSpace(StringTools.fastCodeAt(source, j))) j--;
		return j >= 0 && StringTools.fastCodeAt(source, j) == ','.code;
	}

	/**
	 * Is every node kind in `node`'s subtree side-effect-free per `SAFE_KINDS`?
	 * A strict WHITELIST: an unknown kind fails the walk, so the verdict is
	 * conservative — a missed-but-safe kind costs a spurious `false`, never an
	 * unsafe `true`. Calls, field / index access, object / array / map literals,
	 * lambdas, `new`, assignments, increment / decrement, and interpolated
	 * strings embedding any of these all fall outside the whitelist and yield
	 * `false`.
	 */
	public static function isSideEffectFree(node: QueryNode): Bool {
		var safe: Bool = true;
		function walk(n: QueryNode): Void {
			if (!safe) return;
			if (!isSafeKind(n.kind)) {
				safe = false;
				return;
			}
			for (c in n.children) walk(c);
		}
		walk(node);
		return safe;
	}

	/**
	 * Does `name` occur as a word-boundary identifier token within
	 * `source[from, end)` at an offset that lies inside none of `excluded`?
	 * The conservative "is this name referenced" primitive shared by the
	 * dead-code checks: `unused-import` scans the whole file excluding the
	 * import statements; `unused-local` scans a declaration's enclosing scope
	 * excluding the declaration itself. Word-boundary = a non-identifier char on
	 * both sides, so `name` does not match inside `nameSuffix`. A textual scan
	 * (not an AST projection) is deliberate: it catches reference forms the
	 * grammar hides under non-obvious ctors (`'$name'` simple interpolation,
	 * macro reification) at the cost of also counting the name in comments /
	 * strings — which only ever keeps a binding, never wrongly deletes one.
	 * `end` is clamped to the source length.
	 */
	public static function referencedInRange(source: String, name: String, from: Int, end: Int, excluded: Array<Span>): Bool {
		final len: Int = name.length;
		if (len == 0) return false;
		final stop: Int = end <= source.length ? end : source.length;
		var i: Int = from;
		while (i + len <= stop) {
			final at: Int = source.indexOf(name, i);
			if (at < 0 || at + len > stop) return false;
			final beforeOk: Bool = at == 0 || !isIdentChar(StringTools.fastCodeAt(source, at - 1));
			final afterIdx: Int = at + len;
			final afterOk: Bool = afterIdx >= source.length || !isIdentChar(StringTools.fastCodeAt(source, afterIdx));
			if (beforeOk && afterOk && !offsetWithinAny(at, excluded)) return true;
			i = at + 1;
		}
		return false;
	}

	/**
	 * Format `text` into a doc-comment block, one ` * ` line per line. Leading /
	 * trailing blank lines of the payload are trimmed (a stdin / heredoc payload
	 * always carries a trailing newline — an edge blank is a delivery artifact,
	 * never an intended empty doc line); INTERNAL blank lines are kept as
	 * paragraph breaks.
	 */
	public static function docComment(text: String): String {
		final lines: Array<String> = trimBlankEdges(text.split('\n'));
		final buf: StringBuf = new StringBuf();
		buf.add('/**\n');
		for (line in lines) buf.add(line == '' ? ' *\n' : ' * $line\n');
		buf.add(' */');
		return buf.toString();
	}

	/**
	 * The span of the comment at `cursor`, or null if the cursor is not on a
	 * comment. A block comment is returned whole; a full-line line comment is
	 * merged with the contiguous run of full-line line comments directly above
	 * and below it (no blank line, no code between), so a line-comment block is
	 * addressed as one unit; a trailing line comment after code is returned
	 * alone. String literals are skipped, so an opener inside a string is not
	 * mistaken for a comment.
	 */
	public static function commentBlockAt(source: String, cursor: Int): Null<Span> {
		final toks: Array<{ from: Int, to: Int, isLine: Bool }> = collectCommentTokens(source);
		var hitIdx: Int = -1;
		for (k in 0...toks.length) if (cursor >= toks[k].from && cursor < toks[k].to) {
			hitIdx = k;
			break;
		}
		if (hitIdx < 0) return null;
		final hit: { from: Int, to: Int, isLine: Bool } = toks[hitIdx];
		if (!hit.isLine || !isFullLineComment(source, hit.from)) return new Span(hit.from, hit.to);
		var lo: Int = hitIdx;
		while (lo > 0 && contiguousLineComments(source, toks[lo - 1], toks[lo])) lo--;
		var hi: Int = hitIdx;
		while (hi < toks.length - 1 && contiguousLineComments(source, toks[hi], toks[hi + 1])) hi++;
		return new Span(toks[lo].from, toks[hi].to);
	}

	/**
	 * Scan `source` for every comment token (line and block), skipping string
	 * literals so an opener inside a string is not a comment. Mirrors the `apq
	 * lit` comment walker. Each token is `{ from, to, isLine }`.
	 */
	public static function collectCommentTokens(source: String): Array<{ from: Int, to: Int, isLine: Bool }> {
		final out: Array<{ from: Int, to: Int, isLine: Bool }> = [];
		final n: Int = source.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c == '"'.code || c == "'".code) {
				final quote: Int = c;
				i++;
				while (i < n) {
					final ch: Int = StringTools.fastCodeAt(source, i);
					if (ch == '\\'.code) {
						i += 2;
						continue;
					}
					if (ch == quote) {
						i++;
						break;
					}
					i++;
				}
				continue;
			}
			if (c == '/'.code && i + 1 < n) {
				final next: Int = StringTools.fastCodeAt(source, i + 1);
				if (next == '/'.code) {
					final start: Int = i;
					i += 2;
					while (i < n && StringTools.fastCodeAt(source, i) != '\n'.code) i++;
					out.push({ from: start, to: i, isLine: true });
					continue;
				}
				if (next == '*'.code) {
					final start: Int = i;
					i += 2;
					var closed: Bool = false;
					while (i + 1 < n) {
						if (StringTools.fastCodeAt(source, i) == '*'.code && StringTools.fastCodeAt(source, i + 1) == '/'.code) {
							i += 2;
							closed = true;
							break;
						}
						i++;
					}
					if (!closed) i = n;
					out.push({ from: start, to: i, isLine: false });
					continue;
				}
			}
			i++;
		}
		return out;
	}

	/**
	 * Body span of a comment token — the text between the opener (`//` or the
	 * block opener) and the closer, with a closed block's trailing delimiter
	 * excluded and a line comment running to the newline. Shared by the comment
	 * finder (`Cli.appendCommentHits`) and the comment rewriter (`CommentRewrite`).
	 */
	public static function commentBody(source: String, tok: { from: Int, to: Int, isLine: Bool }): Span {
		final closed: Bool = !tok.isLine && tok.to >= tok.from + 4 && StringTools.fastCodeAt(source, tok.to - 2) == '*'.code // noqa
			&& StringTools.fastCodeAt(source, tok.to - 1) == '/'.code;
		final bodyEnd: Int = closed ? tok.to - 2 : tok.to;
		return new Span(tok.from + 2, bodyEnd);
	}

	/**
	 * Whether a private member of the type named `owner` is confined to its file —
	 * i.e. unreachable from outside it, so an in-file analysis (rename, unused
	 * detection) sees every possible reference. False when any file skip-parsed (it
	 * could hide a subtype or `@:access` the index never saw), when a subtype or
	 * `@:access` grant names the type, or when the file carries an `@:allow` (which
	 * can expose its privates to another type). Conservative: any doubt is false.
	 */
	public static function isPrivateMemberConfined(owner: String, source: String, index: SymbolIndex): Bool {
		return index.skippedFiles()
			.length <= 0 && !index.hasSubtype(owner) && !index.hasAccessGrant(owner) && source.indexOf('@:allow') < 0;
	}

	/**
	 * Whether spanned nodes `a` and `b` cover the same (trimmed) source text. Both
	 * must carry a span — a null span yields `false`, since the texts cannot be
	 * compared.
	 */
	public static function sameSource(a: QueryNode, b: QueryNode, source: String): Bool {
		final sa: Null<Span> = a.span;
		final sb: Null<Span> = b.span;
		return sa != null && sb != null
			&& StringTools.trim(source.substring(sa.from, sa.to)) == StringTools.trim(source.substring(sb.from, sb.to));
	}

	/** Whether the subtree rooted at `node` contains any node of kind `kind`. */
	public static function subtreeContainsKind(node: QueryNode, kind: String): Bool {
		if (node.kind == kind) return true;
		for (c in node.children) if (subtreeContainsKind(c, kind)) return true;
		return false;
	}

	/**
	 * Whether the subtree rooted at `node` contains — within the same scope — any node
	 * whose kind is in `kinds`, descending through children but STOPPING at (and not
	 * matching) a node whose kind is in `stopKinds`. The root `node` itself is not
	 * tested; only its descendants. The kind-set + stop-set generalization of
	 * `subtreeContainsKind`: the stop-set bounds the walk to one scope — e.g. a
	 * value-return / throw search that must not cross into a nested function or lambda.
	 */
	public static function subtreeContainsKindStopping(node: QueryNode, kinds: Array<String>, stopKinds: Array<String>): Bool {
		return node.children.exists(
			child -> !stopKinds.contains(child.kind) && (kinds.contains(child.kind) || subtreeContainsKindStopping(child, kinds, stopKinds))
		);
	}

	/**
	 * Index every node of one of `kinds` by its `from:to` span key — the lookup table
	 * a span-keyed-violation `fix` uses to recover the AST node behind a stored span.
	 * Shared by the `redundant-cast` / `redundant-null-coalescing` autofixes.
	 */
	public static function indexNodesByKind(node: QueryNode, kinds: Array<String>, out: Map<String, QueryNode>): Void {
		if (kinds.contains(node.kind)) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = node;
		}
		for (c in node.children) indexNodesByKind(c, kinds, out);
	}

	/**
	 * Drop every edit whose span is fully contained in another edit's span,
	 * keeping the outer (larger) one. Span-deletion edits from independent sources
	 * — several checks batched by `apq lint --fix`, or one check's nested findings
	 * (a dead run inside a dead run) — can nest; applying nested deletions blindly
	 * corrupts the source. Removing the contained edit is correct for deletions:
	 * the outer deletion already subsumes it. Equal spans keep the earliest index.
	 */
	public static function dropContainedEdits(edits: Array<{ span: Span, text: String }>): Array<{ span: Span, text: String }> {
		return [for (i in 0...edits.length) if (!isContainedEdit(edits, i)) edits[i]];
	}

	/**
	 * Does `source` reference `name` as a member access — a `.name` with a `.`
	 * immediately before and a word boundary after? This is the form a `using`'s
	 * extension method takes whether it is called (`s.trim()`) or captured as a
	 * value (`var f = s.trim`), so the `unused-import` check uses it to decide a
	 * `using` is live. Deliberately does NOT require a trailing `(`: a captured
	 * function reference is just as much a use, and skipping the check also avoids
	 * missing a call separated from its name by a comment. Like `referencedInRange`
	 * it is a textual scan that also counts the form inside a comment / string —
	 * which only ever keeps a `using`, never wrongly deletes one (the safe
	 * direction for an autofix).
	 */
	public static function methodCalledInSource(source: String, name: String): Bool {
		final len: Int = name.length;
		if (len == 0) return false;
		var i: Int = 0;
		while (true) {
			final at: Int = source.indexOf(name, i);
			if (at < 0) return false;
			i = at + 1;
			if (at == 0 || StringTools.fastCodeAt(source, at - 1) != '.'.code) continue;
			final afterIdx: Int = at + len;
			if (afterIdx >= source.length || !isIdentChar(StringTools.fastCodeAt(source, afterIdx))) return true;
		}
	}

	/**
	 * Normalize a comment BODY for cross-line literal matching: fold each line
	 * continuation — a `\n` or `\r\n`, the following whitespace, blank lines, and
	 * one ` * ` doc-marker per line — into a single space, so a phrase wrapped
	 * across two ` * ` lines reads as one run. Returns the normalized text plus a
	 * `map` from each normalized index to the original body offset it came from,
	 * with `map[text.length] == body.length`, so a match found in the normalized
	 * text projects back to a span in the original body.
	 */
	public static function normalizeCommentBody(body: String): { text: String, map: Array<Int> } {
		final buf: StringBuf = new StringBuf();
		final map: Array<Int> = [];
		final n: Int = body.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(body, i);
			final crlf: Bool = c == '\r'.code && i + 1 < n && StringTools.fastCodeAt(body, i + 1) == '\n'.code;
			if (c == '\n'.code || crlf) {
				final runStart: Int = i;
				i = skipContinuation(body, (crlf ? i + 1 : i) + 1, n);
				buf.addChar(' '.code);
				map.push(runStart);
			} else {
				buf.addChar(c);
				map.push(i);
				i++;
			}
		}
		map.push(n);
		return { text: buf.toString(), map: map };
	}

	/**
	 * Whether the condition subtree `cond` contains a null-narrowing guard: an
	 * identifier compared against null (`x == null` / `x != null`) that is then
	 * REUSED elsewhere in the same condition (`x.f`, `x[i]`, `x()`, `g(x)`, a bare
	 * `x`, …). Haxe narrows such an `x` only inside the `if`-condition, so a check
	 * that flattens the condition into a `||` / ternary `return` loses the
	 * narrowing and the result fails to compile under `@:nullSafety(Strict)` — the
	 * finding must be skipped. Conservative: a reuse in ANY position counts (it
	 * over-skips a comparison-only reuse like `x != null && x == y`, which is
	 * actually safe to flatten — never a compile break), and a grammar without the
	 * null/equality kinds yields false.
	 */
	public static function hasNullNarrowingGuard(cond: QueryNode, shape: RefShape): Bool {
		final nullKind: Null<String> = shape.nullLiteralKind;
		if (nullKind == null) return false;
		final identCount: Map<String, Int> = [];
		final checkCount: Map<String, Int> = [];
		tallyGuardIdents(cond, shape.identKind, nullKind, shape.eqKind, shape.notEqKind, identCount, checkCount);
		for (name => total in identCount) {
			// Null-checked (`checks != null`) AND reused beyond its own null-comparison
			// operand(s) (`total > checks`): the reuse relies on the in-condition narrowing.
			final checks: Null<Int> = checkCount[name];
			if (checks != null && total > checks) return true;
		}
		return false;
	}

	/**
	 * Whether any edit in `candidate` overlaps (intersects) any edit in `accepted` —
	 * the cross-check guard the `--fix` loop uses to keep a check's edits atomic. A
	 * check whose edits intersect an already-accepted check's edits is deferred whole
	 * to the next fixed-point pass, so a partial application (e.g. a signature edit
	 * without its matching call-site edit) can never land.
	 */
	public static function editsOverlapAny(
		candidate: Array<{ span: Span, text: String }>, accepted: Array<{ span: Span, text: String }>
	): Bool {
		return candidate.exists(c -> accepted.exists(a -> c.span.from < a.span.to && a.span.from < c.span.to));
	}

	/**
	 * Whether `operand` (parentheses unwrapped) is a provably non-null `Bool` — a node
	 * whose kind is in `boolOpKinds` (a comparison / `&&` / `||` / `!` result). Such a
	 * node can never be `Null<Bool>`, so combining it with boolean logic is sound under
	 * strict null-safety; an identifier, call, field access or literal is not provable
	 * without types. Shared by `comparison-to-boolean` and `prefer-ternary-return`.
	 */
	public static function provablyBoolOperand(operand: QueryNode, boolOpKinds: Array<String>, parenKind: Null<String>): Bool {
		var n: QueryNode = operand;
		while (parenKind != null && n.kind == parenKind && n.children.length == 1) n = n.children[0];
		return boolOpKinds.contains(n.kind);
	}

	/**
	 * Visit every mutable `var` field member of every visibility-bearing type in
	 * `files`, with the enclosing type's simple name, the field node, its source, file,
	 * and whether its preceding modifier run marks it exported (non-default visibility).
	 * The shared container walk behind the field-immutability checks
	 * (`prefer-final-field` private path, `prefer-final-public-field`,
	 * `prefer-read-only-field`) — each filters by `exported` and applies its own proof.
	 * Skip-parse tolerant; a grammar lacking the visibility kind-sets yields nothing.
	 */
	public static function eachFieldMember(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin,
		visit: (owner:String, field:QueryNode, source:String, file:String, exported:Bool) -> Void
	): Void {
		final shape: RefShape = plugin.refShape();
		final containers: Array<String> = shape.visibilityContainerKinds ?? [];
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final mutableFields: Array<String> = shape.mutableFieldDeclKinds ?? [];
		final visibility: Array<String> = shape.visibilityModifierKinds ?? [];
		final defaultVis: Null<String> = shape.defaultVisibilityModifierText;
		if (containers.length == 0 || members.length == 0 || mutableFields.length == 0 || visibility.length == 0 || defaultVis == null)
			return;
		for (entry in files) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (_: Exception) null;
			if (tree != null)
				walkFieldContainers(tree, entry.source, entry.file, containers, members, mutableFields, visibility, defaultVis, visit);
		}
	}

	/**
	 * The `var` → `final` keyword-swap edits for each non-null span in `spans` (a field
	 * decl whose span starts at the `var` keyword). Shared by the `prefer-final-field`
	 * and `prefer-final-public-field` autofixes. Each edit fires only when the bytes at
	 * the span start are literally `var`, so an unexpected span is silently skipped.
	 */
	public static function varKeywordToFinalEdits(source: String, spans: Array<Null<Span>>): Array<{ span: Span, text: String }> {
		final keyword: String = 'var';
		final edits: Array<{ span: Span, text: String }> = [];
		for (span in spans) if (span != null) {
			final end: Int = span.from + keyword.length;
			if (source.substring(span.from, end) != keyword) continue;
			edits.push({ span: new Span(span.from, end), text: 'final' });
		}
		return edits;
	}

	/**
	 * The class-like container kinds — `visibilityContainerKinds` minus the
	 * abstract-without-instance-fields kinds (`AbstractDecl` / `EnumAbstractDecl`),
	 * whose members share one underlying `this` rather than declared instance fields.
	 * The scope in which a constructor-initialised field can be moved to its declaration.
	 */
	public static function classLikeContainerKinds(shape: RefShape): Array<String> {
		final all: Array<String> = shape.visibilityContainerKinds ?? [];
		return [for (k in all) if (k != 'AbstractDecl' && k != 'EnumAbstractDecl') k];
	}

	/**
	 * The single constructor (`FnMember` named `new`) directly declared in `container`,
	 * or null when there is not exactly one — a multiple-constructor (macro-generated)
	 * class is skipped so a field's init timing stays a plain single `new`.
	 */
	public static function soleConstructor(container: QueryNode, shape: RefShape): Null<QueryNode> {
		final ctorName: Null<String> = shape.constructorName;
		final members: Array<String> = shape.memberDeclKinds ?? [];
		if (ctorName == null) return null;
		var found: Null<QueryNode> = null;
		for (child in container.children) if (members.contains(child.kind) && child.name == ctorName) {
			if (found != null) return null;
			found = child;
		}
		return found;
	}

	/**
	 * The single unconditional top-level constructor statement that assigns `field`
	 * (`field = expr` or `this.field = expr`, a DIRECT child of the constructor's block
	 * body — not nested in a branch / loop / closure), paired with the assignment's
	 * right-hand side and the assignment target's span, or null when there is not
	 * exactly one. `container` scopes binding resolution, so a bare `field =` that
	 * resolves to a shadowing constructor local / parameter does NOT match this field.
	 */
	public static function soleConstructorFieldInit(
		container: QueryNode, ctor: QueryNode, field: QueryNode, shape: RefShape
	): Null<{ stmt: QueryNode, rhs: QueryNode, target: Span }> {
		final bodyKind: Null<String> = shape.blockBodyKind;
		final stmtKind: Null<String> = shape.exprStatementKind;
		final assignKind: Null<String> = shape.assignKind;
		final fieldSpan: Null<Span> = field.span;
		final fieldName: Null<String> = field.name;
		if (bodyKind == null || stmtKind == null || assignKind == null || fieldSpan == null || fieldName == null) return null;
		final fieldFrom: Int = fieldSpan.from;
		final body: Null<QueryNode> = ctor.children.find(c -> c.kind == bodyKind);
		if (body == null) return null;
		var match: Null<{ stmt: QueryNode, rhs: QueryNode, target: Span }> = null;
		for (stmt in body.children) if (stmt.kind == stmtKind && stmt.children.length >= 1) {
			final assign: QueryNode = stmt.children[0];
			if (assign.kind != assignKind || assign.children.length < 2) continue;
			final target: QueryNode = assign.children[0];
			final tSpan: Null<Span> = target.span;
			if (tSpan == null) continue;
			if (!ctorTargetIsField(target, fieldFrom, fieldName, container, shape)) continue;
			if (match != null) return null;
			match = { stmt: stmt, rhs: assign.children[1], target: tSpan };
		}
		return match;
	}

	/**
	 * The class-like container and the field member declared at `fieldFrom`, found by
	 * re-walking `tree` — the fix-side re-derivation from a violation's span (a
	 * violation carries only its file and span, so the container and field are
	 * recovered from the parsed source).
	 */
	public static function classLikeFieldAt(
		tree: QueryNode, fieldFrom: Int, shape: RefShape
	): Null<{ container: QueryNode, field: QueryNode }> {
		return findFieldContainer(tree, fieldFrom, classLikeContainerKinds(shape), shape.fieldDeclKinds ?? []);
	}

	/**
	 * Locate, from a parsed `tree`, the field at `fieldFrom` together with its
	 * class-like container and the single unconditional top-level constructor statement
	 * that initialises it — the shared entry point for `field-init-at-declaration`'s fix
	 * and `prefer-final-field`'s no-initializer case. Null when the field is not in a
	 * class-like container, the container has no single constructor, or the field is not
	 * assigned by exactly one top-level constructor statement.
	 */
	public static function constructorFieldInitAt(tree: QueryNode, fieldFrom: Int, shape: RefShape): Null<{
		container: QueryNode,
		field: QueryNode,
		stmt: QueryNode,
		rhs: QueryNode,
		target: Span
	}> {
		final loc: Null<{ container: QueryNode, field: QueryNode }> = classLikeFieldAt(tree, fieldFrom, shape);
		if (loc == null) return null;
		final ctor: Null<QueryNode> = soleConstructor(loc.container, shape);
		if (ctor == null) return null;
		final init: Null<{ stmt: QueryNode, rhs: QueryNode, target: Span }> = soleConstructorFieldInit(
			loc.container, ctor, loc.field, shape
		);
		return init == null ? null : {
			container: loc.container,
			field: loc.field,
			stmt: init.stmt,
			rhs: init.rhs,
			target: init.target
		};
	}

	/**
	 * The offset just before a field declaration's terminating `;`, where a moved
	 * `= <init>` is spliced. A `VarMember` / `FinalMember` span INCLUDES the trailing
	 * `;`, so the insert goes before it rather than at `span.to`; a span with no
	 * terminating `;` (skip-parse edge) falls back to `span.to`.
	 */
	public static function fieldDeclInitInsertPos(source: String, fieldSpan: Span): Int {
		var i: Int = fieldSpan.to - 1;
		while (i > fieldSpan.from) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c == ' '.code || c == '\t'.code || c == '\r'.code || c == '\n'.code) {
				i--;
				continue;
			}
			break;
		}
		return (i > fieldSpan.from && StringTools.fastCodeAt(source, i) == ';'.code) ? i : fieldSpan.to;
	}

	/**
	 * Whether `field` is a plain field with an initializer and is NOT a property — the
	 * shared candidate-shape gate of the `final`-conversion field checks. False when the
	 * field has no initializer (its first child carries no span) or its head before the
	 * initializer contains a `(` (a property accessor clause).
	 */
	public static function isInitializedNonPropertyField(source: String, field: QueryNode): Bool {
		final span: Null<Span> = field.span;
		if (span == null || field.children.length < 1) return false;
		final initSpan: Null<Span> = field.children[0].span;
		return initSpan != null && source.substring(span.from, initSpan.from).indexOf('(') < 0;
	}

	/**
	 * Whether a never-reassigned `var` (field or local) named `name` with declared
	 * simple type `declType` must STAY mutable because a method call on it may reassign
	 * an `abstract`'s underlying `this` — a mutation the assignment-operator write scans
	 * cannot see (`abstract Step(Int) { function next():Void this = this + 1; }` mutated
	 * only via `_s.next()`). Finalizing such a binding produces code the compiler rejects
	 * ("Cannot modify abstract value of final field").
	 *
	 * True (keep the `var`) when `name` has a method call in `source` outside its own
	 * declaration `exclude` AND its type is either an `abstract` resolved in `index`
	 * (`abstractKinds`) or an UNRESOLVED non-stdlib type whose abstractness cannot be
	 * ruled out. False — the `final` suggestion stays sound and useful — for a resolved
	 * non-abstract type (a class method does not reassign the binding), a stdlib value
	 * type, an untyped binding, or no method call. Conservative: it only ever KEEPS a
	 * `var`, never produces a wrong `final`.
	 */
	public static function abstractMethodMayMutate(
		source: String, name: String, declType: Null<String>, exclude: Span, index: SymbolIndex, abstractKinds: Array<String>
	): Bool {
		if (declType == null || !methodCalledOn(source, name, exclude)) return false;
		final resolvedAbstract: Null<Bool> = index.isAbstractType(declType, abstractKinds);
		return resolvedAbstract ?? !finalSafeStdlibTypes.contains(declType);
	}

	/** Index of the first byte at or after `pos` that is neither whitespace nor inside a line or block comment. */
	public static function skipForwardTrivia(source: String, pos: Int): Int {
		final n: Int = source.length;
		var i: Int = pos;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (isSpace(c)) {
				i++;
				continue;
			}
			if (c == '/'.code && i + 1 < n) {
				final c1: Int = StringTools.fastCodeAt(source, i + 1);
				if (c1 == '/'.code) {
					i += 2;
					while (i < n && StringTools.fastCodeAt(source, i) != '\n'.code) i++;
					continue;
				}
				if (c1 == '*'.code) {
					i += 2;
					while (
						i + 1 < n && !(StringTools.fastCodeAt(source, i) == '*'.code && StringTools.fastCodeAt(source, i + 1) == '/'.code)
					)
						i++;
					i += 2;
					continue;
				}
			}
			break;
		}
		return i;
	}

	/** Extend a member's `span` back over own-line leading comments and forward over a same-line trailing comment, yielding its full source slot. */
	public static function memberTriviaSpan(source: String, span: Span, comments: Array<{ from: Int, to: Int, isLine: Bool }>): Span {
		final from: Int = absorbLeadingComments(source, comments, span.from);
		var to: Int = span.to;
		final t: Null<{ from: Int, to: Int, isLine: Bool }> = firstCommentStartingAfter(comments, to);
		if (t != null && StringTools.trim(source.substring(to, t.from)) == '' && source.substring(to, t.from).indexOf('\n') < 0) to = t.to;
		return new Span(from, to);
	}

	/**
	 * The start offset of the contiguous own-line comment block immediately preceding the
	 * line that contains `pos` (only whitespace between the comments and that line), or that
	 * line's start when none exists. Lets a reorder absorb a doc comment sitting just before
	 * a `#if` directive into the conditional it documents.
	 */
	public static function leadingCommentBlockStart(source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, pos: Int): Int {
		return absorbLeadingComments(source, comments, lineStartOf(source, pos));
	}

	/**
	 * The offset just past the first token at `from` — the run of identifier characters
	 * when `from` is on one (a name / keyword), else the single delimiter / operator
	 * character. Lets a cursor land anywhere within a node's opening token and still
	 * resolve the node, matching the forgiving `ast --at` rather than an exact `span.from`.
	 */
	public static function firstTokenEnd(source: String, from: Int): Int {
		if (from < 0 || from >= source.length) return from;
		if (!isIdentChar(StringTools.fastCodeAt(source, from))) return from + 1;
		var i: Int = from + 1;
		while (i < source.length && isIdentChar(StringTools.fastCodeAt(source, i))) i++;
		return i;
	}

	/**
	 * The outermost node whose FIRST TOKEN the cursor falls within (the first in pre-order)
	 * together with its parent — the list element / member the cursor's first token
	 * identifies. The bound is EXCLUSIVE of the token's trailing boundary so a container's
	 * single-char delimiter (`[` / `{` / `(`) does not swallow the element beginning right
	 * after it; a column landing inside a name still resolves it. Null when no node's first
	 * token contains `cursor`. The tolerant twin of `nodeAtFrom` for the USER-cursor ops
	 * (`add-element`, `remove-element`); `nodeAtFrom` stays exact for the internal callers
	 * that pass an already-resolved binding span.
	 */
	public static function elementAtFrom(tree: QueryNode, source: String, cursor: Int): Null<{ node: QueryNode, parent: Null<QueryNode> }> {
		var result: Null<{ node: QueryNode, parent: Null<QueryNode> }> = null;
		function walk(node: QueryNode, parent: Null<QueryNode>): Void {
			if (result != null) return;
			final sp: Null<Span> = node.span;
			if (sp != null && cursor >= sp.from && cursor < firstTokenEnd(source, sp.from)) {
				result = { node: node, parent: parent };
				return;
			}
			for (c in node.children) {
				if (result != null) return;
				walk(c, node);
			}
		}
		walk(tree, null);
		return result;
	}

	/**
	 * Whether `text` contains a comma outside any `()`/`[]`/`{}` nesting and outside a
	 * string literal — the multi-declaration separator of `var i, j = n`. `<>` is
	 * deliberately not tracked (a generic type-parameter comma reads as top-level,
	 * which consumers treat conservatively).
	 */
	public static function hasTopLevelComma(text: String): Bool {
		var depth: Int = 0;
		var i: Int = 0;
		final n: Int = text.length;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(text, i);
			switch c {
				case '('.code | '['.code | '{'.code:
					depth++;
				case ')'.code | ']'.code | '}'.code:
					if (depth > 0) depth--;
				case '"'.code | "'".code:
					i = skipStringLiteral(text, i, c);
				case ','.code:
					if (depth == 0) return true;
				case _:
			}
			i++;
		}
		return false;
	}

	/**
	 * `lines` without its leading / trailing whitespace-only entries — the shared
	 * edge-trim behind `docComment`, `NewFile`'s `@@`-section bodies and the
	 * `fragmented-doc-comment` fix (internal blanks are kept).
	 */
	public static function trimBlankEdges(lines: Array<String>): Array<String> {
		final out: Array<String> = lines.copy();
		while (out.length > 0 && StringTools.trim(out[0]) == '') out.shift();
		while (out.length > 0 && StringTools.trim(out[out.length - 1]) == '') out.pop();
		return out;
	}

	/**
	 * Span starts of `container`'s member declarations that carry a `static`
	 * modifier (the modifier projects as a separate preceding sibling node).
	 * Shared by field-init-at-declaration and prefer-final-field: both must
	 * exempt statics from ctor-assignment reasoning (a static initializes at
	 * class-load, and `static final` requires a declaration initializer).
	 */
	public static function staticMemberFroms(container: QueryNode, shape: RefShape): Array<Int> {
		final staticKind: Null<String> = shape.staticModifierKind;
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final out: Array<Int> = [];
		if (staticKind == null) return out;
		var pending: Bool = false;
		for (child in container.children) {
			if (child.kind == staticKind)
				pending = true;
			else if (members.contains(child.kind)) {
				if (pending) {
					final sp: Null<Span> = child.span;
					if (sp != null) out.push(sp.from);
				}
				pending = false;
			}
		}
		return out;
	}

	/** Whether `target` (a constructor assignment's left-hand side) writes the field at `fieldFrom`. */
	private static function ctorTargetIsField(
		target: QueryNode, fieldFrom: Int, fieldName: String, container: QueryNode, shape: RefShape
	): Bool {
		final identKind: String = shape.identKind;
		final faKind: Null<String> = shape.fieldAccessKind;
		final selfText: Null<String> = shape.selfReferenceText;
		if (faKind != null && target.kind == faKind) {
			final recv: Null<QueryNode> = target.children.length > 0 ? target.children[0] : null;
			return target.name == fieldName && recv != null && recv.kind == identKind && selfText != null && recv.name == selfText;
		}
		if (target.kind == identKind) {
			final name: Null<String> = target.name;
			final span: Null<Span> = target.span;
			return name != null && span != null && TypeResolver.resolveBindingFrom(name, span, container, shape) == fieldFrom;
		}
		return false;
	}

	/** Recursively find the class-like container whose direct field member starts at `fieldFrom`. */
	private static function findFieldContainer(
		node: QueryNode, fieldFrom: Int, classLike: Array<String>, fields: Array<String>
	): Null<{ container: QueryNode, field: QueryNode }> {
		if (classLike.contains(node.kind)) for (child in node.children) if (fields.contains(child.kind)) {
			final sp: Null<Span> = child.span;
			if (sp != null && sp.from == fieldFrom) return { container: node, field: child };
		}
		for (child in node.children) {
			final hit: Null<{ container: QueryNode, field: QueryNode }> = findFieldContainer(child, fieldFrom, classLike, fields);
			if (hit != null) return hit;
		}
		return null;
	}

	/**
	 * Whether a word-bounded occurrence of `name` outside `exclude` is the receiver of a
	 * method call — followed, past whitespace and comments, by `.`, then an identifier,
	 * then `(`. Matches `name.m(...)` and `this.name.m(...)` alike (the `name` token in
	 * `this.name` is bounded by the preceding `.`). A plain field read (`name.x`) or a
	 * method reference without a call (`name.m`) is not a match — only a `this`-mutating
	 * abstract method call is a write the assignment scans miss.
	 */
	private static function methodCalledOn(source: String, name: String, exclude: Span): Bool {
		final n: Int = source.length;
		final len: Int = name.length;
		if (len == 0) return false;
		var from: Int = 0;
		while (true) {
			final idx: Int = source.indexOf(name, from);
			if (idx < 0) return false;
			from = idx + len;
			final boundedBefore: Bool = idx == 0 || !isIdentChar(StringTools.fastCodeAt(source, idx - 1));
			final boundedAfter: Bool = from >= n || !isIdentChar(StringTools.fastCodeAt(source, from));
			if (boundedBefore && boundedAfter && (idx < exclude.from || idx >= exclude.to) && callFollows(source, from)) return true;
		}
	}

	/** Whether the tokens starting at `pos` are `.` <identifier> ... `(` — a method call, ignoring interposed whitespace and comments. */
	private static function callFollows(source: String, pos: Int): Bool {
		final n: Int = source.length;
		var i: Int = skipForwardTrivia(source, pos);
		if (i >= n || StringTools.fastCodeAt(source, i) != '.'.code) return false;
		i = skipForwardTrivia(source, i + 1);
		if (i >= n || !isIdentStartChar(StringTools.fastCodeAt(source, i))) return false;
		while (i < n && isIdentChar(StringTools.fastCodeAt(source, i))) i++;
		i = skipForwardTrivia(source, i);
		return i < n && StringTools.fastCodeAt(source, i) == '('.code;
	}

	/**
	 * Extend `span` to also remove ONE separating comma so a comma list stays
	 * well-formed after the element is cut: the trailing comma (preferred) —
	 * the next non-whitespace byte after `span.to` — else the leading comma
	 * before `span.from` (the element was last). A single-element list has
	 * neither and the span is returned unchanged (`[a]` → `[]`). Surrounding
	 * whitespace is left to the writer re-emit.
	 */
	private static function commaExtendedSpan(source: String, span: Span): Span {
		var i: Int = span.to;
		while (i < source.length && isSpace(StringTools.fastCodeAt(source, i))) i++;
		if (i < source.length && StringTools.fastCodeAt(source, i) == ','.code) return new Span(span.from, i + 1);

		var j: Int = span.from - 1;
		while (j >= 0 && isSpace(StringTools.fastCodeAt(source, j))) j--;
		return j >= 0 && StringTools.fastCodeAt(source, j) == ','.code ? new Span(j, span.to) : span;
	}

	/**
	 * A node kind that contributes no side effect on its own: an enumerated
	 * `SAFE_KINDS` member, or any leaf whose kind ends with `Lit` / `StringExpr`
	 * (a literal payload not separately enumerated).
	 */
	private static inline function isSafeKind(kind: String): Bool {
		return SAFE_KINDS.contains(kind) || StringTools.endsWith(kind, 'Lit') || StringTools.endsWith(kind, 'StringExpr');
	}

	/** Is `offset` inside any of `spans` (`from`-inclusive, `to`-exclusive)? */
	private static function offsetWithinAny(offset: Int, spans: Array<Span>): Bool {
		for (s in spans) if (offset >= s.from && offset < s.to) return true;
		return false;
	}

	/** True if only whitespace precedes the byte at `from` on its line. */
	private static function isFullLineComment(source: String, from: Int): Bool {
		var i: Int = from - 1;
		while (i >= 0 && StringTools.fastCodeAt(source, i) != '\n'.code) {
			if (!isSpace(StringTools.fastCodeAt(source, i))) return false;
			i--;
		}
		return true;
	}

	/**
	 * True if two comment tokens are full-line line comments separated by a
	 * single line break (no blank line, no code) — members of one contiguous
	 * line-comment block.
	 */
	private static function contiguousLineComments(
		source: String, a: { from: Int, to: Int, isLine: Bool }, b: { from: Int, to: Int, isLine: Bool }
	): Bool {
		if (!a.isLine || !b.isLine) return false;
		if (!isFullLineComment(source, a.from) || !isFullLineComment(source, b.from)) return false;
		var newlines: Int = 0;
		for (k in a.to ... b.from) {
			final c: Int = StringTools.fastCodeAt(source, k);
			if (c == '\n'.code)
				newlines++;
			else if (!isSpace(c))
				return false;
		}
		return newlines == 1;
	}

	/** True when `edits[i]` is contained in another edit (the outer one is kept). */
	private static function isContainedEdit(edits: Array<{ span: Span, text: String }>, i: Int): Bool {
		final e: Span = edits[i].span;
		for (j in 0...edits.length) if (j != i) {
			final o: Span = edits[j].span;
			final contains: Bool = o.from <= e.from && e.to <= o.to;
			final strictlyBigger: Bool = o.from < e.from || e.to < o.to;
			if (contains && (strictlyBigger || j < i)) return true;
		}
		return false;
	}

	/**
	 * Skip a comment line-continuation starting at `from` (just past a `\n`): any
	 * further whitespace and blank lines, plus ONE ` * ` doc-marker per line.
	 * Returns the index of the first content character (or `n`).
	 */
	private static function skipContinuation(body: String, from: Int, n: Int): Int {
		var i: Int = from;
		var markerSeen: Bool = false;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(body, i);
			if (c == ' '.code || c == '\t'.code || c == '\r'.code) {
				i++;
			} else if (c == '\n'.code) {
				i++;
				markerSeen = false;
			} else if (c == '*'.code && !markerSeen) {
				i++;
				markerSeen = true;
			} else {
				break;
			}
		}
		return i;
	}

	/** Tally, over `node`, every IdentExpr occurrence and every null-comparison ident operand. */
	private static function tallyGuardIdents(
		node: QueryNode, identKind: String, nullKind: String, eqKind: Null<String>, notEqKind: Null<String>, identCount: Map<String, Int>,
		checkCount: Map<String, Int>
	): Void {
		if (node.kind == identKind) {
			final name: Null<String> = node.name;
			if (name != null) bumpCount(identCount, name);
		}
		if ((eqKind != null && node.kind == eqKind) || (notEqKind != null && node.kind == notEqKind)) {
			final ident: Null<String> = nullComparedIdent(node, identKind, nullKind);
			if (ident != null) bumpCount(checkCount, ident);
		}
		for (c in node.children) tallyGuardIdents(c, identKind, nullKind, eqKind, notEqKind, identCount, checkCount);
	}

	/** Increment the integer counter for `key`. */
	private static inline function bumpCount(map: Map<String, Int>, key: String): Void {
		final cur: Null<Int> = map[key];
		map[key] = (cur ?? 0) + 1;
	}

	/** The identifier compared against null in `node` (one operand an ident, the other null), or null. */
	private static function nullComparedIdent(node: QueryNode, identKind: String, nullKind: String): Null<String> {
		if (node.children.length != 2) return null;
		final a: QueryNode = node.children[0];
		final b: QueryNode = node.children[1];
		return a.kind == identKind && b.kind == nullKind ? a.name : b.kind == identKind && a.kind == nullKind ? b.name : null;
	}

	/** Recursive worker for `eachFieldMember`: visit a container's mutable fields, tracking exported state. */
	private static function walkFieldContainers(
		node: QueryNode, source: String, file: String, containers: Array<String>, members: Array<String>, mutableFields: Array<String>,
		visibility: Array<String>, defaultVis: String,
		visit: (owner:String, field:QueryNode, source:String, file:String, exported:Bool) -> Void
	): Void {
		if (containers.contains(node.kind)) {
			final owner: Null<String> = node.name;
			if (owner != null) {
				var exported: Bool = false;
				for (child in node.children) {
					if (visibility.contains(child.kind)) {
						final span: Null<Span> = child.span;
						if (span != null && StringTools.trim(source.substring(span.from, span.to)) != defaultVis) exported = true;
					} else if (members.contains(child.kind)) {
						if (mutableFields.contains(child.kind)) visit(owner, child, source, file, exported);
						exported = false;
					}
				}
			}
		}
		for (child in node.children)
			walkFieldContainers(child, source, file, containers, members, mutableFields, visibility, defaultVis, visit);
	}

	/** Walk back from `from` over own-line line-comments and block-comments (and the whitespace between) to the first code. */
	private static function lastCommentEndingBefore(
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, pos: Int
	): Null<{ from: Int, to: Int, isLine: Bool }> {
		var best: Null<{ from: Int, to: Int, isLine: Bool }> = null;
		for (c in comments) if (c.to <= pos && (best == null || c.to > best.to)) best = c;
		return best;
	}

	/** Extend `to` forward over a line-comment (or same-line block-comment) trailing on the decl's own line. */
	private static function firstCommentStartingAfter(
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, pos: Int
	): Null<{ from: Int, to: Int, isLine: Bool }> {
		var best: Null<{ from: Int, to: Int, isLine: Bool }> = null;
		for (c in comments) if (c.from >= pos && (best == null || c.from < best.from)) best = c;
		return best;
	}

	/** Index of the first character of the line containing `i` (just past the preceding newline). */
	private static function lineStartOf(source: String, i: Int): Int {
		final nl: Int = source.lastIndexOf('\n', i);
		return nl < 0 ? 0 : nl + 1;
	}

	/** Walk `from` back over own-line leading comments (and the whitespace between) to the first code; returns the new start offset. Shared by `memberTriviaSpan` and `leadingCommentBlockStart`. */
	private static function absorbLeadingComments(source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, from: Int): Int {
		var result: Int = from;
		while (true) {
			final c: Null<{ from: Int, to: Int, isLine: Bool }> = lastCommentEndingBefore(comments, result);
			if (c == null || StringTools.trim(source.substring(c.to, result)) != '') break;
			final ls: Int = lineStartOf(source, c.from);
			if (StringTools.trim(source.substring(ls, c.from)) != '') break;
			result = ls;
		}
		return result;
	}

	/**
	 * Index of the closing `quote` of the string opened at `open`, honouring
	 * `\`-escapes; the source length minus one if unterminated (the caller's `i++`
	 * then ends the scan).
	 */
	private static function skipStringLiteral(text: String, open: Int, quote: Int): Int {
		final n: Int = text.length;
		var i: Int = open + 1;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(text, i);
			if (c == '\\'.code) {
				i += 2;
				continue;
			}
			if (c == quote) return i;
			i++;
		}
		return n - 1;
	}

}
