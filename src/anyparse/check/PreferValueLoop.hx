package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.Violation;
import anyparse.check.LoopScan.IndexedLoopHeader;
import anyparse.check.LoopScan.IntervalLoopSeams;
import anyparse.check.LoopScan.LoopSeams;
import anyparse.query.GrammarPlugin;
import anyparse.query.NominalTypes;
import anyparse.query.OccurrenceScan;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags an INDEXED `for` whose index is never anything but an index into the collection it
 * counts — `for (i in 0...X.length)` where every mention of `i` sits inside an `X[i]` — which
 * Haxe writes directly as `for (v in X)`. `Severity.Info`, paired with an autofix. DEFAULT OFF
 * (`DefaultOff`): the two spellings are equivalent, so which one a project wants is a style
 * choice — opt in with `"prefer-value-loop": { "enabled": true }`.
 *
 * Disjoint from its sibling `prefer-keyvalue-loop` BY ENFORCEMENT, not by shape luck:
 * `claimedByKeyValueLoop` declines exactly the loops that rule claims. A statement-position
 * `for` only — `ForExpr` (an array comprehension, a value-position `for`) is out of scope.
 *
 * ## Soundness gates (all required for a flag)
 *
 * - **`X` is a bare identifier.** A path receiver (`this.items`) is skipped for the reason the
 *   sibling states: the type resolution behind the rewrite reads a BINDING's annotation.
 * - **`X`'s length cannot move** (`LoopScan.usedOnlyAsStableCollection`). `0...X.length`
 *   evaluates its bound once while `for (v in X)` re-asks the iterator every step, so a body
 *   that appends to `X` would turn a terminating loop into a runaway one.
 * - **Every read of `i` is an `X[i]`**, and there is at least one — `LoopScan.countReads` equal
 *   to `LoopScan.countIndexReads`.
 * - **Nothing in the body BINDS `i` or `X`** (`LoopScan.bindsName`, wider than `declares`): a
 *   nested `for (i in …)`, a lambda parameter `i`, a `catch (i:…)` or a `case var i` shadows the
 *   index, and the `X[i]` underneath then belongs to that binder rather than to this loop.
 * - **The body TEXT mentions `i` nowhere else** in ACTIVE code (`OccurrenceScan.referencedInRange`
 *   under `inertMask`). What an `opaqueKinds` subtree hides — a `macro` quotation answering
 *   "absent" where the honest answer is "unknown" — reaches no walk, and a missed mention is a
 *   licence to DELETE the index. The three index gates are COMPLEMENTARY, never redundant: a bare
 *   `$i` leaves no standalone `i` token in the bytes, so only the read count sees it.
 * - **`i` and `X` are different names.**
 *
 * ## Rewrite gate (report-only when it fails)
 *
 * A container that RESOLVES to something other than `Array` is not reported at all: `String`
 * carries a `length` and no iterator, so the advice would not compile. An UNRESOLVED one is
 * reported without a fix. The binder comes from `singularOf`, an English plural convention
 * private to this check; no singular, a reserved word, or a name the body mentions in active
 * text leaves the finding report-only, as does a comment inside a replaced region. One
 * pathological decline is accepted: `macro $i{nm}` spells the reification marker with the token
 * a loop named `i` uses, and a macro body is active code no mask may hide.
 */
@:nullSafety(Strict)
final class PreferValueLoop implements Check implements DefaultOff {

	/** This check's stable id, spelled once. */
	private static inline final RULE_ID: String = 'prefer-value-loop';

	/** The element-count member an indexed loop bounds itself by. */
	private static inline final LENGTH_MEMBER: String = 'length';

	/** The one container nominal whose value iteration yields what `X[0...length]` yields. */
	private static inline final ARRAY_TYPE: String = 'Array';

	/** The sibling's minimum body: the declaration it consumes plus at least one real statement. */
	private static inline final MIN_KEY_VALUE_STATEMENTS: Int = 2;

	/** The one `X[i]` the sibling's rewrite consumes; a second one is outside its claim. */
	private static inline final CONSUMED_INDEX_READS: Int = 1;

	/** The English vowels, for deciding which `…ies` plural came from a `…y` singular. */
	private static inline final VOWELS: String = 'aeiou';

	/** The ending a `…y` singular takes in the plural. */
	private static inline final PLURAL_IES: String = 'ies';

