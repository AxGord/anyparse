package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * Outcome of an `Inline.inline` call. `Ok` carries the format-preserving
 * rewritten source; `Err` carries a human-readable diagnostic (cursor
 * not on an inlinable identifier, an unsafe initializer, a reassigned
 * binding, a post-rewrite re-parse failure). Modelled as a sum type so
 * the CLI maps it to stdout vs. stderr + a non-zero exit without a
 * sentinel-string convention. Mirrors `RenameResult`.
 */
enum InlineResult {

	Ok(text: String);
	Err(message: String);

}

/**
 * Scope-correct, format-preserving inline-variable — the sibling of
 * `Rename`, the second refactoring operation built on the query engine.
 *
 * Given a cursor on a LOCAL `var` / `final` declaration (or on any read
 * of it), the inline:
 *
 *  1. Resolves the binding at `line:col` via the shared cursor resolver.
 *  2. Confirms the decl is a local `var` / `final` with an initializer
 *     (not a field / param / for-iterator / catch-var).
 *  3. Refuses unless the binding is single-assignment (no writes) and
 *     the initializer is INLINE-SAFE — side-effect-free and free of
 *     reference-identity / property-getter / evaluation-order hazards.
 *  4. Substitutes every read of the binding with the initializer's exact
 *     source text (parenthesised when the initializer root is an
 *     operator, so precedence is preserved), deletes the decl line, and
 *     re-parses the result; an unparseable rewrite is rejected.
 *
 * The safety model is a strict WHITELIST: the initializer subtree is
 * inlined only when EVERY node kind is in `SAFE_KINDS` (or matches the
 * literal-suffix rule). A missed-but-safe kind costs a spurious refusal;
 * a missed hazardous kind would be a silent miscompile — so the default
 * is always to refuse the unknown. Calls, field/index access, object /
 * array / map literals, lambdas, `new`, assignments, increment /
 * decrement, and interpolated strings embedding any of these are all
 * outside the whitelist and therefore refused.
 *
 * Coordinate convention: `line` / `col` are interpreted exactly as
 * `apq refs` PRINTS them (1-based), identical to
 * `Rename`.
 */
@:nullSafety(Strict)
final class Inline {

	/**
	 * Local-variable declaration kinds the cursor's binding must carry to
	 * be inlinable. Excludes statics, fields, params, for-iterators and
	 * catch-vars — only a plain local `var` / `final` qualifies.
	 */
	private static final LOCAL_DECL_KINDS: Array<String> = ['VarStmt', 'FinalStmt'];

	/**
	 * Inline the local variable whose binding is identified by the symbol
	 * at `line:col` in `source`. `plugin` / `shape` are the caller-owned
	 * grammar plugin and its `RefShape` (the same pair the `refs` CLI
	 * builds), so the resolver stays language-agnostic. Returns
	 * `Ok(rewritten)` or an `Err` describing why the inline could not be
	 * applied. The source is never mutated — the caller decides whether to
	 * write the result.
	 *
	 * Named `inlineVar` (not `inline`) because `inline` is a Haxe keyword
	 * and `Inline.inline(...)` does not parse at the call site.
	 */
	public static function inlineVar(source: String, line: Int, col: Int, plugin: GrammarPlugin, shape: RefShape): InlineResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err('source does not parse: $exception')
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(source, line, col);

