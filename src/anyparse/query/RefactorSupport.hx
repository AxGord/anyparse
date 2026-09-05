package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * One resolved top-level type declaration, normalised across the plain
 * and `final`-wrapped grammar shapes so every consumer compares uniformly.
 *
 *  - A plain `class C {}` parses as a single `ClassDecl C` node — `name`
 *    and `kind` come from the node, both `nameNode` and `declNode` ARE the
 *    node, and `fullSpan` is the node's own span.
 *  - A `final class C {}` parses as `FinalDecl(ClassForm C …)` — the OUTER
 *    `FinalDecl` carries NO name and a span that INCLUDES the `final `
 *    keyword; the INNER `ClassForm` carries the name `C` and a span that
 *    EXCLUDES `final `. For this shape `kind` is normalised to `ClassDecl`
 *    (a final class IS a class), `nameNode` is the inner `ClassForm` (it
 *    holds the name token, so `identTokenContains` and the decl-name
 *    occurrence anchor on it), `declNode` is the OUTER `FinalDecl`, and
 *    `fullSpan` is that node's span so a move cuts `final class C {…}` WITH
 *    its `final ` keyword.
 *
 * `final` is the only modifier that WRAPS a decl (it is legal in Haxe
 * only on `class` — `final interface` / `final abstract` are parse
 * errors). Every other modifier (`private` / `public` / `extern`) is a
 * SEPARATE preceding sibling node (`Private` / `Extern`) that leaves the
 * named decl node a plain `ClassDecl` / … — those already resolve through the
 * node-on-node branch, so no wrapper handling is needed for them. They are NOT
 * in `fullSpan` either: a caller that must cover them (a cut, a replace) folds
 * the group with `declGroupSpan(declNode, …)`, which is what `declNode` is for.
 */
typedef TypeDeclMatch = {
	var name: String;
	var kind: String;
	var nameNode: QueryNode;
	var declNode: QueryNode;
	var fullSpan: Span;
}

/**
 * The MODULE a type is declared in, in the three shapes a qualified reference needs.
 *
 *  - `path` — the module's full dotted path (`pkg.Mod`, or bare `Mod` in the root package).
 *  - `pkg` — the module's package (`''` in the root package).
 *  - `base` — the module's basename, i.e. the name its MAIN type must carry.
 *
 * A dotted reference names a type THROUGH this path, so a cross-file rewrite compares the
 * receiver's WHOLE path against what `qualifiedPaths` makes legal — never against the
 * reference's last segment, which a same-named module in another package also satisfies.
 */
typedef ModulePath = {
	final path: String;
	final pkg: String;
	final base: String;
}

/**
 * Cursor-resolution and identifier/span primitives shared by the scope-correct refactoring
 * operations (`Rename`, `Inline`). Every member is `public static` and behaviour-preserving: the
 * bodies were lifted verbatim out of `Rename` once a second consumer (`Inline`) needed the same
 * cursor-to-binding resolution and word-boundary identifier-token logic. Keeping them here means
 * the two operations cannot drift apart.
 *
 * Coordinate convention: callers feed `cursor` as a raw UTF-16 offset (the operations invert the
 * `apq refs` printed column before calling). The helpers never re-implement scope analysis — they
 * ride on top of the `Refs.find` resolver and operate on `QueryNode` spans only.
 */
@:nullSafety(Strict)
final class RefactorSupport {

	/**
	 * The two file-wide vetoes `isPrivateMemberConfined` pairs with its per-type ones: no skipped
	 * file spells `member` (an unreadable one could hide any writer at all) and the member's own
	 * file carries no `@:allow`, which hands its privates to a type the index cannot name from
	 * here. Both are per-SUBJECT, not per-run — the earlier wording called this "the part … that
	 * NO precise gate can refine", which stopped being true when the skip-parse half became
	 * `skippedMayReference(member)` and was never true of the grant half.
	 *
	 * The other two vetoes — subtype and `@:access` grant — name a REACHABLE file each, so a caller
	 * that can scan those files for what it actually fears pairs this with its own gates
	 * instead: `prefer-final-field` asks only whether such a file WRITES the member, since
	 * a read survives `final`.
	 */
	public static inline function privateMemberScanIsSound(source: String, index: SymbolIndex, member: String): Bool {
		return !index.text.skippedMayReference(member) && !index.text.sourceCarriesAllowGrant(source);
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
		final host: Null<SymbolIndexHost> = plugin is SymbolIndexHost ? cast plugin : null;
		return host != null && host.hasAnyResolutionScope() ? host.resolutionIndex() : null;
	}