	/** The ending the singular behind an `…ies` plural carries. */
	private static inline final SINGULAR_Y: String = 'y';

	/** The ending a sibilant singular takes in the plural. */
	private static inline final PLURAL_ES: String = 'es';

	/** The ending every other plural takes. */
	private static inline final PLURAL_S: String = 's';

	/** Endings that take `es` rather than a bare `s`, so the singular drops both characters. */
	private static final SIBILANT_PLURALS: Array<String> = ['ses', 'xes', 'zes', 'ches', 'shes'];

	/** Endings that make a word LOOK plural while it is not — `class`, `status`, `axis`. */
	private static final SINGULAR_ENDINGS: Array<String> = ['ss', 'us', 'is'];

	/** A collection name the singularizer will touch: lower camelCase, so a derived binder is one too. */
	private static final COLLECTION_NAME_PATTERN: EReg = ~/^[a-z][A-Za-z0-9_]*$/;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'an indexed for whose index only reads X[i], replaceable with for (v in X)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final typed: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		return RunScan.collectWith(files, plugin, LoopScan.intervalSeamsOf(plugin.refShape()), (entry, tree, s, violations) -> {
			walk(tree, fileScanOf(tree, entry.source, typed?.declaredTypeSources(entry.source), plugin, s), entry.file, violations);
		});
	}

	/**
	 * Rewrite each flagged loop into `for (v in X)`: one splice over the header through the end
	 * of the range, plus one per `X[i]` occurrence. The closing paren and the body are outside
	 * every span, so a braced and an unbraced body take the same edits.
	 */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return RunScan.walkedEdits(
			plugin, source, LoopScan.intervalSeamsOf(plugin.refShape()), violations,
			(tree, types, s, wanted, out) -> fixWalk(tree, fileScanOf(tree, source, types, plugin, s), wanted, out)
		);
	}

	/** Descend `node`, testing it as a loop and recursing; a reification subtree is skipped wholesale. */
	private static function walk(node: QueryNode, f: FileScan, file: String, out: Array<Violation>): Void {
		if (f.seams.core.opaqueKinds.contains(node.kind)) return;
		final m: Null<Match> = analyze(node, f);
		if (m != null) out.push({
			file: file,
			span: m.forSpan,
			rule: RULE_ID,
			severity: Severity.Info,
			message: adviceFor(m)
		});
		for (c in node.children) walk(c, f, file, out);
	}

	/**
	 * The finding's text. Two spellings, because one of them has to be honest about there being
	 * no name to write: a collection whose singular this check cannot derive still has a value
	 * loop in it, and naming the binder is then the reader's job.
	 */
	private static function adviceFor(m: Match): String {
		final binder: Null<String> = m.binder;
		return binder == null
			? 'this indexed loop reads only ${m.collection}[${m.index}]; it can be a value loop over ${m.collection}'
			: 'this indexed loop can be for ($binder in ${m.collection})';
	}

	/** Mirror of `walk` for the fix path: emit the splices for each wanted, rewritable loop. */
	private static function fixWalk(node: QueryNode, f: FileScan, wanted: Array<String>, out: Array<FixEdit>): Void {
		if (f.seams.core.opaqueKinds.contains(node.kind)) return;
		final m: Null<Match> = analyze(node, f);
		if (m != null && wanted.contains('${m.forSpan.from}:${m.forSpan.to}')) for (e in buildEdits(m, f.source)) out.push(e);
		for (c in node.children) fixWalk(c, f, wanted, out);
	}

	/**
	 * The matched loop — the spans the rewrite splices, the two names it reads and the binder it
	 * would write — or null when any gate fails. Shared by `walk` (report) and `fixWalk` (rewrite)
	 * so both see one decision.
	 *
	 * The gates are layered on purpose: the node walks answer precisely about the shapes the tree
	 * projects, and the text scan answers completely about the ones it hides.
	 */
	private static function analyze(forNode: QueryNode, f: FileScan): Null<Match> {
		final core: LoopSeams = f.seams.core;
		final h: Null<IndexedLoopHeader> = LoopScan.indexedHeaderOf(forNode, f.source, LENGTH_MEMBER, f.seams);
		if (h == null) return null;
		final reads: Array<QueryNode> = LoopScan.collectIndexReads(h.body, h.collection, h.index, core);
		if (reads.length == 0 || LoopScan.countReads(h.body, h.index, core) != reads.length) return null;
		if (claimedByKeyValueLoop(h.body, h.collection, h.index, reads.length, core)) return null;
		if (!LoopScan.usedOnlyAsStableCollection(h.body, h.collection, LENGTH_MEMBER, core)) return null;
		if (LoopScan.bindsName(h.body, h.index, core) || LoopScan.bindsName(h.body, h.collection, core)) return null;
		final forSpan: Null<Span> = forNode.span;
		final iterableSpan: Null<Span> = h.iterable.span;
		final bodySpan: Null<Span> = h.body.span;
		if (forSpan == null || iterableSpan == null || bodySpan == null) return null;
		final readSpans: Array<Span> = [];
		final indexSpans: Array<Span> = [];
		for (r in reads) {
			final span: Null<Span> = r.span;
			final indexSpan: Null<Span> = r.children[1].span;
			if (span == null || indexSpan == null) return null;
			readSpans.push(span);
			indexSpans.push(indexSpan);
		}
		// The COMPLETENESS gate, and the one the walks above cannot be: they prune an `opaqueKinds`
		// subtree, so a `macro` quotation answers "the index is absent" when the honest answer is
		// "unknown". Here a missed mention is a licence to DELETE the index, the unsafe direction, so
		// the proof is a TEXT scan over the body with the occurrences this rewrite itself re-spells
		// excluded. `f.inert` keeps a comment and a non-interpolating literal from counting as a use;
		// a literal that CAN interpolate stays visible, because its bytes can be a real read.
		if (OccurrenceScan.referencedInRange(f.source, h.index, bodySpan.from, bodySpan.to, indexSpans, f.inert)) return null;
		final collectionTypeSource: Null<String> = LoopScan.identTypeSource(h.sizeReceiver, f.root, f.types, core);
		// A container that RESOLVES to something else has no value iteration to offer — `String`
		// is the one that stings, since it carries a `length` — so the message would be advice
		// that does not compile; only an UNRESOLVED one keeps the report-only tolerance.
		return collectionTypeSource != null && NominalTypes.outerNominalOf(collectionTypeSource) != ARRAY_TYPE ? null : {
			forSpan: forSpan,
			iterableSpan: iterableSpan,
			index: h.index,
			collection: h.collection,
			binder: binderFor(f, bodySpan, h.index, h.collection),
			readSpans: readSpans,
			resolved: collectionTypeSource != null
		};
	}

	/**
	 * Whether `prefer-keyvalue-loop` claims this loop, spelled here so no loop is reported by both
	 * rules and the two autofixes cannot race. It has to be that rule's claim ENTIRE, not just its
	 * opening `final v = X[i];`: a braced body of at least two statements holding exactly one `X[i]`.
	 * Deferring on the opening alone left every loop the sibling declines for one of its own gates
	 * reported by NOBODY.
	 *
	 * The cost, stated rather than hidden: with `prefer-keyvalue-loop` disabled, a loop of exactly that
	 * shape is reported by neither rule. A near miss stays here — a multi-declarator opener
	 * (`var v = X[i], w = 2;`) and an unbraced one are outside the sibling's claim, so this rule keeps
	 * them.
	 */
	private static function claimedByKeyValueLoop(
		body: QueryNode, collection: String, index: String, indexReads: Int, core: LoopSeams
	): Bool {
		if (body.kind != core.blockStmtKind || body.children.length < MIN_KEY_VALUE_STATEMENTS) return false;
		if (indexReads != CONSUMED_INDEX_READS) return false;
		final decl: QueryNode = body.children[0];
		if (LoopScan.singleLocalDeclName(decl, core.localDeclKinds, core) == null) return false;
		final init: QueryNode = decl.children[0];
		return LoopScan.isIndexAccessOf(init, collection, core) && LoopScan.bareIdentName(init.children[1], core) == index;
	}

	/**
	 * The name the value binder would take, or null when this check will not write one. A candidate the
	 * body spells ANYWHERE in ACTIVE text is refused — the same masked TEXT scan `analyze` uses, because
	 * a name that occurs only in a `macro` quotation is just as capturable as one in plain code.
	 * Shadowing an OUTER name the body never mentions is safe by contrast: the binder's scope ends with
	 * the loop.
	 *
	 * The mask carries its weight on this half especially: a comment naming the singular is ordinary in a
	 * loop body, and a comment cannot capture a binding.
	 *
	 * `candidate == collection` is not tested: every `singularOf` answer is strictly shorter than its
	 * input.
	 */
	private static function binderFor(f: FileScan, bodySpan: Span, index: String, collection: String): Null<String> {
		final candidate: Null<String> = singularOf(collection);
		return if (candidate == null || candidate == index)
			null
		else if ((f.seams.core.shape.reservedWords ?? []).contains(candidate))
			null
		else if (OccurrenceScan.referencedInRange(f.source, candidate, bodySpan.from, bodySpan.to, [], f.inert))
			null
		else
			candidate;
	}

	/**
	 * The singular of a plural collection name, or null when no rule applies. An English
	 * identifier convention, so it lives here rather than in the grammar seam: a plural is a
	 * property of how people name collections, not of the language being parsed.
	 */
	private static function singularOf(name: String): Null<String> {
		if (!COLLECTION_NAME_PATTERN.match(name)) return null;
		if (name.endsWith(PLURAL_IES)) {
			// A `…y` singular pluralises through a consonant (`property`, `body`); a stem already
			// ending in a vowel had an `…ie` singular, which loses only the `s`.
			final stem: String = name.substring(0, name.length - PLURAL_IES.length);
			return if (stem.length == 0)
				null
			else if (VOWELS.indexOf(stem.charAt(stem.length - 1)) >= 0)
				name.substring(0, name.length - PLURAL_S.length)
			else
				stem + SINGULAR_Y;
		}
		for (suffix in SIBILANT_PLURALS) if (name.endsWith(suffix)) return name.substring(0, name.length - PLURAL_ES.length);
		for (suffix in SINGULAR_ENDINGS) if (name.endsWith(suffix)) return null;
		if (!name.endsWith(PLURAL_S)) return null;
		final stem: String = name.substring(0, name.length - PLURAL_S.length);
		return stem.length == 0 ? null : stem;
	}

	/**
	 * The splices that turn `m` into a value loop — the header through the end of the range, then
	 * one per `X[i]` — or an empty list when the rewrite is refused: no binder name, an
	 * unresolved container, or a comment inside a region a splice would overwrite.
	 */
	private static function buildEdits(m: Match, source: String): Array<FixEdit> {
		final maybeBinder: Null<String> = m.binder;
		if (maybeBinder == null || !m.resolved) return [];
		if (CheckScan.hasCommentMarker(source, m.forSpan.from, m.iterableSpan.to)) return [];
		for (span in m.readSpans) if (CheckScan.hasCommentMarker(source, span.from, span.to)) return [];
		final binder: String = maybeBinder;
		final edits: Array<FixEdit> = [
			{ span: new Span(m.forSpan.from, m.iterableSpan.to), text: 'for ($binder in ${m.collection}' }
		];
		for (span in m.readSpans) edits.push({ span: span, text: binder });
		return edits;
	}

	/** Bundle the per-FILE facts every gate reads, so the walks carry one argument instead of five. */
	private static function fileScanOf(
		tree: QueryNode, source: String, types: Null<Map<Int, String>>, plugin: GrammarPlugin, seams: IntervalLoopSeams
	): FileScan {
		return {
			root: tree,
			source: source,
			types: types,
			inert: OccurrenceScan.inertMask(source, plugin),
			seams: seams
		};
	}

}

/**
 * The per-FILE facts every gate reads: the tree root a type lookup resolves against, the source
 * and its inert-region mask (comments, regexes and non-interpolating literals — the spans a text
 * scan must not read as a use), the declared-type map, and the seams.
 */
private typedef FileScan = {
	var root: QueryNode;
	var source: String;
	var types: Null<Map<Int, String>>;
	var inert: Array<Span>;
	var seams: IntervalLoopSeams;
}

/** One matched loop: the spans the rewrite splices, the names it reads, the binder it would write. */
private typedef Match = {
	var forSpan: Span;
	var iterableSpan: Span;
	var index: String;
	var collection: String;
	var binder: Null<String>;
	var readSpans: Array<Span>;
	var resolved: Bool;
}
