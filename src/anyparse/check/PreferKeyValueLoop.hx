package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.Violation;
import anyparse.check.LoopScan.IndexedLoopHeader;
import anyparse.check.LoopScan.IntervalLoopSeams;
import anyparse.check.LoopScan.LoopSeams;
import anyparse.query.GrammarPlugin;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;

/**
 * Flags an INDEXED `for` that only wanted the element — `for (i in 0...X.length)` whose body
 * OPENS with `final v = X[i];` — which Haxe's key-value iteration writes directly:
 * `for (i => v in X)`, with that first statement gone. `Severity.Info`, paired with an autofix.
 * DEFAULT OFF (`DefaultOff`): the two spellings are equivalent, so which one a project wants is
 * a style choice — opt in with `"prefer-keyvalue-loop": { "enabled": true }`.
 *
 * The index stays BOUND, which is what makes the rewrite worth having over `for (v in X)`: an
 * inner `for (j in i + 1...X.length)`, an `i`-keyed lookup elsewhere in the body, a `trace(i)` —
 * all keep working untouched. A body that never reads `i` again is still rewritten to the
 * key-value form (the transform this rule is specified as); collapsing THAT case to
 * `for (v in X)` is a different rewrite and is deliberately out of scope.
 *
 * ## The shape it accepts
 *
 * A `for` whose iterable is exactly `0...X.length` for a bare identifier `X`, whose body is a
 * braced block of at least two statements, and whose FIRST statement is a single-variable local
 * declaration (`var` or `final`, with or without a type annotation) initialised by exactly `X[i]`.
 *
 * ## Soundness gates (all required for a flag)
 *
 * - **`X` is a bare identifier.** A path receiver (`this.items`, `a.b`) is skipped: the type
 *   resolution behind the rewrite gate reads a BINDING's annotation, and a check's `run` has no
 *   `SymbolIndex` to walk a path with. A bare identifier that binds to a FIELD does resolve and
 *   IS accepted.
 * - **`X`'s length cannot move.** `0...X.length` evaluates the bound ONCE; `for (i => v in X)`
 *   re-asks the iterator every step, so a body that appends to `X` would turn a terminating loop
 *   into a runaway one. Every mention of `X` in the body must therefore be a `length` read or an
 *   index READ — see `LoopScan.usedOnlyAsStableCollection`, whose doc also states the limit both
 *   rules inherit: the scan is BODY-LOCAL, so an alias handed out before the loop
 *   (`register(X); for (…) { tick(); }`) or a call that mutates `X` through a field the callee
 *   owns is invisible to it. Closing that class needs whole-program alias analysis; this rule is
 *   `Info` and opt-in precisely because it stops short of one.
 * - **Exactly one `X[i]`.** Any OTHER `X[i]` in the body would have to become `v`, which is a
 *   rename this rule does not attempt — skipped rather than half-rewritten.
 * - **Nothing writes `i` or `v`.** A range binder and a key binder are both read-only in spirit;
 *   a write to either means the loop is doing something this rewrite does not model. (`X` itself
 *   needs no separate write gate — a write target is not one of the two positions the
 *   stable-collection scan admits.)
 * - **No statement-position re-declaration.** No statement after the consumed declaration
 *   re-declares `i`, `v` or `X` as a local `var` / `final`. Binders of OTHER kinds — a `catch`
 *   variable, a lambda parameter, a case-pattern capture, a nested loop binder — are NOT scanned,
 *   and do not need to be: each of them shadows the moved header binding exactly as it shadowed
 *   the block-scoped declaration.
 * - **Distinct names.** `i`, `v` and `X` must be three different names (`for (i => i in i)` is
 *   not a rewrite, it is a collision).
 * - **No closure gate is needed.** Unlike its sibling `dead-binder-counter-loop`, this rewrite
 *   re-scopes nothing: a block-scoped `final v` and a Haxe loop binder are both fresh per
 *   iteration, so a capturing lambda observes the same value either way.
 *
 * ## Rewrite gate (report-only when it fails)
 *
 * A container that RESOLVES to something other than `Array` is not reported at all — the message
 * names a form that would not compile for it. An UNRESOLVED `X` (unannotated, a path, a plugin
 * without `TypeInfoProvider`) still reports, and there the FIX additionally needs the element
 * type provable, because it DROPS the declaration and with it any `:Type` annotation: `X`'s
 * binding must be declared `Array<E>` and the annotation — when the declaration carries one —
 * must be exactly `E`. A widening annotation, or a comment anywhere in the replaced region
 * (through the end of the declaration's line, so a trailing comment cannot silently migrate onto
 * the loop header), leaves the finding report-only.
 *
 * ## Grammar-agnostic
 *
 * Driven by `LoopScan.seamsOf` plus `RefShape.intervalKind`; any unset kind makes the check a
 * no-op. The `length` member name is the one language-specific token, spelled as a constant the
 * way the other member-name-matching checks spell theirs.
 */
