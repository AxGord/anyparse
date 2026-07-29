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
/**
 * Lexical classification of one word-boundary occurrence of an identifier.
 * Drives the naming completeness gate: only `CommentTrivia` occurrences are
 * renamed along with the code, every other class blocks the rename.
 */
enum abstract OccurrenceClass(Int) {

	final ActiveCode = 0;
	final ConditionalRaw = 1;
	final CommentTrivia = 2;
	final StringLiteral = 3;
	final DirectiveComment = 4;

}

/**
 * One classified word-boundary occurrence: the span of the matched identifier
 * and its lexical class.
 */
typedef ClassifiedOccurrence = {
	final span: Span;
	final kind: OccurrenceClass;
};

/** Kind of a lexically-scanned non-code source region (comment or string). */
private enum abstract LexRegionKind(Int) {

	final LineComment = 0;
	final BlockComment = 1;
	final StringLit = 2;

}

/** A lexically-scanned non-code region: `[from, to)` and its kind. */
private typedef LexRegion = {
	final from: Int;
	final to: Int;
	final kind: LexRegionKind;
};
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
	/** The grammar kind a `typedef` projects as — the only member host whose members sit under an `Anon`. */
	private static final TYPEDEF_DECL_KIND: String = 'TypedefDecl';

	/** The grammar kind an anonymous structure projects as, in BOTH a typedef body and a type expression. */
	private static final ANON_KIND: String = 'Anon';

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
		'AbstractClassDecl',
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
	 *
	 * This MUTABILITY fact is NOT derivable from a declaration — a method signature
	 * never states whether it reassigns `this` — so, unlike the extension-method and
	 * static-return tables now derived from the std sources via `StdResolver`, this
	 * list is intrinsic semantic knowledge and stays hand-maintained.
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
	 * Whether `kind` declares a member. `isFieldMemberKind` plus the enum constructors and
	 * the three conditional member forms `HxClassMember` dispatches BEFORE their plain
	 * twins (`var x … #if … ;`, `function #if a f #else g #end`, a `#if` splice at member
	 * scope). Each of those carries a signature and a body like any member, so a walk
	 * looking for member HOSTS has to recognise them or it descends into one.
	 */
	public static inline function isMemberDeclKind(kind: String): Bool {
		return isFieldMemberKind(kind) || kind == 'SimpleCtor' || kind == 'ParamCtor' || kind == 'VarSemiCondInitMember'
			|| kind == 'CondNameFnMember' || kind == 'CondSpliceMember';
	}

	/**
	 * Visit `node` and every descendant that can HOST a member declaration, so a caller can
	 * scan each host's direct children. Descends through wrappers — a `#if` region puts a
	 * member one level down, a typedef puts its fields under an `Anon` — but stops at the
	 * two places an anonymous structure is written as a TYPE rather than as a member list:
	 * inside a member (its annotation or its body) and in a declaration's own header (a
	 * type-parameter constraint, a heritage type argument, an abstract's underlying). An
	 * `{ var x:Int; }` there projects the very kinds a member does (`VarField` /
	 * `FinalField`), so descending reports its fields as members of the enclosing type —
	 * a phantom that has bitten the symbol index and `remove-member` alike.
	 */
	public static function eachMemberHost(node: QueryNode, visit: QueryNode -> Void): Void {
		visit(node);
		for (child in node.children) if (descendsToMemberHost(node.kind, child.kind)) eachMemberHost(child, visit);
	}

	/**
	 * Whether a walk looking for member declarations should descend from a `parentKind`
	 * node into a `childKind` one. Split out of `eachMemberHost` for a walk that threads
	 * its own state down the tree (`unused-private` carries an `extends` flag) and so
	 * cannot delegate the recursion itself — the pruning knowledge still lives here.
	 */
	public static inline function descendsToMemberHost(parentKind: String, childKind: String): Bool {
		return !isMemberDeclKind(childKind) && (parentKind == TYPEDEF_DECL_KIND || childKind != ANON_KIND);
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
	 * Offset of the first word-boundary occurrence of `name` within
	 * `[span.from, span.to)` that lives in code the compiler sees, or -1
	 * when the window holds none. Identical to `identTokenOffset` except
	 * that a match inside COMMENT trivia is skipped, so a comment sitting
	 * between a receiver and its member never wins the race for the member
	 * token (the window a caller derives from two AST spans also contains
	 * every byte of trivia between them).
	 *
	 * String literals and `#if` bodies are deliberately NOT skipped: a
	 * `${obj.member}` interpolation and a conditionally compiled access are
	 * both live references a rename has to reach.
	 */
	public static function activeCodeIdentTokenOffset(source: String, span: Span, name: String): Int {
		final regions: Array<LexRegion> = scanLexicalRegions(source);
		var from: Int = span.from;
		while (from < span.to) {
			final at: Int = identTokenOffset(source, new Span(from, span.to), name);
			if (at < 0 || !offsetWithinComment(at, regions)) return at;
			from = at + 1;
		}
		return -1;
	}

	/**
	 * Is `offset` inside a COMMENT region? The first lexical region that
	 * contains it decides; a string literal is not a comment, so code
	 * interpolated inside one stays eligible.
	 */
	private static function offsetWithinComment(offset: Int, regions: Array<LexRegion>): Bool {
		for (region in regions) if (offset >= region.from && offset < region.to) return region.kind != LexRegionKind.StringLit;
		return false;
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

	/**
	 * Stage a cross-file rename all-or-nothing: canonicalize each file's edit
	 * `slice` through `canon` and return every file's rewritten source ONLY when
	 * EVERY slice canonicalizes to a genuinely-changed result. Any `Err`, any
	 * missing source (`sourceOf` returns null), or any no-op slice reverts the
	 * WHOLE set (returns null) — the multi-file counterpart of a single
	 * `canonicalize`, so a partial application can never reach disk. Pure:
	 * `sourceOf` supplies each file's current source and `canon` performs the
	 * per-file canonicalization (`file, source, edits`), both injected by the
	 * caller.
	 */
	public static function stageCrossFileRename(
		slices: Array<{ file: String, edits: Array<{ span: Span, text: String }> }>, sourceOf: (String) -> Null<String>,
		canon: (String, String, Array<{ span: Span, text: String }>) -> EditResult
	): Null<Array<{ file: String, source: String }>> {
		final out: Array<{ file: String, source: String }> = [];
		for (slice in slices) {
			final src: Null<String> = sourceOf(slice.file);
			if (src == null) return null;
			switch canon(slice.file, src, slice.edits) {
				case Ok(text):
					if (text == src) return null;
					out.push({ file: slice.file, source: text });
				case Err(_):
					return null;
			}
		}
		return out.length == 0 ? null : out;
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
	 * Extend a declaration's span back over its leading doc comment, so a replace / remove
	 * can carry (or rewrite) the documentation. Scans back over whitespace from `span.from`;
	 * the block comment immediately above the node (doc or plain) is absorbed, then the walk
	 * keeps going back ONLY across further doc comments — a stray duplicate left by an
	 * earlier edit — so a stacked duplicate is cleaned up as one unit while a DISTINCT
	 * preceding block comment (a license header or section banner above the doc) is left
	 * intact. Returns the span unchanged when only whitespace or a non-comment token
	 * precedes. Line-comment (double-slash) doc runs are not handled (v1); the re-parse gate
	 * validates the result either way.
	 *
	 * Each comment's START comes from `collectCommentTokens` — the lexer's own tokenisation —
	 * never from scanning the text for an opener sequence. A block comment does not nest, so
	 * an opener written INSIDE a doc's text (a backticked example, say) is content; a scan
	 * that searched backwards for one used to cut the doc there, leaving an unterminated
	 * fragment that swallowed the next member's doc, and the same defect made `set-doc`
	 * splice its replacement mid-comment and never converge.
	 */
	public static function docExtendedSpan(source: String, span: Span): Span {
		final tokens: Array<{ from: Int, to: Int, isLine: Bool }> = collectCommentTokens(source);
		var from: Int = span.from;
		var first: Bool = true;
		while (true) {
			var i: Int = from - 1;
			while (i >= 0 && isSpace(StringTools.fastCodeAt(source, i))) i--;
			if (i < 0) break;
			// The preceding token must be a BLOCK comment ending exactly here. Asking the
			// lexer which token that is (rather than scanning back for a `/*`) is what keeps
			// an opener written inside the doc's own TEXT from being mistaken for its start.
			final open: Int = blockCommentEndingAt(tokens, i + 1);
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
	 * Is the source spanned by `span` — with its first and last byte stripped
	 * (a brace-delimited block's `{` / `}`) — whitespace-only? A block holding
	 * only a comment is non-blank: a comment carries no statement, but it is
	 * source a fix must not silently discard (it may be the only trace of
	 * intent behind an otherwise-empty block). Shared by `empty-block` (an
	 * empty `{}` control-flow body) and `constant-condition` (a dead branch a
	 * fix would eliminate).
	 */
	public static function isBlankSpan(span: Span, source: String): Bool {
		final inner: String = source.substring(span.from + 1, span.to - 1);
		return StringTools.trim(inner) == '';
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
		for (region in scanLexicalRegions(source)) switch region.kind {
			case LineComment:
				out.push({ from: region.from, to: region.to, isLine: true });
			case BlockComment:
				out.push({ from: region.from, to: region.to, isLine: false });
			case StringLit:
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
		return privateMemberScanIsSound(source, index) && !index.hasSubtype(owner) && !index.hasAccessGrant(owner);
	}

	/**
	 * The part of `isPrivateMemberConfined` that NO precise gate can refine: no file
	 * skip-parsed (one could hide any writer at all) and no `@:allow` in the member's own
	 * file (which hands its privates to a type the index cannot name from here). The other
	 * two vetoes — subtype and `@:access` grant — name a REACHABLE file each, so a caller
	 * that can scan those files for what it actually fears pairs this with its own gates
	 * instead: `prefer-final-field` asks only whether such a file WRITES the member, since
	 * a read survives `final`.
	 */
	public static inline function privateMemberScanIsSound(source: String, index: SymbolIndex): Bool {
		return index.skippedFiles().length <= 0 && source.indexOf('@:allow') < 0;
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
	 * Recursive kind / name / arity equality over two subtrees — the shared SHAPE-identity
	 * predicate. Spans and source formatting are ignored, so two nodes compare equal when
	 * they project the same tree regardless of where they sit or how they are laid out.
	 * `Matcher` uses it to enforce a reused metavariable (`$x` twice in one pattern must
	 * capture the same shape); `tail-merge` uses it as one half of its tail-identity test
	 * (paired with a whitespace-normalized source comparison, since shape equality alone
	 * cannot see a comment sitting INSIDE a statement's span).
	 */
	public static function structurallyEqual(a: QueryNode, b: QueryNode): Bool {
		if (a.kind != b.kind) return false;
		if (a.name != b.name) return false;
		if (a.children.length != b.children.length) return false;
		for (k in 0...a.children.length) if (!structurallyEqual(a.children[k], b.children[k])) return false;
		return true;
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
	 * `x`, …). Haxe narrows such an `x` only inside a condition, so a check that
	 * flattens the condition into a bare boolean `||` chain loses the narrowing and
	 * the result fails to compile under `@:nullSafety(Strict)` —
	 * `simplify-boolean-ternary` must always skip a guarded finding. A ternary
	 * `cond ? a : b` KEEPS the narrowing (it types like if/else), so the ternary
	 * checks consult this only through `refusesNullNarrowingBoolCollapse` (refusing
	 * just the bool-literal collapse that would hand off to the flattening
	 * `simplify-boolean-ternary`). Conservative: a reuse in ANY position counts (it
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
	 * Whether collapsing an `if`/branch pair with condition `cond` and branch
	 * values `a` / `b` into a ternary must be REFUSED: `cond` carries a
	 * null-narrowing guard (`hasNullNarrowingGuard`) AND a branch value is a bool
	 * literal (`boolLitKind`; an unset kind never refuses). A VALUE ternary keeps
	 * the in-condition narrowing (`cond ? a : b` types exactly like if/else), so a
	 * guarded condition alone is fine — but a bool-literal pair hands off to
	 * `simplify-boolean-ternary`, whose boolean flattening loses the narrowing
	 * (and whose own guard then strands a stuck ternary uglier than the original).
	 * The shared gate of `prefer-ternary-return` / `prefer-ternary-assignment`.
	 */
	public static function refusesNullNarrowingBoolCollapse(a: QueryNode, b: QueryNode, cond: QueryNode, shape: RefShape): Bool {
		final boolLitKind: Null<String> = shape.boolLitKind;
		return boolLitKind != null && (a.kind == boolLitKind || b.kind == boolLitKind) && hasNullNarrowingGuard(cond, shape);
	}

	/**
	 * The local name a top-level statement DECLARES, or null — the `name` of
	 * `topLevelDeclaredNode`'s result. Shared by `guard-continue`'s collision gate and
	 * `Rename`'s same-name blind-spot net.
	 */
	public static function topLevelDeclaredName(
		stmt: QueryNode, localDeclKinds: Array<String>, localDeclExprKinds: Array<String>, metaKinds: Array<String>
	): Null<String> {
		final decl: Null<QueryNode> = topLevelDeclaredNode(stmt, localDeclKinds, localDeclExprKinds, metaKinds);
		return decl == null ? null : decl.name;
	}

	/**
	 * The declaration NODE a top-level statement DECLARES a local in, or null — the
	 * node `topLevelDeclaredName` reads the name off, exposed for callers that also
	 * need its span (`guard-continue`'s collision rename locates the binder token
	 * inside it). Same walk: a `localDeclKinds` statement answers directly, otherwise
	 * the walk descends through single-payload wrappers (`metaKinds` children skipped)
	 * to an expression-position declaration.
	 */
	public static function topLevelDeclaredNode(
		stmt: QueryNode, localDeclKinds: Array<String>, localDeclExprKinds: Array<String>, metaKinds: Array<String>
	): Null<QueryNode> {
		var cur: QueryNode = stmt;
		while (true) {
			if (localDeclKinds.contains(cur.kind) || localDeclExprKinds.contains(cur.kind)) return cur;
			final payload: Array<QueryNode> = [for (c in cur.children) if (!metaKinds.contains(c.kind)) c];
			if (payload.length != 1) return null;
			cur = payload[0];
		}
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
		return boolOpKinds.contains(unwrapParens(operand, parenKind).kind);
	}

	/**
	 * `node` with every enclosing parenthesis layer peeled off — `((e))` yields `e`.
	 * The grammar-agnostic paren seam: an UNSET `parenKind` (the grammar declares no
	 * parenthesized-expression kind) returns `node` unchanged, so a caller degrades to
	 * its un-unwrapped behaviour rather than guessing a kind. A paren node that does not
	 * hold exactly one child stops the walk — only a plain single-child wrap is
	 * semantically transparent.
	 */
	public static function unwrapParens(node: QueryNode, parenKind: Null<String>): QueryNode {
		var n: QueryNode = node;
		while (parenKind != null && n.kind == parenKind && n.children.length == 1) n = n.children[0];
		return n;
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
	 * `index` is forced lazily — only after a method call is found — so most runs never build it. When
	 * the plugin carries a resolution scope, the forced index resolves against the configured libraries
	 * too, so a library abstract (e.g. openfl `ByteArray`) is recognised rather than treated as unknown.
	 *
	 * True (keep the `var`) when `name` has a method call in `source` outside its own declaration
	 * `exclude` AND its type either resolves to an abstract that may REBIND `this`
	 * (`SymbolIndex.abstractRebindsThis`) or is an UNRESOLVED non-stdlib type whose abstractness cannot
	 * be ruled out. False — the `final` suggestion stays sound and useful — for a resolved non-abstract
	 * type, a RESOLVED abstract whose only `this`-writes are in its constructor (the compiler forbids
	 * `this =` outside inline members and `final` rejects an inline this-writer transitively, so a
	 * ctor-only writer like `ByteArray` is final-safe) or that only `@:forward`s to a class underlying
	 * (which mutates the object, never the binding), a stdlib value type, an untyped binding, or no
	 * method call. A `@:build` abstract bails conservative (its members may be macro-generated and
	 * invisible). Conservative: it only ever KEEPS a `var`, never produces a wrong `final`.
	 */
	public static function abstractMethodMayMutate(
		source: String, name: String, declType: Null<String>, exclude: Span, index: () -> Null<SymbolIndex>, abstractKinds: Array<String>
	): Bool {
		if (declType == null || !methodCalledOn(source, name, exclude)) return false;
		final idx: Null<SymbolIndex> = index();
		final resolvedRebind: Null<Bool> = idx == null ? null : idx.abstractRebindsThis(declType, abstractKinds);
		return resolvedRebind ?? !finalSafeStdlibTypes.contains(declType);
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

	/**
	 * The dotted segments of a PATH expression — a root identifier (or a self reference)
	 * followed by plain field accesses, so `session.files` yields `['session', 'files']` — or
	 * null when `node` is anything else. Only `fieldKind` links over an `identKind` root are
	 * accepted: a call, an index access or a null-safe `?.` link anywhere in the chain projects
	 * as a different kind and yields null, keeping every segment a plain field read with no side
	 * effect of its own. Shared by the `map-keys-lookup` and `prefer-index-access` type gates.
	 */
	public static function pathOf(node: QueryNode, identKind: String, fieldKind: String): Null<Array<String>> {
		final name: Null<String> = node.name;
		if (name == null) return null;
		if (node.kind == identKind) return [name];
		if (node.kind != fieldKind || node.children.length != 1) return null;
		final base: Null<Array<String>> = pathOf(node.children[0], identKind, fieldKind);
		if (base == null) return null;
		base.push(name);
		return base;
	}

	/** The simple outer nominal of a written type — `pkg.Map<String, Int>` → `Map` — or null when the text is not a nominal at all. */
	public static function outerNominalOf(typeSource: String): Null<String> {
		final lt: Int = typeSource.indexOf('<');
		final head: String = StringTools.trim(lt < 0 ? typeSource : typeSource.substring(0, lt));
		final dot: Int = head.lastIndexOf('.');
		final name: String = dot < 0 ? head : head.substring(dot + 1);
		return isIdentifier(name) ? name : null;
	}

	/**
	 * The declared type nominal of a receiver path's ROOT — the enclosing type declaration for
	 * the self reference, else the root identifier's binding annotation from `declaredTypes` — or
	 * null when the root cannot be resolved. Shared by the map-abstract / keys()-type gates. A
	 * root that is a static TYPE name (no value binding) is resolved separately, import-aware,
	 * by `staticRootPathTypeSource`.
	 */
	public static function pathRootTypeName(
		recv: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, shape: RefShape
	): Null<String> {
		final identKind: Null<String> = shape.identKind;
		if (identKind == null) return null;
		var node: QueryNode = recv;
		while (node.kind != identKind && node.children.length == 1) node = node.children[0];
		if (node.kind != identKind) return null;
		if (node.name == shape.selfReferenceText) {
			final span: Null<Span> = recv.span ?? node.span;
			return span == null ? null : TypeResolver.enclosingTypeName(root, span);
		}
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(node, root, shape);
		return bindingFrom == null ? null : declaredTypes[bindingFrom];
	}

	/**
	 * The verbatim declared-type SOURCE of the FINAL segment of a multi-segment path receiver
	 * (`path.length >= 2`), resolved through `index`: the `rootType` nominal seeds the walk, each
	 * intermediate field segment resolves to its outer nominal via `memberTypeSourceOf`, and the
	 * last segment returns its raw type source — null when any link is unresolvable. A consumer
	 * that wants the final NOMINAL wraps this in `outerNominalOf`.
	 */
	public static function pathFinalMemberTypeSource(path: Array<String>, rootType: String, index: SymbolIndex): Null<String> {
		var current: String = rootType;
		for (i in 1...path.length - 1) {
			final memberType: Null<String> = index.memberTypeSourceOf(current, path[i]);
			final nominal: Null<String> = memberType == null ? null : outerNominalOf(memberType);
			if (nominal == null) return null;
			current = nominal;
		}
		return index.memberTypeSourceOf(current, path[path.length - 1]);
	}

	/**
	 * The verbatim declared type SOURCE of a receiver path's final member, for a value / `this` /
	 * static-TYPE-name root. Resolves PACKAGE-SAFE FIRST via the import- and inheritance-aware
	 * `SymbolIndex.resolvePathFinalMemberTypeSource` (so an import-correct intermediate type's
	 * INHERITED member is read off THAT exact type, never a same-simple-named type in another
	 * package — the cross-package poisoning that made the package-blind walk emit `[]` on a
	 * non-Map). Only when the import-aware walk cannot follow the chain — an aliased conditional
	 * supertype the index does not model (openfl's `Application` inherits `meta` from lime's via
	 * `import … as LimeApplication`) — does it FALL BACK to the package-blind simple-name walk: a
	 * value / `this` root walks the whole path by simple name; a static TYPE root still resolves
	 * its FIRST member import-aware (dodging a same-named root's `#if`-typed member) before the
	 * simple-name tail. `rootType` is the value / `this` root's type name, or null for a static
	 * TYPE root (then `path[0]` is the type). Null when unresolved / ambiguous (fails closed).
	 */
	public static function pathReceiverMemberTypeSource(
		path: Array<String>, rootType: Null<String>, index: SymbolIndex, fromFile: String
	): Null<String> {
		if (path.length < 2) return null;
		final startType: String = rootType ?? path[0];
		final resolved: Null<String> = index.resolvePathFinalMemberTypeSource(fromFile, startType, path.slice(1));
		if (resolved != null) return resolved;
		if (rootType != null) return pathFinalMemberTypeSource(path, rootType, index);
		final firstSource: Null<String> = index.resolvePathFinalMemberTypeSource(fromFile, path[0], [path[1]]);
		if (firstSource == null) return null;
		if (path.length == 2) return firstSource;
		final firstNominal: Null<String> = outerNominalOf(firstSource);
		return firstNominal == null ? null : pathFinalMemberTypeSource(path.slice(1), firstNominal, index);
	}

	/**
	 * The report + resolution-scope `SymbolIndex` the plugin host carries — a subtype declared in a
	 * configured resolution library, or in the implicitly-scoped Haxe std, is indexed there too — or
	 * null when the plugin is not a resolution host or no scope reached it at all (the caller falls
	 * back to the report index). The eager counterpart of `lazySymbolIndex`, for a check that already
	 * holds a report index and only needs to know whether a WIDER one exists:
	 * `resolutionIndexOf(plugin) ?? index`.
	 *
	 * The null return is now the RARE case rather than the default. A `Cli` run reaches it only when
	 * the project declares no resolution key AND no Haxe std is discoverable — a machine without Haxe,
	 * or one that declined the std via `APQ_NO_STD` / `"resolutionStd": false`. It is still the plain
	 * answer for a direct `check.run` with a bare plugin, which is what the unit tests that pin the
	 * report-only behaviour use.
	 */
	public static inline function resolutionIndexOf(plugin: GrammarPlugin): Null<SymbolIndex> {
		final host: Null<SymbolIndexHost> = (plugin is SymbolIndexHost) ? cast plugin : null;
		return (host != null && host.hasAnyResolutionScope()) ? host.resolutionIndex() : null;
	}

	/**
	 * A memoized `SymbolIndex` builder — built at most once, on first call, over `files`. Shared by
	 * checks whose path-receiver type gate needs cross-file resolution only after cheaper structural
	 * gates pass, so most runs never trigger the build. When `plugin` is a `SymbolIndexHost` carrying
	 * ANY resolution scope — a declared one (report files UNION the configured library roots) or the
	 * implicit std-only one — that host's memoised resolution index is preferred, so the check resolves
	 * against libraries and std too.
	 *
	 * The report-only fallback below it is therefore no longer the ordinary path: on a Haxe-equipped
	 * machine a `Cli` run always takes the host branch, and the fallback answers only for a direct
	 * `check.run` with a bare plugin (every unit test that pins report-scope behaviour) or a machine
	 * with no discoverable std. `prebuilt`, when supplied, is an already-built report-scope index that
	 * fallback returns as-is instead of building a second one — `prefer-final-field` passes the eager
	 * index it already holds. It is ignored when a resolution scope is present, since the wider index
	 * must win; that is not a lost optimisation, because the host's index is a DIFFERENT (wider) index
	 * than `prebuilt`, so there is no duplicate build to avoid on that path.
	 */
	public static function lazySymbolIndex(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?prebuilt: SymbolIndex
	): () -> Null<SymbolIndex> {
		final host: Null<SymbolIndexHost> = (plugin is SymbolIndexHost) ? cast plugin : null;
		if (host != null && host.hasAnyResolutionScope()) {
			final resolver: SymbolIndexHost = host;
			return () -> resolver.resolutionIndex();
		}
		if (prebuilt != null) {
			final ready: SymbolIndex = prebuilt;
			return () -> ready;
		}
		var index: Null<SymbolIndex> = null;
		var built: Bool = false;
		return () -> {
			if (!built) {
				built = true;
				index = SymbolIndex.build(files, plugin);
			}
			return index;
		};
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
	public static inline function isSafeKind(kind: String): Bool {
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
	 * The offset at which an `extends` / `implements` clause can be spliced into
	 * the header of `decl` (named `typeName`): just past its last header token,
	 * before the body `{`. AST-anchored — each header child node (a type-parameter
	 * constraint, an `extends` / `implements` clause, a conditional block) bounds
	 * the search, and the search itself steps over comments and string literals,
	 * so a `{` written inside a header comment or inside a structural type
	 * constraint is never mistaken for the body brace. Null when no body brace can
	 * be verified before the first body member; a caller that gets null must
	 * refuse the whole operation rather than splice at an unverified offset.
	 */
	public static function typeHeaderInsertOffset(source: String, decl: TypeDeclMatch, typeName: String): Null<Int> {
		final nameSpan: Span = decl.nameNode.span ?? decl.fullSpan;
		final nameAt: Int = identTokenOffset(source, nameSpan, typeName);
		final headerFrom: Int = nameAt < 0 ? nameSpan.from : nameAt + typeName.length;
		final limit: Int = nameSpan.to <= source.length ? nameSpan.to : source.length;
		var from: Int = headerFrom;
		var brace: Int = -1;
		// Children are in document order: the first one that starts after a located
		// brace belongs to the body, every earlier one is part of the header.
		for (child in decl.nameNode.children) {
			final s: Null<Span> = child.span;
			if (s == null) continue;
			brace = headerScan(source, from, s.from < limit ? s.from : limit).brace;
			if (brace >= 0) break;
			if (s.to > from) from = s.to;
		}
		if (brace < 0) brace = headerScan(source, from, limit).brace;
		return brace < 0 || StringTools.fastCodeAt(source, brace) != '{'.code ? null : headerScan(source, headerFrom, brace).tokenEnd;
	}

	/**
	 * The first `{` and the end of the last non-whitespace token in
	 * `source[from...to)`, both computed with comments and string literals treated
	 * as invisible. `brace` is -1 when the range holds no brace outside them;
	 * `tokenEnd` falls back to `from` when the range is all trivia.
	 */
	private static function headerScan(source: String, from: Int, to: Int): { brace: Int, tokenEnd: Int } {
		final end: Int = to <= source.length ? to : source.length;
		var brace: Int = -1;
		var tokenEnd: Int = from;
		var i: Int = from;
		while (i < end) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c == '/'.code && i + 1 < end) {
				final next: Int = StringTools.fastCodeAt(source, i + 1);
				if (next == '/'.code) {
					final nl: Int = source.indexOf('\n', i + 2);
					i = nl < 0 ? end : nl + 1;
					continue;
				}
				if (next == '*'.code) {
					final close: Int = source.indexOf('*/', i + 2);
					i = close < 0 ? end : close + 2;
					continue;
				}
			}
			if (c == '"'.code || c == "'".code) {
				i = skipStringLiteral(source, i, c) + 1;
				tokenEnd = i;
				continue;
			}
			if (c == '{'.code && brace < 0) brace = i;
			if (!isSpace(c)) tokenEnd = i + 1;
			i++;
		}
		return { brace: brace, tokenEnd: tokenEnd };
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

	/**
	 * Classify every word-boundary occurrence of `name` in `source[from...end)`
	 * (offsets inside `excluded` skipped) by lexical context, built on top of the
	 * parse so `#if...#end` regions and trivia are exact. Returns null when
	 * `source` does not parse — the caller then falls back to the raw scan
	 * (fail-closed). See `OccurrenceClass` for what each class means.
	 */
	public static function classifyOccurrences(
		source: String, name: String, plugin: GrammarPlugin, from: Int, end: Int, excluded: Array<Span>
	): Null<Array<ClassifiedOccurrence>> {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return null catch (exception: Exception) return null;
		final out: Array<ClassifiedOccurrence> = [];
		final len: Int = name.length;
		if (len == 0) return out;
		final condSpans: Array<Span> = [];
		collectConditionalSpans(tree, condSpans);
		final regions: Array<LexRegion> = scanLexicalRegions(source);
		final stop: Int = end <= source.length ? end : source.length;
		var i: Int = from;
		while (i + len <= stop) {
			final at: Int = source.indexOf(name, i);
			if (at < 0 || at + len > stop) break;
			i = at + 1;
			final afterIdx: Int = at + len;
			final beforeOk: Bool = at == 0 || !isIdentChar(StringTools.fastCodeAt(source, at - 1));
			final afterOk: Bool = afterIdx >= source.length || !isIdentChar(StringTools.fastCodeAt(source, afterIdx));
			if (beforeOk && afterOk && !offsetWithinAny(at, excluded))
				out.push({ span: new Span(at, afterIdx), kind: classifyAt(source, at, condSpans, regions) });
		}
		return out;
	}

	/**
	 * Single-pass lexer emitting every non-code region (line/block comment,
	 * string literal) with byte offsets. Strings are skipped with `\`-escape
	 * handling; `collectCommentTokens` filters this to its comment tokens.
	 */
	private static function scanLexicalRegions(source: String): Array<LexRegion> {
		final out: Array<LexRegion> = [];
		final n: Int = source.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c == '"'.code || c == "'".code) {
				final quote: Int = c;
				final start: Int = i;
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
				out.push({ from: start, to: i, kind: StringLit });
				continue;
			}
			if (c == '/'.code && i + 1 < n) {
				final next: Int = StringTools.fastCodeAt(source, i + 1);
				if (next == '/'.code) {
					final start: Int = i;
					i += 2;
					while (i < n && StringTools.fastCodeAt(source, i) != '\n'.code) i++;
					out.push({ from: start, to: i, kind: LineComment });
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
					out.push({ from: start, to: i, kind: BlockComment });
					continue;
				}
			}
			i++;
		}
		return out;
	}

	/** Collect the span of every `#if...#end` region node into `out` (recursive). */
	private static function collectConditionalSpans(node: QueryNode, out: Array<Span>): Void {
		if (isConditionalKind(node.kind)) {
			final s: Null<Span> = node.span;
			if (s != null) out.push(s);
		}
		for (child in node.children) collectConditionalSpans(child, out);
	}

	/**
	 * Whether a projected node kind denotes a `#if...#end` region — a block
	 * `Conditional`, an expression `ConditionalExpr`, or any `CondSplice*`
	 * mid-expression / statement splice. An unrecognised conditional kind
	 * degrades to `ActiveCode`, which still blocks — fail-closed.
	 */
	public static inline function isConditionalKind(kind: String): Bool {
		return kind == 'Conditional' || kind == 'ConditionalExpr' || StringTools.startsWith(kind, 'CondSplice');
	}

	/** The lexical class of the occurrence at `at`; see `OccurrenceClass`. */
	private static function classifyAt(source: String, at: Int, condSpans: Array<Span>, regions: Array<LexRegion>): OccurrenceClass {
		if (offsetWithinAny(at, condSpans)) return ConditionalRaw;
		for (region in regions) if (at >= region.from && at < region.to) return switch region.kind {
			case StringLit: StringLiteral;
			case LineComment | BlockComment: isNoqaComment(source, region) ? DirectiveComment : CommentTrivia;
		};
		return ActiveCode;
	}

	/**
	 * Whether a comment region carries a `noqa` suppression directive on any of
	 * its lines (`noqa` or `noqa: rules`, case-insensitive — the flake8 form the
	 * `Suppression` check honours). Such a line is machine-meaningful, so the
	 * rename must not rewrite inside it.
	 */
	private static function isNoqaComment(source: String, region: LexRegion): Bool {
		for (raw in source.substring(region.from, region.to).split('\n')) {
			var line: String = StringTools.trim(raw);
			if (StringTools.startsWith(line, '//') || StringTools.startsWith(line, '/*')) line = StringTools.trim(line.substr(2));
			final lower: String = line.toLowerCase();
			if (lower == 'noqa' || StringTools.startsWith(lower, 'noqa:')) return true;
		}
		return false;
	}

	/**
	 * Whether the field declared by `field` can become `final` off its CONSTRUCTOR
	 * assignment: it has no declaration initializer (a `final` with one cannot be
	 * reassigned in the constructor) and no `(` in its declaration head (which covers
	 * properties and parenthesised function types), its sole write is exactly one
	 * unconditional top-level constructor statement (`x = expr` / `this.x = expr` via
	 * `constructorFieldInitAt` — a shadowing local or parameter that owns the
	 * assignment leaves it a `var`), it is not static (`static final` requires a
	 * declaration initializer), and no other write to its name appears anywhere in
	 * `source` — a conservative text scan (`MemberWriteScan.writtenInRange`) that also
	 * sees `#if` bodies the structural walkers cannot. A `@:build` macro injecting a
	 * writer is the residual blind spot, shared with every other arm of the three
	 * consumers and surfacing as a loud compile error at the injected write.
	 *
	 * The shared core of the constructor arms of `prefer-final-field` /
	 * `prefer-final-public-field` AND of `prefer-read-only-field`'s cession of the same
	 * candidates — all three MUST agree on it, or a ctor-assigned field either gets two
	 * conflicting fixes or none. A new single-file soundness gate for the arm therefore
	 * belongs INSIDE this predicate, never in one consumer — and mind its cost:
	 * predicate-false routes the field to `prefer-read-only-field`'s `(default, null)`.
	 * Each check wraps it in its own cross-file write gates; this predicate is
	 * single-file only.
	 */
	public static function ctorSoleAssignmentFinalizable(source: String, field: QueryNode, plugin: GrammarPlugin): Bool {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (name == null || span == null) return false;
		if (field.children.length >= 1) return false;
		if (source.substring(span.from, span.to).indexOf('(') >= 0) return false;
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (_: Exception) null;
		if (tree == null) return false;
		final loc: Null<{
			container: QueryNode,
			field: QueryNode,
			stmt: QueryNode,
			rhs: QueryNode,
			target: Span
		}> = constructorFieldInitAt(tree, span.from, plugin.refShape());
		return loc != null && !staticMemberFroms(loc.container, plugin.refShape()).contains(span.from)
			&& !MemberWriteScan.writtenInRange(source, name, loc.target, 0, source.length);
	}

	/**
	 * The start offset of the BLOCK comment token whose end is exactly `end`, or -1 when
	 * no such token exists. `tokens` is a `collectCommentTokens` result, i.e. the lexer's
	 * own view: a block comment is ONE token from its opener to the first closer, so an
	 * opener sequence appearing inside the comment's text is content, not a boundary.
	 */
	private static function blockCommentEndingAt(tokens: Array<{ from: Int, to: Int, isLine: Bool }>, end: Int): Int {
		for (t in tokens) if (!t.isLine && t.to == end) return t.from;
		return -1;
	}

}
