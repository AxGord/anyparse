package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.Violation;
import anyparse.check.ElementLoopRewrite.BinderChoice;
import anyparse.check.LoopScan.IndexedLoopHeader;
import anyparse.check.LoopScan.IntervalLoopSeams;
import anyparse.check.LoopScan.LoopFileScan;
import anyparse.check.LoopScan.LoopSeams;
import anyparse.query.GrammarPlugin;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;

using Lambda;

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
 * ## The no-opener arm
 *
 * A body with no such opener that reads `X[i]` and uses `i` elsewhere too becomes `for (i => v in X)` with every `X[i]`
 * re-spelled `v` (`v` is the singular of `X` without its leading underscores). A body whose only reads of `i` are `X[i]` is
 * `prefer-value-loop`'s, and one that opens with the binding is the opener arm's whatever that arm decides. Beyond the gates
 * above it refuses an `X[i]` under a nested binder of `i` and any closure mentioning `X` - a closure reads the slot when it RUNS,
 * the binder holds it from the iteration that made it. Report-only when the binder name is taken anywhere in the enclosing
 * function or by a member, when the container is unresolved, and when the body holds a call that can reach `X`
 * behind the loop's back (`ElementLoopRewrite.callsThroughSelf`): such a callee can replace `X[i]` after the
 * binder was read, or grow `X`, which the key-value iterator follows. The opener arm takes the same report-only
 * gate, and an enclosing or nested indexed loop deriving the same binder name leaves either arm report-only.
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

	/** The opener arm's decline when dropping the declaration could change the value binder's type. */
	private static inline final ELEMENT_TYPE_DECLINE: String = 'the collection is not a declared `Array<E>` whose `E` the dropped declaration '
		+ 'carries, so dropping it could change the value binder\'s type';

	/** The opener arm's decline when a trailing comment on the dropped declaration's line would move onto the loop header. */
	private static inline final TRAILING_COMMENT_DECLINE: String =
		'a trailing comment on the dropped declaration\'s line would move onto the loop header';

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
			walk(
				tree, LoopScan.fileScanOf(tree, entry.source, typed?.declaredTypeSources(entry.source), plugin, s), null, entry.file,
				violations
			);
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
			(tree, types, s, wanted, out) ->
				fixWalk(tree, LoopScan.fileScanOf(tree, source, types, plugin, s), null, wanted, violations, out)
		);
	}

	/** Descend `node`, testing it as a loop and recursing; a reification subtree is skipped wholesale. */
	private static function walk(node: QueryNode, f: LoopFileScan, outerFn: Null<QueryNode>, file: String, out: Array<Violation>): Void {
		if (f.seams.core.opaqueKinds.contains(node.kind)) return;
		final opener: Null<Match> = analyze(node, f.root, f.source, f.types, f.seams);
		final reads: Null<ReadsMatch> = opener == null ? analyzeReads(node, f, outerFn) : null;
		if (opener != null)
			out.push(finding(
				file, opener.forSpan, 'this indexed loop can be for (${opener.keyVar} => ${opener.valueVar} in ${opener.collection})'
			));
		else if (reads != null)
			out.push(finding(file, reads.forSpan, readsAdvice(reads)));
		final fn: Null<QueryNode> = outerFn ?? enclosingFunctionAt(node, f);
		for (c in node.children) walk(c, f, fn, file, out);
	}

	/** Mirror of `walk` for the fix path: emit the header rewrite for each wanted, rewritable loop. */
	private static function fixWalk(
		node: QueryNode, f: LoopFileScan, outerFn: Null<QueryNode>, wanted: Array<String>, violations: Array<Violation>,
		out: Array<FixEdit>
	): Void {
		if (f.seams.core.opaqueKinds.contains(node.kind)) return;
		final m: Null<Match> = analyze(node, f.root, f.source, f.types, f.seams);
		if (m != null && wanted.contains('${m.forSpan.from}:${m.forSpan.to}')) {
			final decline: Null<String> = openerDecline(m, f.source);
			if (decline == null)
				out.push(buildEdit(m));
			else
				ElementLoopRewrite.declineAt(violations, RULE_ID, m.forSpan, decline);
		}
		final r: Null<ReadsMatch> = m == null ? analyzeReads(node, f, outerFn) : null;
		if (r != null && wanted.contains('${r.forSpan.from}:${r.forSpan.to}')) {
			final edits: Array<FixEdit> = buildReadEdits(r, f.source);
			if (edits.length == 0)
				ElementLoopRewrite.declineAt(violations, RULE_ID, r.forSpan, r.decline ?? ElementLoopRewrite.COMMENT_DECLINE);
			for (e in edits) out.push(e);
		}
		final fn: Null<QueryNode> = outerFn ?? enclosingFunctionAt(node, f);
		for (c in node.children) fixWalk(c, f, fn, wanted, violations, out);
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
			declTypeSource: types == null ? null : types[declSpan.from],
			selfCall: ElementLoopRewrite.callsThroughSelf(h.body, core)
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

	/**
	 * The single `{span, text}` replacing `[for, declaration end)` with the key-value header.
	 */
	private static function buildEdit(m: Match): FixEdit {
		return { span: new Span(m.forSpan.from, m.declSpan.to), text: 'for (${m.keyVar} => ${m.valueVar} in ${m.collection}) {' };
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

	/**
	 * The NO-OPENER arm: `for (i in 0...X.length)` whose body reads `X[i]` at least once and uses `i`
	 * somewhere else too, with no `final v = X[i];` to consume — the header becomes `for (i => v in X)`
	 * and every `X[i]` becomes `v`. Null when a gate fails; see the type doc for each one.
	 *
	 * Disjoint from both neighbours by construction: a body that OPENS with the binding is the opener
	 * arm's claim whatever its other gates answer, and a body whose every read of `i` is an `X[i]` is
	 * `prefer-value-loop`'s.
	 */
	private static function analyzeReads(forNode: QueryNode, f: LoopFileScan, outerFn: Null<QueryNode>): Null<ReadsMatch> {
		final core: LoopSeams = f.seams.core;
		final h: Null<IndexedLoopHeader> = LoopScan.indexedHeaderOf(forNode, f.source, LENGTH_MEMBER, f.seams);
		if (h == null || LoopScan.opensWithIndexBinding(h.body, h.collection, h.index, core)) return null;
		final reads: Array<QueryNode> = LoopScan.collectIndexReads(h.body, h.collection, h.index, core);
		if (reads.length == 0) return null;
		if (LoopScan.countReads(h.body, h.index, core) == reads.length) return null;
		if (LoopScan.countWrites(h.body, h.index, core) != 0) return null;
		if (!ElementLoopRewrite.bodyAdmitsElementLoop(h, f.source, LENGTH_MEMBER, core)) return null;
		final forSpan: Null<Span> = forNode.span;
		final iterableSpan: Null<Span> = h.iterable.span;
		final readSpans: Null<Array<Span>> = spansOf(reads);
		if (forSpan == null || iterableSpan == null || readSpans == null) return null;
		final collectionTypeSource: Null<String> = LoopScan.identTypeSource(h.sizeReceiver, f.root, f.types, core);
		if (collectionTypeSource != null && NominalTypes.outerNominalOf(collectionTypeSource) != ARRAY_TYPE) return null;
		final binder: BinderChoice = binderOf(f, forNode, outerFn?.span ?? new Span(0, f.source.length), h.index, h.collection);
		return {
			forSpan: forSpan,
			iterableSpan: iterableSpan,
			index: h.index,
			collection: h.collection,
			binder: binder.name,
			readSpans: readSpans,
			decline: ElementLoopRewrite.elementDecline(binder, h.collection, collectionTypeSource, h.body, core)
		};
	}

	/**
	 * The value binder the no-opener arm would write, or null. The singular of the collection name with
	 * its leading underscores dropped (`_points` -> `point`), refused when the enclosing FUNCTION spells
	 * it anywhere in active text (a parameter, an outer local, a use) or the file declares a member or a
	 * module-level value of that name: the key-value binder would shadow it for the whole loop.
	 */
	private static function binderOf(f: LoopFileScan, forNode: QueryNode, scope: Span, index: String, collection: String): BinderChoice {
		final choice: BinderChoice = ElementLoopRewrite.binderFor(
			f, forNode, index, ElementLoopRewrite.withoutLeadingUnderscores(collection), scope, 'the enclosing function'
		);
		final name: Null<String> = choice.name;
		final shape: RefShape = f.seams.core.shape;
		final valueDeclKinds: Array<String> = (shape.memberDeclKinds ?? []).concat(shape.moduleValueDeclKinds);
		return name == null || !declaresValue(f.root, name, valueDeclKinds)
			? choice
			: { name: null, refusal: 'the element name `$name` is declared as a member or a module-level value' };
	}

	/** Whether `node`'s subtree declares a member or module-level value named `name`. */
	private static function declaresValue(node: QueryNode, name: String, kinds: Array<String>): Bool {
		return kinds.contains(node.kind) && node.name == name || node.children.exists(c -> declaresValue(c, name, kinds));
	}

	/** The no-opener finding's text: the binder named outright, or the key-value form described when none can be written. */
	private static function readsAdvice(r: ReadsMatch): String {
		final binder: Null<String> = r.binder;
		return binder == null
			? 'this indexed loop reads ${r.collection}[${r.index}]; it can be a key-value loop over ${r.collection}'
			: 'this indexed loop can be for (${r.index} => $binder in ${r.collection})';
	}

	/** The no-opener splices — the key-value header, then each `X[i]` as the binder — or none when the fix is refused. */
	private static function buildReadEdits(r: ReadsMatch, source: String): Array<FixEdit> {
		final binder: Null<String> = r.binder;
		return binder == null || r.decline != null
			? []
			: ElementLoopRewrite.elementReadEdits(
				source, r.forSpan, r.iterableSpan, 'for (${r.index} => $binder in ${r.collection}', r.readSpans, binder
			);
	}

	/**
	 * `node` when it opens a function, else null; the walk keeps the first one it enters, which is the outermost.
	 */
	private static function enclosingFunctionAt(node: QueryNode, f: LoopFileScan): Null<QueryNode> {
		return (f.seams.core.shape.functionKinds ?? []).contains(node.kind) ? node : null;
	}

	/** One `Info` finding of this rule at `span`. */
	private static function finding(file: String, span: Span, message: String): Violation {
		return {
			file: file,
			span: span,
			rule: RULE_ID,
			severity: Severity.Info,
			message: message
		};
	}

	/** The span of every node in `nodes`, in order, or null when the tree carries none for one of them. */
	private static function spansOf(nodes: Array<QueryNode>): Null<Array<Span>> {
		final out: Array<Span> = [];
		for (n in nodes) {
			final span: Null<Span> = n.span;
			if (span == null) return null;
			out.push(span);
		}
		return out;
	}

	/**
	 * Why the opener arm withholds its fix, or null: an element type the dropped declaration could change,
	 * a comment inside the replaced region, a trailing comment on the declaration's line (it documents the
	 * statement the rewrite deletes, and the splice would re-attach it to the loop header), or a call that
	 * can reach the collection behind the loop's back — the binder is read at the iteration start, as the
	 * declaration was, but a callee can still grow `X`, which the key-value iterator follows.
	 */
	private static function openerDecline(m: Match, source: String): Null<String> {
		final declEnd: Int = m.declSpan.to;
		return if (!provablyArrayElement(m))
			ELEMENT_TYPE_DECLINE
		else if (CheckScan.hasCommentMarker(source, m.forSpan.from, declEnd))
			ElementLoopRewrite.COMMENT_DECLINE
		else if (CheckScan.hasCommentMarker(source, declEnd, lineEndAfter(source, declEnd)))
			TRAILING_COMMENT_DECLINE
		else if (m.selfCall)
			ElementLoopRewrite.SELF_CALL_DECLINE
		else
			null;
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
	var selfCall: Bool;
}

/**
 * One loop the no-opener arm matched: the spans its splices cover, the two names it reads, the
 * binder it would write, and why the fix is withheld when it is (the finding's `declineReason`).
 */
private typedef ReadsMatch = {
	var forSpan: Span;
	var iterableSpan: Span;
	var index: String;
	var collection: String;
	var binder: Null<String>;
	var readSpans: Array<Span>;
	var decline: Null<String>;
}