@:nullSafety(Strict)
final class PreferKeyValueLoop implements Check implements DefaultOff {

	/** This check's stable id, spelled once. */
	private static inline final RULE_ID: String = 'prefer-keyvalue-loop';

	/** The element-count member an indexed loop bounds itself by. */
	private static inline final LENGTH_MEMBER: String = 'length';

	/** The one container nominal whose key-value iteration yields the `0...length` indices. */
	private static inline final ARRAY_TYPE: String = 'Array';

	/** Minimum body statements: the consumed declaration plus at least one real statement. */
	private static inline final MIN_BODY_STATEMENTS: Int = 2;

	/** The one `X[i]` the rewrite consumes — any further one would need renaming to the value binder. */
	private static inline final CONSUMED_INDEX_READS: Int = 1;

	/** `Array<E>` carries exactly one type argument; anything else is not the container this rewrite models. */
	private static inline final ARRAY_TYPE_ARGUMENTS: Int = 1;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'an indexed for whose body opens by binding X[i], replaceable with for (i => v in X)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final typed: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		return RunScan.collectWith(files, plugin, LoopScan.intervalSeamsOf(plugin.refShape()), (entry, tree, s, violations) -> {
			final types: Null<Map<Int, String>> = typed?.declaredTypeSources(entry.source);
			walk(tree, tree, entry.file, entry.source, types, s, violations);
		});
	}

	/**
	 * Rewrite each flagged loop's header into `for (i => v in X) {` and drop the declaration it
	 * consumed — one splice covering `[for, declaration end)`. Refused, leaving the finding
	 * report-only, when the element type is not provable (see the type doc) or a comment sits in
	 * the replaced region.
	 */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return RunScan.walkedEdits(
			plugin, source, LoopScan.intervalSeamsOf(plugin.refShape()), violations,
			(tree, types, s, wanted, out) -> fixWalk(tree, tree, source, types, s, wanted, out)
		);
	}

	/** Descend `node`, testing it as a loop and recursing; a reification subtree is skipped wholesale. */
	private static function walk(
		node: QueryNode, root: QueryNode, file: String, source: String, types: Null<Map<Int, String>>, s: IntervalLoopSeams,
		out: Array<Violation>
	): Void {
		if (s.core.opaqueKinds.contains(node.kind)) return;
		final m: Null<Match> = analyze(node, root, source, types, s);
		if (m != null) out.push({
			file: file,
			span: m.forSpan,
			rule: RULE_ID,
			severity: Severity.Info,
			message: 'this indexed loop can be for (${m.keyVar} => ${m.valueVar} in ${m.collection})'
		});
		for (c in node.children) walk(c, root, file, source, types, s, out);
	}

	/** Mirror of `walk` for the fix path: emit the header rewrite for each wanted, rewritable loop. */
	private static function fixWalk(
		node: QueryNode, root: QueryNode, source: String, types: Null<Map<Int, String>>, s: IntervalLoopSeams, wanted: Array<String>,
		out: Array<FixEdit>
	): Void {
		if (s.core.opaqueKinds.contains(node.kind)) return;
		final m: Null<Match> = analyze(node, root, source, types, s);
		if (m != null && wanted.contains('${m.forSpan.from}:${m.forSpan.to}')) {
			final e: Null<FixEdit> = buildEdit(m, source);
			if (e != null) out.push(e);
		}
		for (c in node.children) fixWalk(c, root, source, types, s, wanted, out);
	}

	/**
	 * The matched loop — its span, the consumed declaration, the three names, and the two type
	 * annotations the rewrite gate reads — or null when any gate fails. Shared by `walk` (report)
	 * and `fixWalk` (rewrite) so both see one decision.
	 */
	private static function analyze(
		forNode: QueryNode, root: QueryNode, source: String, types: Null<Map<Int, String>>, s: IntervalLoopSeams
	): Null<Match> {
		final core: LoopSeams = s.core;
		final h: Null<IndexedLoopHeader> = matchHeader(forNode, source, s);
		if (h == null) return null;
		final decl: QueryNode = h.body.children[0];
		final valueVar: Null<String> = LoopScan.singleLocalDeclName(decl, core.localDeclKinds, core);
		if (valueVar == null || valueVar == h.index || valueVar == h.collection) return null;
		final init: QueryNode = decl.children[0];
		if (!LoopScan.isIndexAccessOf(init, h.collection, core)) return null;
		if (LoopScan.bareIdentName(init.children[1], core) != h.index) return null;
		if (!bodyAdmitsRewrite(h.body, h.index, valueVar, h.collection, core)) return null;
		final forSpan: Null<Span> = forNode.span;
		final declSpan: Null<Span> = decl.span;
		if (forSpan == null || declSpan == null) return null;
		final collectionTypeSource: Null<String> = LoopScan.identTypeSource(h.sizeReceiver, root, types, core);
		// A container that RESOLVES to something other than `Array` has no key-value iteration to
		// offer, so the message would be advice that does not compile; only an UNRESOLVED one keeps
		// the report-only tolerance, where the suggestion is a lead rather than a claim.
		return collectionTypeSource != null && NominalTypes.outerNominalOf(collectionTypeSource) != ARRAY_TYPE ? null : {
			forSpan: forSpan,
			declSpan: declSpan,
			keyVar: h.index,
			valueVar: valueVar,
			collection: h.collection,
			collectionTypeSource: collectionTypeSource,
			declTypeSource: types == null ? null : types[declSpan.from]
		};
	}

	/**
	 * `LoopScan.indexedHeaderOf` narrowed by THIS rule's own demand on the body: a braced block of at
	 * least two statements, since the rewrite consumes the first one and must leave the loop
	 * something to run.
	 */
	private static function matchHeader(forNode: QueryNode, source: String, s: IntervalLoopSeams): Null<IndexedLoopHeader> {
		final h: Null<IndexedLoopHeader> = LoopScan.indexedHeaderOf(forNode, source, LENGTH_MEMBER, s);
		if (h == null) return null;
		final body: QueryNode = h.body;
		return body.kind != s.core.blockStmtKind || body.children.length < MIN_BODY_STATEMENTS ? null : h;
	}

	/**
	 * Whether the body tolerates the rewrite: nothing writes the key, the value or the collection;
	 * the collection is only read in length-preserving positions; exactly one `X[i]` (the consumed
	 * one) exists; and no statement after the consumed declaration re-declares any of the three.
	 */
	private static function bodyAdmitsRewrite(
		body: QueryNode, keyVar: String, valueVar: String, collection: String, core: LoopSeams
	): Bool {
		if (LoopScan.countWrites(body, keyVar, core) != 0) return false;
		if (LoopScan.countWrites(body, valueVar, core) != 0) return false;
		if (LoopScan.countIndexReads(body, collection, keyVar, core) != CONSUMED_INDEX_READS) return false;
		if (!LoopScan.usedOnlyAsStableCollection(body, collection, LENGTH_MEMBER, core)) return false;
		for (i in 1...body.children.length) {
			final stmt: QueryNode = body.children[i];
			if (
				LoopScan.declares(stmt, keyVar, core) || LoopScan.declares(stmt, valueVar, core)
				|| LoopScan.declares(stmt, collection, core)
			)
				return false;
		}
		return true;
	}

	/** The single `{span, text}` replacing `[for, declaration end)` with the key-value header, or null when the rewrite is refused. */
	private static function buildEdit(m: Match, source: String): Null<FixEdit> {
		// Reaching to the end of the declaration's LINE, not just its `;`: a trailing comment there
		// documents the statement the rewrite deletes, and the splice would silently re-attach it to
		// the loop header.
		return if (!provablyArrayElement(m))
			null
		else if (CheckScan.hasCommentMarker(source, m.forSpan.from, lineEndAfter(source, m.declSpan.to)))
			null
		else
			{ span: new Span(m.forSpan.from, m.declSpan.to), text: 'for (${m.keyVar} => ${m.valueVar} in ${m.collection}) {' };
	}

	/** The offset of the newline ending the line `from` sits on, or the source end — how far a trailing comment can reach. */
	private static function lineEndAfter(source: String, from: Int): Int {
		final at: Int = source.indexOf('\n', from);
		return at == -1 ? source.length : at;
	}

	/**
	 * Whether dropping the declaration provably keeps the value binder's type: the collection is
	 * a declared `Array<E>`, and the declaration either carries no annotation or carries exactly
	 * `E`. A widening annotation (`Dynamic`, a supertype) would change what the binder is typed
	 * as, so it stays report-only.
	 */
	private static function provablyArrayElement(m: Match): Bool {
		final collectionType: Null<String> = m.collectionTypeSource;
		if (collectionType == null || NominalTypes.outerNominalOf(collectionType) != ARRAY_TYPE) return false;
		final declared: Null<String> = m.declTypeSource;
		if (declared == null) return true;
		final args: Null<Array<String>> = NominalTypes.typeArgumentSourcesOf(collectionType);
		return args != null && args.length == ARRAY_TYPE_ARGUMENTS && StringTools.trim(args[0]) == StringTools.trim(declared);
	}

}

/** One matched loop: the spans the rewrite splices, the three names it re-spells, and the annotations its type gate reads. */
private typedef Match = {
	var forSpan: Span;
	var declSpan: Span;
	var keyVar: String;
	var valueVar: String;
	var collection: String;
	var collectionTypeSource: Null<String>;
	var declTypeSource: Null<String>;
}