		final prep: InlinePrep = resolveInlineTarget(source, line, col, cursor, tree, shape);
		return switch prep {
			case PErr(message): Err(message);
			case POk(target): buildInlineEdits(source, target, plugin, shape);
		};
	}

	/** `from` offset of a Read/Write hit's binding span (callers pre-null-check). */
	private static inline function bindingSpanFrom(hit: RefHit): Int {
		final b: Null<Span> = hit.bindingSpan;
		return b == null ? -1 : b.from;
	}

	/**
	 * Free-identifier safety: for every `IdentExpr` in the initializer
	 * (other than `this`), confirm that
	 *
	 *  - nothing anywhere writes that name (any write ⇒ evaluation-order
	 *    hazard once the decl is removed and the read moves), and
	 *  - the ident resolves to a LOCAL binding — a non-field-member decl.
	 *    An unresolved ident (field / property / static / import) or one
	 *    that resolves to a class member could be a property getter, whose
	 *    duplicated reads would re-invoke the getter.
	 *
	 * Returns an `Err` message string on the first hazard, or null when
	 * every free ident is safe to duplicate.
	 */
	private static function checkFreeIdents(
		name: String, init: QueryNode, tree: QueryNode, initHits: Map<String, Array<RefHit>>
	): Null<String> {
		for (id in namedIdents(init)) {
			final nm: String = id.name;
			final idSpan: Span = id.span;
			final nmHits: Array<RefHit> = initHits[nm] ?? [];
			if (nmHits.exists(h -> h.kind == RefKind.Write))
				return '"$name" initializer depends on reassigned variable "$nm" — cannot inline';

			final readHit: Null<RefHit> = nmHits.find(h -> h.span.from == idSpan.from);
			final boundSpan: Null<Span> = readHit?.bindingSpan;
			if (boundSpan == null) return '"$name" initializer reads non-local "$nm" — cannot inline (may be a property)';

			final boundDecl: Null<QueryNode> = RefactorSupport.nodeAtFrom(tree, boundSpan.from);
			if (boundDecl == null || MemberKinds.isFieldMemberKind(boundDecl.kind))
				return '"$name" initializer reads non-local "$nm" — cannot inline (may be a property)';
		}
		return null;
	}

	/**
	 * Every `IdentExpr` in `node`'s subtree that names a binding (not `this`), in pre-order.
	 */
	private static function namedIdents(node: QueryNode): Array<NamedIdent> {
		final out: Array<NamedIdent> = [];
		function walk(n: QueryNode): Void {
			final name: Null<String> = n.name;
			final span: Null<Span> = n.span;
			if (n.kind == 'IdentExpr' && name != null && name != 'this' && span != null) {
				final named: String = name;
				final at: Span = span;
				out.push({ name: named, span: at });
			}
			for (c in n.children) walk(c);
		}
		walk(node);
		return out;
	}

	/**
	 * Resolve and validate the inline target at `cursor`: the binding must be a
	 * local `var` / `final` (not a field / param / for-iterator / catch-var)
	 * with a single-assignment, inline-safe initializer and at least one read,
	 * every free identifier of which is a stable local. Returns the validated
	 * `InlineTarget` or a `PErr` with the precise refusal reason.
	 */
	private static function resolveInlineTarget(
		source: String, line: Int, col: Int, cursor: Int, tree: QueryNode, shape: RefShape
	): InlinePrep {
		final node: Null<QueryNode> = RefactorSupport.resolveCursorNode(tree, cursor, source);
		if (node == null) return PErr('position $line:$col is not on an inlinable identifier');
		final targetName: Null<String> = node.name;
		if (targetName == null) return PErr('position $line:$col is not on an inlinable identifier');
		final name: String = targetName;

		final hits: Array<RefHit> = Refs.find(name, tree, shape);

		final bindingFrom: Null<Int> = RefactorSupport.resolveBindingFrom(node, hits);
		if (bindingFrom == null) return PErr('could not resolve a binding for "$name" at $line:$col');
		final binding: Int = bindingFrom;

		// The decl node must be a local var / final, not a field / param /
		// for-iterator / catch-var.
		final declNode: Null<QueryNode> = RefactorSupport.nodeAtFrom(tree, binding);
		if (declNode == null) return PErr('could not locate the declaration of "$name" at $line:$col');
		final decl: QueryNode = declNode;
		if (!LOCAL_DECL_KINDS.contains(decl.kind)) return PErr('"$name" is not a local variable (only local var/final can be inlined)');

		// The initializer is the decl's first child.
		final init: Null<QueryNode> = decl.children.length > 0 ? decl.children[0] : null;
		final initSpan: Null<Span> = init?.span;
		if (init == null || initSpan == null) return PErr('"$name" has no initializer to inline');
		final initializer: QueryNode = init;
		final initRange: Span = initSpan;

		// No reassignment: the binding must have zero Write hits.
		final writes: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Write && h.bindingSpan != null && bindingSpanFrom(h) == binding);
		if (writes.length > 0) return PErr('"$name" is reassigned — cannot inline a mutable variable');

		// Collect reads of this binding.
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read && h.bindingSpan != null && bindingSpanFrom(h) == binding);
		if (reads.length == 0) return PErr('"$name" has no reads to inline');

		// The initializer subtree must be entirely inline-safe.
		if (!MemberKinds.isSideEffectFree(initializer, shape))
			return PErr('"$name" initializer is not inline-safe (contains calls/field-access/collection/lambda)');

		// Every free identifier the initializer reads must be a stable
		// local (not reassigned anywhere, not a field / property).
		final initHits: Map<String, Array<RefHit>> = Refs.findMulti(namedIdents(initializer).map(id -> id.name), tree, shape);
		final freeIdentErr: Null<String> = checkFreeIdents(name, initializer, tree, initHits);
		if (freeIdentErr != null) return PErr(freeIdentErr);
		final undecided: Null<String> = undecidedPatternRefusal(source, hits, binding, name);
		if (undecided != null) return PErr(undecided);

		// The "go edit the source and retry" refusals come LAST: that advice is wasted when an
		// unconditional gate above would reject the inline anyway.
		//
		// A braceless `$name` read is a position only a bare IDENTIFIER may occupy:
		// substituting an expression there yields literal text (`'$name'` becomes
		// `'$(a + b)'`), and the re-parse gate cannot catch it because the rewrite is a
		// perfectly valid string. The two blind-region refusals follow it.
		if (reads.exists(h -> h.interpolated))
			return PErr('"$name" is read through a braceless string interpolation ($$$name) - rebrace it as $${$name} first');
		final blind: Null<String> = scopeBlindSpot(source, tree, binding, name, shape);
		return blind != null
			? PErr(blind)
			: POk({
				name: name,
				decl: decl,
				initializer: initializer,
				initRange: initRange,
				reads: reads,
				initHits: initHits
			});
	}

	/**
	 * The refusal for a `case` pattern name bound to the local, or hiding it, that is not a PROVEN
	 * capture (`RefactorSupport.undecidedPatternHit`), or null when there is none: the arm's reads of the
	 * name may be the local's or the capture's, and the substitution can serve only one reading.
	 */
	private static function undecidedPatternRefusal(source: String, hits: Array<RefHit>, binding: Int, name: String): Null<String> {
		final undecided: Null<RefHit> = RefactorSupport.undecidedPatternHit(hits, binding);
		if (undecided == null) return null;
		final at: Position = undecided.span.lineCol(source);
		return '"$name" is named by the case pattern at ${at.line}:${at.col}, which one file cannot prove a capture'
			+ ' rather than a comparison with a constant - the reads of the arm may or may not be this local\'s';
	}

	/**
	 * The diagnostic for a region of the local's OWN function that holds no readable nodes, or null
	 * when the function has none. Two such regions exist and they refuse for one reason: a read of
	 * `name` inside either is invisible to `reads`, so the substitution skips it and the decl
	 * deletion strands it — a rewrite that re-parses cleanly and means something else.
	 *
	 * A `${ … }` interpolation hole IS an ordinary expression position this op handles; the blind
	 * one is a hole the rescan synthesized from an escape-spelled `$`, which carries no parsed
	 * expression. The other is an unparsed conditional-compilation region, blind by construction.
	 */
	private static function scopeBlindSpot(source: String, tree: QueryNode, binding: Int, name: String, shape: RefShape): Null<String> {
		final scope: QueryNode = BinderScan.enclosingFunctionSubtree(tree, binding, shape);
		final opaque: Null<String> = CondRegionScan.opaqueCondRegionDiagnostic(source, scope, name, shape, 'inline of "$name"');
		if (opaque != null) return opaque;
		final blockKind: Null<String> = shape.stringInterpBlockKind;
		return blockKind != null && OccurrenceScan.unreadableInterpBlock(scope, blockKind) != null
			? '"$name" shares its scope with an escape-spelled string interpolation carrying no parsed expression -'
				+ ' a read of the name inside it cannot be seen; respell that interpolation first'
			: null;
	}

	/**
	 * Build and apply the inline edits for a validated `target`: substitute the
	 * initializer's exact source (parenthesised when its root is an operator) for
	 * every read, delete the decl line (refusing if the decl shares its line),
	 * then re-parse the rewrite — an unparseable result is rejected.
	 */
	private static function buildInlineEdits(source: String, target: InlineTarget, plugin: GrammarPlugin, shape: RefShape): InlineResult {
		final name: String = target.name;
		final initializer: QueryNode = target.initializer;
		final initRange: Span = target.initRange;

		// Build the substitution text: the initializer's exact source,
		// parenthesised when the root is an operator.
		final initText: String = source.substring(initRange.from, initRange.to);
		// The initializer is already proven side-effect-free, so its root can only ever be an atom,
		// a grouping node or an operator: the wider `parenFreeRootKinds` would add members
		// unreachable here.
		final substitution: String = MemberKinds.atomicRootKinds(shape).contains(initializer.kind) ? initText : '($initText)';

		final edits: Array<{ span: Span, text: String }> = [];

		// Each read's identifier token is replaced with the substitution.
		final readFroms: Array<Int> = [];
		for (read in target.reads) {
			final identFrom: Int = SourceText.identTokenOffset(source, read.span, name);
			if (identFrom < 0) continue;
			readFroms.push(identFrom);
			edits.push({ span: new Span(identFrom, identFrom + name.length), text: substitution });
		}

		// The decl line is deleted. The decl span includes its trailing
		// `;`; the line is removed only when the decl owns it exclusively
		// (whitespace before, nothing but whitespace + the line break
		// after) — otherwise we refuse rather than mangle adjacent code.
		final declSpan: Null<Span> = target.decl.span;
		final deleteSpan: Null<Span> = declSpan == null ? null : ElementSpan.ownedLinesSpan(source, declSpan);
		if (deleteSpan == null) return Err('"$name" declaration shares its line — cannot inline cleanly');
		edits.push({ span: deleteSpan, text: '' });

		final rewritten: String = CanonicalEdit.applyEdits(source, edits);
		if (rewritten == source) return Err('inline of "$name" is a no-op');

		final newTree: QueryNode = try plugin.parseFile(rewritten) catch (exception: ParseError) return Err(
			'rewritten source does not parse: $exception'
		)
		catch (exception: Exception) return Err('rewritten source does not parse: ${exception.message}');
		final paren: Int = substitution == initText ? 0 : 1;
		final captured: Null<Int> = recapturedIdent(target, readFroms, edits, paren, newTree, shape);
		if (captured == null) return Ok(rewritten);
		final at: Position = new Span(captured, captured).lineCol(rewritten);
		return Err(
			'inline of "$name" is unsafe: at ${at.line}:${at.col} of the rewrite an identifier of its initializer would bind to'
			+ ' a different declaration - a binding of that name shadows it there'
		);
	}

	/**
	 * The offset in `rewritten` of the first substituted identifier that binds to a DIFFERENT declaration
	 * than the same identifier does inside the initializer, or null when every one keeps its binding. A
	 * read site can sit where a lambda parameter, a nested local or a `case` capture of an initializer's
	 * name shadows it, and the substitution then reads that binding instead. Decided by re-resolving the
	 * rewritten tree, the way `Rename.captureMismatch` decides a rename; `paren` is the offset of the
	 * initializer text inside the substitution.
	 */
	private static function recapturedIdent(
		target: InlineTarget, readFroms: Array<Int>, edits: Array<{ span: Span, text: String }>, paren: Int, newTree: QueryNode,
		shape: RefShape
	): Null<Int> {
		final idents: Array<NamedIdent> = namedIdents(target.initializer);
		final newHits: Map<String, Array<RefHit>> = Refs.findMulti([for (id in idents) id.name], newTree, shape);
		for (id in idents) {
			final from: Int = id.span.from;
			final bound: Null<Span> = (target.initHits[id.name] ?? []).find(h -> h.span.from == from)?.bindingSpan;
			if (bound == null) continue;
			final expected: Int = shifted(bound.from, edits);
			final hits: Array<RefHit> = newHits[id.name] ?? [];
			for (readFrom in readFroms) {
				final at: Int = shifted(readFrom, edits) + paren + (from - target.initRange.from);
				final hit: Null<RefHit> = hits.find(h -> h.span.from == at);
				if (hit == null || hit.bindingSpan?.from != expected) return at;
			}
		}
		return null;
	}

	/** Where `offset` of the original source lands once every edit wholly before it is applied. */
	private static function shifted(offset: Int, edits: Array<{ span: Span, text: String }>): Int {
		var out: Int = offset;
		for (edit in edits) if (edit.span.to <= offset) out += edit.text.length - (edit.span.to - edit.span.from);
		return out;
	}

}

/**
 * A validated inline target: the binding name, its local decl node, the
 * inline-safe initializer subtree and its exact source span, and the reads
 * to substitute.
 */
private typedef InlineTarget = {
	final name: String;
	final decl: QueryNode;
	final initializer: QueryNode;
	final initRange: Span;

	/** Every hit of every name the initializer reads, resolved once over the original tree. */
	final initHits: Map<String, Array<RefHit>>;
	final reads: Array<RefHit>;
};

/** An identifier of an initializer that names a binding, with the span it is written at. */
private typedef NamedIdent = {
	final name: String;
	final span: Span;
};

/** Resolution outcome of `resolveInlineTarget`: the target or a refusal. */
private enum InlinePrep {

	POk(target: InlineTarget);
	PErr(message: String);

}