	/**
	 * The resolution scope's RAW sources (report UNION the library roots) when `plugin` hosts one, else
	 * null. The text counterpart of `resolutionIndexOf`, for a scan that needs no parse: the index
	 * drops a skip-parsed file from `allFiles` (it keeps the raw source, which is what
	 * `skippedFilesMentioning` reads), so a whole-scope proof walking `allFiles` would treat that
	 * file as holding nothing at all.
	 */
	public static inline function resolutionSourcesOf(plugin: GrammarPlugin): Null<Array<{ file: String, source: String }>> {
		final host: Null<SymbolIndexHost> = plugin is SymbolIndexHost ? cast plugin : null;
		return host != null && host.hasAnyResolutionScope() ? host.resolutionFiles() : null;
	}

	/**
	 * Whether a BARE `typeName` needs no import to resolve from a file in `filePkg` — which only a
	 * module's MAIN type read from that module's OWN package ever does. A SUB-MODULE type is
	 * invisible bare outside its own module, a sibling file in the same package included.
	 *
	 * The proof every import decision owes before it omits an import. "The two files share a
	 * package" is not that proof, and reading it as one leaves the file naming a type the compiler
	 * cannot find.
	 *
	 * Deliberately conservative in one place: a ROOT-package main type IS visible bare from every
	 * package, but only until the reading file's own package declares the same name, and nothing
	 * here can see out of scope to rule that out — so the answer stays `false` and the caller emits
	 * an `import Mod;` that is redundant rather than a bare name that could bind to the wrong type.
	 * The same-MODULE case (both types in one file, where the bare name always resolves) is not
	 * expressible from `filePkg` alone and is the caller's to exclude.
	 */
	public static inline function bareNameResolves(typeName: String, module: ModulePath, filePkg: String): Bool {
		return typeName == module.base && filePkg == module.pkg;
	}

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
			return span != null && span.from == cursor && SourceText.isRenameableName(node.name);
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
			if (span != null && cursor >= span.from && cursor < span.to && SourceText.isRenameableName(node.name) && pred(node))
				best = node;
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
		final identFrom: Int = SourceText.identTokenOffset(source, span, name);
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
			return boundTo?.from;
		}

		// Cursor is on a node that the resolver does not emit as a ref
		// hit — the `this.<field>` field-access case. Bind it to the sole
		// member decl of the same name.
		if (node.kind != MemberKinds.FIELD_ACCESS_KIND) return null;
		final memberDecl: Null<RefHit> = hits.find(h -> h.kind == RefKind.Decl);
		return memberDecl?.span.from;
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
		if (name != null && MemberKinds.TYPE_DECL_KINDS.contains(node.kind)) return {
			name: name,
			kind: node.kind,
			nameNode: node,
			declNode: node,
			fullSpan: span
		};

		if (node.kind == 'FinalDecl' && node.children.length > 0) {
			final inner: QueryNode = node.children[0];
			final innerName: Null<String> = inner.name;
			if (inner.kind == 'ClassForm' && innerName != null) return {
				name: innerName,
				kind: 'ClassDecl',
				nameNode: inner,
				declNode: node,
				fullSpan: span
			};
		}
		return null;
	}

	/**
	 * The type declaration named `typeName` in `tree`, or null when the module declares none or more
	 * than one — a name that is ambiguous within one file cannot address a single declaration, so
	 * every caller wants the same refusal rather than an arbitrary first match. An empty or omitted
	 * `kinds` filters nothing; a non-empty one keeps only matches whose `TypeDeclMatch.kind` it lists
	 * (a caller that may only address, say, a CLASS).
	 */
	public static function uniqueTypeDeclNamed(tree: QueryNode, typeName: String, ?kinds: Array<String>): Null<TypeDeclMatch> {
		final allow: Array<String> = kinds ?? [];
		final matches: Array<TypeDeclMatch> = [];
		function walk(node: QueryNode): Void {
			final match: Null<TypeDeclMatch> = typeDeclOf(node);
			if (match != null && match.name == typeName && (allow.length == 0 || allow.contains(match.kind))) matches.push(match);
			for (child in node.children) walk(child);
		}
		walk(tree);
		return matches.length == 1 ? matches[0] : null;
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
				// Three accepted anchors, because a `final class` splits the two spans: the name
				// token, the start of the whole declaration (`final`), and the start of the NAMED
				// node - which for that shape is the inner `ClassForm` at `class`, and is exactly
				// the coordinate `apq refs --decls` prints. Without the third, the documented
				// "copy the position from refs --decls" convention resolved no type declaration
				// for a `final class` and the caller fell through to the value-namespace rename.
				final nameSpan: Null<Span> = m.nameNode.span;
				final onNameStart: Bool = nameSpan != null && nameSpan.from == cursor;
				if (
					cursor >= span.from && cursor < span.to
					&& (identTokenContains(m.nameNode, cursor, source) || span.from == cursor || onNameStart)
				)
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
		return tail.endsWith('.hx') ? tail.substr(0, tail.length - '.hx'.length) : tail;
	}

	/**
	 * Every DOTTED path by which a file in package `filePkg` may legally name `typeName`
	 * declared in `module` — the whole set a qualified reference is matched against.
	 *
	 * For `T` in module `pkg.Mod` (file `pkg/Mod.hx`) Haxe accepts:
	 *
	 *  - `T` — from `pkg`, or after an import. Not dotted, so not listed here.
	 *  - `pkg.Mod.T` — from anywhere.
	 *  - `Mod.T` — ONLY from a file in `pkg`; `import pkg.Mod;` does NOT make it legal
	 *    elsewhere. Hence the `filePkg == module.pkg` gate: a ROOT-package module is visible
	 *    as `Mod.T` from every package, so the same text in two packages can name two
	 *    different types, and only the gate keeps a rename off the foreign one.
	 *  - `pkg.Mod` — the MAIN type alone (its name equals the basename); it has no
	 *    `<module>.<type>` form, and in the root package no dotted form at all.
	 */
	public static function qualifiedPaths(typeName: String, module: ModulePath, filePkg: String): Array<String> {
		if (typeName == module.base) return module.path == module.base ? [] : [module.path];
		final out: Array<String> = ['${module.path}.$typeName'];
		if (filePkg == module.pkg && module.path != module.base) out.push('${module.base}.$typeName');
		return out;
	}

	/**
	 * The ONE dotted path that names `typeName` in `module` from every file, whatever its package
	 * or imports: `pkg.Mod` for a module's main type, `pkg.Mod.T` for a sub-module type, and the
	 * basename alone (`Mod` / `Mod.T`) for a root-package module, which is visible everywhere.
	 * The single exception is a ROOT-package module shadowed by a same-named module in the reading
	 * file's own package — Haxe can spell only the near one, so no path reaches the root one.
	 *
	 * The root-anchored counterpart of `qualifiedPaths`: that one lists every spelling a reference
	 * MAY already use, this one is the spelling a rewrite SHOULD emit when it cannot prove which
	 * shorter form is legal at the reading site.
	 */
	public static function rootQualifiedPath(typeName: String, module: ModulePath): String {
		return typeName == module.base ? module.path : '${module.path}.$typeName';
	}

	/** The dotted path a receiver chain spells (`a.b.C`), or `''` when a link is not a plain name. */
	public static function flattenPath(node: QueryNode): String {
		final name: Null<String> = node.name;
		if (name == null) return '';
		if (node.kind == MemberKinds.IDENT_EXPR_KIND) return name;
		if (node.kind != MemberKinds.FIELD_ACCESS_KIND || node.children.length == 0) return '';
		final head: String = flattenPath(node.children[0]);
		return head == '' ? '' : '$head.$name';
	}

	/**
	 * Whether `recv` names the type `typeName` used as a NAMESPACE — the receiver half of a
	 * static access the rename owns.
	 *
	 * A bare `IdentExpr` qualifies unless the resolver bound it to a value (`valueResolved`
	 * holds those receiver offsets): an unresolved bare name is the type. A DOTTED receiver
	 * qualifies only when its WHOLE path is one of `qualified` (`qualifiedPaths`); matching its
	 * last segment instead would accept `other.Mod.T` for a rename of `pkg.Mod.T`.
	 */
	public static function receiverIsTypeNamespace(
		recv: QueryNode, typeName: String, qualified: Array<String>, valueResolved: Array<Int>
	): Bool {
		final recvSpan: Null<Span> = recv.span;
		return recv.name == typeName && recvSpan != null && (
			recv.kind == MemberKinds.IDENT_EXPR_KIND
				? !valueResolved.contains(recvSpan.from)
				: recv.kind == MemberKinds.FIELD_ACCESS_KIND && qualified.contains(flattenPath(recv))
		);
	}

	/**
	 * Offset of the LAST segment of the dotted `pathName` within `span` — where a rewrite of the
	 * TYPE half of `a.b.C.member` must land. `pathName` is the node's name slot: an `import` /
	 * `using` declaration and a QUALIFIED type reference each carry the whole dotted path there.
	 *
	 * Exact by construction: it finds the path text and steps past its final `.`, where
	 * `identTokenOffset` takes the FIRST word-boundary occurrence of the name in the span and so
	 * mis-lands whenever an earlier segment spells it too (`import Foo.sub.Foo;`). -1 when
	 * `pathName` is null, its last segment is not `typeName`, or the path does not start in `span`.
	 */
	public static function lastSegmentOffset(source: String, span: Span, pathName: Null<String>, typeName: String): Int {
		if (pathName == null || SourceText.lastSegment(pathName) != typeName) return -1;
		final pathStart: Int = pathOffset(source, span, pathName);
		return pathStart < 0 ? -1 : pathStart + pathName.lastIndexOf('.') + 1;
	}

	/**
	 * Offset at which the dotted `pathName` starts inside `span`, or -1 when `span` does not hold
	 * the whole path contiguously (whitespace around a dot) or `pathName` is null. Both ends are
	 * checked, because the caller turns this into a REPLACEMENT span `[at, at + pathName.length)`.
	 *
	 * Where `lastSegmentOffset` finds the TYPE half of `a.b.C.member`, this finds the whole
	 * receiver: a rewrite that repoints a reference at a type reachable under a DIFFERENT module
	 * must replace the entire path, not its final segment.
	 */
	public static function pathOffset(source: String, span: Span, pathName: Null<String>): Int {
		if (pathName == null) return -1;
		final at: Int = source.indexOf(pathName, span.from);
		return at < 0 || at + pathName.length > span.to ? -1 : at;
	}

	/**
	 * Whether the type annotation ending at `typeEnd` is a function's RETURN type rather than a
	 * TYPE-PARAMETER CONSTRAINT. The two project into the SAME slot — the child immediately before the
	 * function body — under the same node kind, so `function f<T: Colour>()` and `function f(): Colour`
	 * give byte-identical trees and the slot alone proves nothing. What separates them is the PARAMETER
	 * LIST: a constraint always has one between itself and the body, a return type never does, so a gap
	 * holding no `(` is the discriminator.
	 *
	 * COMMENTS in the gap are skipped through the shared `commentRegionEnd` scan, because a `(` written
	 * inside one cannot be a parameter list. Without that, a block comment or a trailing line comment
	 * between the annotation and the body carried the whole function out of the proof — measured on
	 * both, each a silent refusal.
	 *
	 * A conditional-compilation directive needs no such arm: probed on `function f(): Colour #if
	 * (myflag) return X; #else return X; #end`, the conditional BODY node opens AT the `#if`, so the
	 * directive and its parentheses fall inside the body rather than in the gap. Metadata behaves the
	 * same way — `@:meta("(")` before the body opens at the `@`.
	 *
	 * Every OTHER unknown is answered `false`, which is the direction both callers want: a comment
	 * that does not close before the body, an offset pair that arrives reversed, a `bodyStart` past
	 * the end of the source. That keeps a `(` the scan cannot attribute from ever reading as absent,
	 * and it bounds the scan to the window it was handed. Note what the arm does NOT buy: a comment
	 * can only ever flip a RETURN-type slot, never a constraint slot, because a constraint's `(`
	 * precedes any comment that could follow it. And this project's own writer refuses to round-trip
	 * a comment in that gap at all ("the writer round trip would drop the comment"), so the shapes
	 * the arm accepts are ones no anyparse tool could have produced — a real writer gap, recorded
	 * here because it is what makes the arm look unreachable on this tree.
	 */
	public static function isReturnTypeSlot(source: String, typeEnd: Int, bodyStart: Int): Bool {
		if (typeEnd > bodyStart || bodyStart > source.length) return false;
		var i: Int = typeEnd;
		while (i < bodyStart) {
			final c: Int = source.fastCodeAt(i);
			if (c == '('.code) return false;
			if (c != '/'.code || i + 1 >= bodyStart) {
				i++;
				continue;
			}
			final commentEnd: Int = SourceComments.commentRegionEnd(source, i);
			if (commentEnd < 0)
				i++;
			else if (commentEnd > bodyStart)
				return false;
			else
				i = commentEnd;
		}
		return true;
	}

	/**
	 * Whether a private member of the type named `owner` is confined to its file —
	 * i.e. unreachable from outside it, so an in-file analysis (rename, unused
	 * detection) sees every possible reference. False when any file skip-parsed (it
	 * could hide a subtype or `@:access` the index never saw), when a subtype or
	 * `@:access` grant names the type, or when the file carries an `@:allow` (which
	 * can expose its privates to another type). Conservative: any doubt is false.
	 */
	public static function isPrivateMemberConfined(owner: String, member: String, source: String, index: SymbolIndex): Bool {
		return privateMemberScanIsSound(source, index, member) && !index.subtypes.hasSubtype(owner) && !index.text.hasAccessGrant(owner);
	}

	/**
	 * Whether `source` carries an `@:allow` grant IN CODE — the one place this project asks that
	 * question. It had two readers spelling the same `indexOf` scan (`privateMemberScanIsSound` and
	 * `Naming`s `CROSS_ALLOW_GRANT` gate), which is how a scan and the sentence describing it drift
	 * apart.
	 *
	 * Comment, string and regex regions are masked — through `plugin.lexicalRegions`, the seam,
	 * since S55; this was the last plugin-less `LexicalRegions` read with a single caller, and
	 * `SymbolIndex` carries the plugin the memo needs. Masking is a CORRECTNESS fix rather than a
	 * tightening: a comment is not metadata, and no string literal becomes metadata on the
	 * declarations of its own file.
	 *
	 * The raw scan reported a grant for 22 of anyparse's own 1501 files while
	 * `apq meta '@:allow' src test` finds ZERO real ones — every hit was a doc comment or a test
	 * fixture's source-code literal. Withheld findings read exactly like a clean tree, and in
	 * `Naming` the same hit wrote a refusal sentence naming metadata the file did not carry (T159
	 * could only reorder that sentence behind a more precise cause; masking removes it).
	 *
	 * COST, since consumers call this once per MEMBER: a file that does not mention the tag pays one
	 * `indexOf` exactly as before, and a file that does pays a full lex per call — the answer is a
	 * property of the FILE and is not memoised, because a process-scoped cache is what this project's
	 * first invariant forbids and the run-scoped place for one is the consumer's own file loop. The
	 * bound is (files mentioning the tag) x (their members): 22 files here, and the project lint gate
	 * does not move (90.4s -> 91.4s over 1502 files, inside the run-to-run spread). Do not reuse this
	 * in a hotter loop without hoisting it out of one.
	 *
	 * The one shape this cannot see is a `@:allow` a BUILD MACRO adds; a check whose action depends
	 * on that gates on the macro separately (`TypeTraits.transitivelyCarriesBuildMacro`,
	 * `MemberWriteScan.carriesBuildMacro`), which is the right place for it — a text scan of the
	 * carrier file could never have seen it either.
	 */
	public static function carriesAllowGrant(source: String, plugin: GrammarPlugin): Bool {
		var at: Int = source.indexOf('@:allow');
		if (at < 0) return false;
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		while (at >= 0) {
			if (LexicalRegions.regionAt(at, regions) == null) return true;
			at = source.indexOf('@:allow', at + 1);
		}
		return false;
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
			if (sp != null && cursor >= sp.from && cursor < SourceText.firstTokenEnd(source, sp.from)) {
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
	 * The verbatim declared type SOURCE a BARE identifier carries when it names no value binding at
	 * all but IS a member — declared directly or INHERITED — of the enclosing type declaration: the
	 * implicit-`this` read Haxe resolves without the qualifier. `SymbolIndex`'s import-aware walk
	 * supplies it (`resolvePathFinalMemberTypeSource` over a one-segment member path), so the
	 * extends chain is followed to the SPECIFIC supertype each clause names rather than to any
	 * same-simple-named type elsewhere in the scope.
	 *
	 * Null — the caller keeps its conservative branch — whenever: `ident` is not an identifier node;
	 * it DOES resolve to a value binding; no enclosing type declaration covers it; or the member is
	 * unresolved / ambiguous anywhere along the chain.
	 *
	 * `invisibleBinders` is the gate that is not about resolution but about VISIBILITY, and it is
	 * load-bearing: a binder the scope resolver cannot see looks EXACTLY like an unbound name, so
	 * without it this arm answers the enclosing type's member for a local the author actually wrote
	 * — and a rewrite built on that answer breaks the build. Build the list with
	 * `resolverInvisibleBinderNames`, which is per-file while this is per-site. A NULL list — the
	 * grammar exposes no seam for one of the binder classes — is refused outright: an EMPTY list
	 * means "this file binds nothing invisibly", a null one means the question cannot be asked.
	 */
	public static function implicitThisMemberTypeSource(
		ident: QueryNode, root: QueryNode, shape: RefShape, index: SymbolIndex, file: String, invisibleBinders: Null<Array<String>>
	): Null<String> {
		final identKind: Null<String> = shape.identKind;
		final name: Null<String> = ident.name;
		final span: Null<Span> = ident.span;
		if (identKind == null || ident.kind != identKind || name == null || span == null) return null;
		if (name == shape.selfReferenceText) return null;
		if (invisibleBinders == null || invisibleBinders.contains(name)) return null;
		if (TypeResolver.resolveBindingFrom(name, span, root, shape) != null) return null;
		final enclosing: Null<String> = TypeResolver.enclosingTypeName(root, span);
		return enclosing == null ? null : index.paths.resolvePathFinalMemberTypeSource(file, enclosing, [name]);
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
		final host: Null<SymbolIndexHost> = plugin is SymbolIndexHost ? cast plugin : null;
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

	/**
	 * The offset at which an `extends` / `implements` clause can be spliced into
	 * the header of `decl` (named `typeName`): just past its last header token,
	 * before the body `{`. AST-anchored - each header child node (a type-parameter
	 * constraint, an `extends` / `implements` clause, a conditional block) bounds
	 * the search, and the search itself steps over comments and string literals,
	 * so a `{` written inside a header comment or inside a structural type
	 * constraint is never mistaken for the body brace. Null when no body brace can
	 * be verified before the first body member; a caller that gets null must
	 * refuse the whole operation rather than splice at an unverified offset.
	 *
	 * The name token is located with `activeCodeIdentTokenOffset`, not the raw
	 * scan: a leading block comment that repeats the type name would otherwise
	 * win the race for it, and the whole header search would then run inside that
	 * comment - splicing the clause into comment text. The result still PARSES, so
	 * no downstream reparse gate catches it, while the caller has already staged
	 * the member cut: the members move out and nothing inherits them.
	 */
	public static function typeHeaderInsertOffset(
		source: String, decl: TypeDeclMatch, typeName: String, regions: Array<LexRegion>
	): Null<Int> {
		final brace: Null<Int> = typeBodyBraceOffset(source, decl, typeName, regions);
		return brace == null ? null : headerScan(source, typeHeaderFrom(source, decl, typeName, regions), brace, regions).tokenEnd;
	}

	/**
	 * The offset of `decl`'s body-opening `{`, or null when it has no brace body (`typedef T = Int;`).
	 * Scanned over the HEADER only — comment- and string-aware (`headerScan`), and cut short at the
	 * first child that starts after a located brace, so a `{` inside a type-parameter constraint or a
	 * header comment cannot be mistaken for the body's.
	 *
	 * The position an insertion takes from here is `brace + 1`: right AFTER the brace, never before
	 * the first member — that position sits past the member's leading doc comment, which the insertion
	 * would then silently steal.
	 */
	public static function typeBodyBraceOffset(
		source: String, decl: TypeDeclMatch, typeName: String, regions: Array<LexRegion>
	): Null<Int> {
		final nameSpan: Span = decl.nameNode.span ?? decl.fullSpan;
		final limit: Int = nameSpan.to <= source.length ? nameSpan.to : source.length;
		var from: Int = typeHeaderFrom(source, decl, typeName, regions);
		var brace: Int = -1;
		// Children are in document order: the first one that starts after a located
		// brace belongs to the body, every earlier one is part of the header.
		for (child in decl.nameNode.children) {
			final s: Null<Span> = child.span;
			if (s == null) continue;
			brace = headerScan(source, from, s.from < limit ? s.from : limit, regions).brace;
			if (brace >= 0) break;
			if (s.to > from) from = s.to;
		}
		if (brace < 0) brace = headerScan(source, from, limit, regions).brace;
		return brace < 0 || source.fastCodeAt(brace) != '{'.code ? null : brace;
	}

	/**
	 * The fully-qualified paths the `metaName` annotations written directly above `declNode` grant — the
	 * meta run that decorates that one declaration, and nothing else in the file.
	 *
	 * Not the index's FILE-wide grant list: an annotation written on a sibling MEMBER reaches only that
	 * member's body, so reading one as the type's would let a caller drop a grant a moved body needs.
	 * Walked in the tree because a type-level annotation is a MODULE-level sibling of the declaration it
	 * decorates (and of the `#if` region's, for a file wrapped in one), which no span of the type itself
	 * contains.
	 *
	 * The tag comes from the CALLER rather than being spelled here: this layer is grammar-agnostic, and
	 * `BuildMacroMetaSeamTest` fails the build on a target-language tag written into one. Each argument
	 * is flattened whole, so a multi-target annotation answers every path it names, and the spelling is
	 * returned verbatim: a caller comparing a fully-qualified path must not treat a short one — which
	 * resolves through the file's own imports — as the same grant.
	 */
	public static function accessGrantsOn(tree: Null<QueryNode>, declNode: QueryNode, metaName: String): Array<String> {
		if (tree == null) return [];
		final out: Array<String> = [];
		function walk(node: QueryNode): Void {
			var i: Int = node.children.indexOf(declNode) - 1;
			while (i >= 0 && MemberKinds.META_KINDS.contains(node.children[i].kind)) {
				final meta: QueryNode = node.children[i];
				if (meta.name == metaName) for (arg in meta.children) out.push(flattenPath(arg));
				i--;
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	/** The offset just past `decl`'s NAME token — where its header (supertype clauses, type params) begins. */
	private static function typeHeaderFrom(source: String, decl: TypeDeclMatch, typeName: String, regions: Array<LexRegion>): Int {
		final nameSpan: Span = decl.nameNode.span ?? decl.fullSpan;
		final nameAt: Int = OccurrenceScan.activeCodeIdentTokenOffset(source, nameSpan, typeName, regions);
		return nameAt < 0 ? nameSpan.from : nameAt + typeName.length;
	}

	/**
	 * The first `{` and the end of the last non-whitespace token in
	 * `source[from...to)`, both computed with comments and string literals treated
	 * as invisible. `brace` is -1 when the range holds no brace outside them;
	 * `tokenEnd` falls back to `from` when the range is all trivia.
	 */
	private static function headerScan(source: String, from: Int, to: Int, regions: Array<LexRegion>): { brace: Int, tokenEnd: Int } {
		final end: Int = to <= source.length ? to : source.length;
		var brace: Int = -1;
		var tokenEnd: Int = from;
		var i: Int = from;
		while (i < end) {
			final c: Int = source.fastCodeAt(i);
			if (c == '/'.code && i + 1 < end) {
				final commentEnd: Int = SourceComments.commentRegionEnd(source, i);
				if (commentEnd >= 0) {
					i = commentEnd;
					continue;
				}
			}
			if (c == '"'.code || c == "'".code) {
				// The scanned region starting HERE is the literal; its end is the seam's own answer to
				// where the quote closes. A quote the scan attributes to some other region (a regex
				// body) is not a literal opener and is stepped over as an ordinary byte.
				//
				// REACHABLE, against the reading that a header window — just past the type NAME to the
				// body `{` — can hold no string: a `@:const` type parameter does. `class X extends
				// B<"//">` parses here as a `ConstStringType`, and the whole program compiles and runs
				// on 4.3.7. Drop this arm and the `//` inside the literal opens a line comment that
				// eats the rest of the header, so `typeHeaderInsertOffset` answers the quote's offset
				// and `extract-interface` writes its clause INTO the literal —
				// `class X extends B<" implements IX//">`, which re-parses and passes every gate the op
				// has. Pinned by `TriviaScanSliceTest.testTypeHeaderInsertOffsetStepsOverAHeaderStringLiteral`.
				final literal: Null<LexRegion> = LexicalRegions.regionAt(i, regions);
				i = literal != null && literal.from == i ? literal.to : i + 1;
				tokenEnd = i;
				continue;
			}
			if (c == '{'.code && brace < 0) brace = i;
			if (!SourceText.isSpace(c)) tokenEnd = i + 1;
			i++;
		}
		return { brace: brace, tokenEnd: tokenEnd };
	}

}
