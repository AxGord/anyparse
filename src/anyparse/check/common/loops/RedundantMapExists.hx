package anyparse.check.common.loops;

import anyparse.check.Check.DefaultOff;
import anyparse.check.common.control.BranchChain;
import anyparse.check.common.loops.MapValueScan.ValueSeams;
import anyparse.query.CanonicalEdit;
import anyparse.query.ElementSpan;
import anyparse.query.LexicalRegions;
import anyparse.query.MemberKinds;
import anyparse.query.OccurrenceScan;
import anyparse.query.ParenGuard;
import anyparse.query.ShapeVocab;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.query.TypeSyntax;

using anyparse.util.Strings;

/**
 * The structural half of a match — the nodes, before any type or comment gate.
 */
private typedef Shape = {
	final recv: QueryNode;
	final read: QueryNode;
	final fallback: QueryNode;
	final name: String;
}

/**
 * One matched `m.exists(k) ? m[k] : d` site and the verbatim parts its rewrite keeps.
 */
private typedef Match = {
	final span: Span;
	final name: String;
	final bindingFrom: Int;
	final readSource: String;
	final fallbackSource: String;
};

/** The `m.exists(k)` membership test both forms open with: the receiver, the key and the map's name. */
private typedef ExistsTest = { final recv: QueryNode; final key: QueryNode; final name: String; };

/**
 * One matched `if (m.exists(k)) … m[k] …` statement: the rewrite that reads the map once into a local and tests it
 * against null, or — when none can be written — the reason, which the finding carries as its decline.
 */
private typedef StatementMatch = {
	final span: Span;
	final name: String;
	final bindingFrom: Int;
	final rewrite: Null<String>;
	final refusal: Null<String>;
};

/** What one file's walk reads: its text, comment regions, tree and declared types. */
private typedef FileScan = {
	final source: String;
	final regions: () -> Array<LexRegion>;
	final root: QueryNode;
	final declaredTypes: Map<Int, String>;
	final declaredTypeSources: Map<Int, String>;
};

/** Per-run resolved seams + type provider. */
private typedef Cfg = {

	final shape: RefShape;
	final typed: TypeInfoProvider;
	final ternaryKind: String;
	final callKind: String;
	final fieldAccessKind: String;
	final indexAccessKind: String;
	final identKind: String;
	final existsMethods: Array<String>;
	final mapTypes: Array<String>;
	final nullableWrappers: Array<String>;

	/** `GrammarPlugin.typeSyntax` — how a receiver's written type is read. */
	final typeSyntax: TypeSyntaxReader;
	final opaqueKinds: Array<String>;
	final mutationKinds: Array<String>;

	/** The statement form's seams; empty when the grammar lacks one, which disables only that form. */
	final ifStatementKinds: Array<String>;
	final blockKinds: Array<String>;
	final writeParentKinds: Array<String>;
	final reservedWords: Array<String>;

	/** A declaration the new local is scoped to: a name spelled anywhere in one is taken. */
	final functionKinds: Array<String>;

	/** A body that runs later than, or again after, the code around it, so a read inside one may see a later write. */
	final deferredKinds: Array<String>;

};

/**
 * Flags a map lookup spelled as a membership test followed by an index read, which does two hash lookups where one
 * answers. `Severity.Info`, DEFAULT OFF, with an autofix that fires only where a stored null value is PROVEN impossible.
 * Two forms:
 *
 * - the ternary `m.exists(k) ? m[k] : d`, rewritten to `m[k] ?? d`;
 * - the statement `if (m.exists(k)) <then>` standing in a block, whose then-branch reads `m[k]`, rewritten to a local
 *   read once before it and tested instead: `final v: Null<V> = m[k]; if (v != null) <then>`, each read of the
 *   then-branch re-spelled `v` and an `else` kept as written.
 *
 * ## The null-value gate is real, not theoretical
 *
 * Both rewrites diverge from the original on exactly one input: a key PRESENT in the map whose stored VALUE is null.
 * So each is a behaviour change unless no null value can ever be in the map, and that proof — an occurrence census over
 * the whole resolution scope — is `MapValueScan`'s job. Where it fails the site is still reported, with a message and a
 * decline saying so, and carries no fix; a memo that stores null on purpose (`Map<K, Null<V>>`) is such a site.
 *
 * ## Why the shape is narrow
 *
 * The receiver must be a BARE IDENTIFIER whose declared type resolves to the grammar's Map abstract: a missing key reading
 * as `null` is that abstract's contract, and the census needs one name to enumerate. Receivers and keys must be textually
 * identical and the key pure, and a comment in a region either rewrite drops or re-spells refuses the site. The statement
 * form also needs a then-branch that reaches the map ONLY through those reads, none of them a write's target or inside a
 * closure, with no write or call running before the last one (`thenReads`); the local is named after the map's singular
 * (`ElementLoopRewrite.elementNameOf`), else after the key, and a name already spelled in the enclosing declaration
 * refuses the fix. Nested matches are flagged outermost-first; an inner one is caught on the next `--fix` pass.
 *
 * ## Whole-project scope required
 *
 * The census is only sound when it can see every file that references the map — the contract `prefer-final-field`
 * documents — so the check is registered among the `--fix` loop's full-scope ids.
 *
 * ## Grammar-agnostic
 *
 * Driven by `RefShape` seams (`ternaryKind`, `callKind`, `fieldAccessKind`, `indexAccessKind`, `identKind`,
 * `mapExistsMethods`, `mapAbstractTypeNames`, and for the statement form `ifStatementKinds` and the block kinds; any unset
 * disables what needs it) and by `MapValueScan.seamsOf` for the proof. Type resolution requires
 * `plugin is TypeInfoProvider`. The sister forms left out, and why: docs/guide/lint/loops.md.
 */
@:nullSafety(Strict)
final class RedundantMapExists extends RuleBase implements DefaultOff {

	/** The rule id, and the `--rule` selector that force-enables this default-off check. */
	private static inline final RULE_ID: String = 'redundant-map-exists';

	/** `m.exists(k)` is a call with [callee, key]. */
	private static inline final EXISTS_CALL_CHILDREN: Int = 2;

	/** `m[k]` is an index access with [receiver, key]. */
	private static inline final INDEX_CHILD_COUNT: Int = 2;

	/** The message for a site whose no-null-value proof cleared — the one that gets a fix. */
	private static final FIXABLE_MESSAGE: String = 'this exists-then-index map lookup can be map[key] ?? default';

	/** The message for a site the census could not prove; reported for a human, never fixed. */
	private static final UNPROVEN_MESSAGE: String =
		'this exists-then-index map lookup reads like map[key] ?? default, but a stored null value cannot be ruled out';

	/** Why an unproven site gets no edit, for `apq lint --fix`'s unfixed ledger — the same fact the message states. */
	private static final DECLINE_REASON: String =
		'the value census could not rule out a stored null, so map[key] ?? default would change the result for that key';

	/** The statement form's message where the proof cleared. */
	private static final FIXABLE_STATEMENT_MESSAGE: String =
		'this exists-then-index map lookup can read the map once into a local and test the local against null';

	/** The statement form's message where the census could not prove the map free of stored nulls. */
	private static final UNPROVEN_STATEMENT_MESSAGE: String =
		'this exists-then-index map lookup reads like a once-read local tested against null, but a stored null value cannot be ruled out';

	/** Why an unproven statement gets no edit. */
	private static final STATEMENT_DECLINE_REASON: String =
		'the value census could not rule out a stored null, so testing the once-read local against null would skip the branch for that key';

	/** The local's name when the map's name has no singular: the key's name with this suffix. */
	private static final KEY_VALUE_SUFFIX: String = 'Value';

	/** Why a statement whose map declaration writes no `Map<K, V>` gets no edit: the local could not be typed. */
	private static final UNTYPED_REFUSAL: String = 'the map\'s declaration writes no value type, so the once-read local cannot be typed';

	public function new() {
		super(
			RULE_ID,
			'a map exists-then-index lookup — the ternary m.exists(k) ? m[k] : d (-> m[k] ?? d) or the statement '
			+ 'if (m.exists(k)) … m[k] … (-> a once-read local tested against null)',
			RuleCategory.Loops
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final cfg: Null<Cfg> = config(plugin);
		if (cfg == null) return [];
		final valueSeams: Null<ValueSeams> = MapValueScan.seamsOf(cfg.shape);
		// The REPORT index deliberately, not `lazySymbolIndex` (which prefers the resolution
		// one): `MapValueScan` reads its `skippedFiles` as the "nothing is hidden from the
		// scan" proof, and on any project with libraries configured the resolution index's
		// skipped set is permanently non-empty — which silently refused every site. The
		// subtype and access-grant lookups inside the census resolve their own wider scope.
		var reportIndex: Null<SymbolIndex> = null;
		final resolveSymbols: () -> SymbolIndex = () -> {
			final built: SymbolIndex = reportIndex ?? IndexScope.report(files, plugin);
			reportIndex = built;
			return built;
		};
		final proven: Map<String, Bool> = [];
		return RunScan.collect(files, plugin, (entry, root, violations) -> {
			final f: FileScan = fileScan(entry.source, root, ElementSpan.lazyRegions(entry.source, plugin), cfg);
			final proofOf: (
				String, Int
			) -> Bool = (name, bindingFrom) ->
				isProven(name, bindingFrom, entry.file, entry.source, root, valueSeams, resolveSymbols(), plugin, proven);
			collect(root, null, root, f, cfg, m -> {
				final proof: Bool = proofOf(m.name, m.bindingFrom);
				violations.push({
					file: entry.file,
					span: m.span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: proof ? FIXABLE_MESSAGE : UNPROVEN_MESSAGE,
					// The failed proof IS the decline — carried onto the finding so `apq lint --fix`'s
					// ledger reads this check's own sentence rather than reporting that it declared none.
					declineReason: proof ? null : DECLINE_REASON
				});
			}, s -> {
				final proof: Bool = proofOf(s.name, s.bindingFrom);
				violations.push({
					file: entry.file,
					span: s.span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: proof ? FIXABLE_STATEMENT_MESSAGE : UNPROVEN_STATEMENT_MESSAGE,
					declineReason: proof ? s.refusal : STATEMENT_DECLINE_REASON
				});
			});
		});
	}

	/**
	 * Rewrite each PROVEN site to `<index read> ?? <default>`. The proof is re-derived here
	 * rather than carried over from `run`: a check's `fix` is handed one file's source and
	 * its own violations, and the census reads the whole resolution scope, so the answer
	 * cannot travel in a `Violation`. An unproven site simply yields no edit.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final cfg: Null<Cfg> = config(plugin);
		if (cfg == null) return [];
		final c: Cfg = cfg;
		// The REPORT index, exactly as in `run`: the census reads its `skippedFiles` as the
		// "nothing is hidden" proof and derives its own wider scope for the subtype and
		// access-grant lookups. Handing it the RESOLUTION index instead makes that gate
		// permanently false on any project with libraries configured, and every edit vanishes
		// while the report still says the site is fixable.
		if (index == null) return [];
		final report: SymbolIndex = index;
		return RunScan.editsWith(plugin, source, MapValueScan.seamsOf(c.shape), (tree, valueSeams) -> {
			final f: FileScan = fileScan(source, tree, ElementSpan.lazyRegions(source, plugin), c);
			final proven: Map<String, Bool> = [];
			final file: String = violations.length > 0 ? violations[0].file : '';
			final proofOf: (
				String, Int
			) -> Bool = (name, bindingFrom) -> isProven(name, bindingFrom, file, source, tree, valueSeams, report, plugin, proven);
			final guarded: Array<GuardedEdit> = [];
			final plain: Array<{ span: Span, text: String }> = CheckScan.applyBySpan(
				plugin, source, violations, [c.ternaryKind], (node, span) -> {
					final m: Null<Match> = match(node, f, c);
					if (m == null || !proofOf(m.name, m.bindingFrom)) return null;
					final edit: GuardedEdit = ParenGuard.binaryEdit(span, m.readSource, '??', m.fallbackSource);
					guarded.push(edit);
					return edit;
				}
			);
			// `plain` and `guarded` hold the same edits in the same order, so a containment index of one is the other's.
			return ParenGuard.guard(
				source, [ for (i in 0...guarded.length) if (!CanonicalEdit.isContainedEdit(plain, i)) guarded[i] ], plugin
			)
				.concat(statementEdits(violations, f, c, proofOf));
		});
	}

	/**
	 * The cached no-null-value verdict for the map `name` binds at `bindingFrom`, false when no proof is
	 * available at all. Keyed on the BINDING, not the name: the census is owner-scoped, so
	 * two same-named maps in different types get their own verdicts.
	 */
	private static function isProven(
		name: String, bindingFrom: Int, file: String, source: String, root: QueryNode, seams: Null<ValueSeams>, index: Null<SymbolIndex>,
		plugin: GrammarPlugin, cache: Map<String, Bool>
	): Bool {
		if (seams == null) return false;
		final key: String = '$file:$bindingFrom';
		final cached: Null<Bool> = cache[key];
		if (cached != null) return cached;
		final verdict: Bool = MapValueScan.proven(name, bindingFrom, source, root, index, plugin, seams);
		cache[key] = verdict;
		return verdict;
	}

	/**
	 * Walk `node`, handing `sink` each OUTERMOST matching ternary and `statementSink` each outermost matching statement
	 * of a block — a nested match inside one would yield an overlapping edit, and is caught on the next `--fix` pass once the
	 * outer rewrite has re-parsed. `scope` is the innermost enclosing declaration of `functionKinds`, else the root.
	 */
	private static function collect(
		node: QueryNode, parent: Null<QueryNode>, scope: QueryNode, f: FileScan, cfg: Cfg, sink: Match -> Void,
		statementSink: StatementMatch -> Void
	): Void {
		if (cfg.opaqueKinds.contains(node.kind)) return;
		if (node.kind == cfg.ternaryKind) {
			final m: Null<Match> = match(node, f, cfg);
			if (m != null) {
				sink(m);
				return;
			}
		}
		if (parent != null && cfg.ifStatementKinds.contains(node.kind) && cfg.blockKinds.contains(parent.kind)) {
			final s: Null<StatementMatch> = statementMatch(node, scope, f, cfg);
			if (s != null) {
				statementSink(s);
				return;
			}
		}
		final inner: QueryNode = cfg.functionKinds.contains(node.kind) ? node : scope;
		for (c in node.children) collect(c, node, inner, f, cfg, sink, statementSink);
	}

	/**
	 * If `ternary` is `m.exists(k) ? m[k] : d` on a bare Map-typed identifier with a pure key
	 * and no comment in either dropped region, return the rewrite's parts; else null.
	 */
	private static function match(ternary: QueryNode, f: FileScan, cfg: Cfg): Null<Match> {
		final source: String = f.source;
		final regions: () -> Array<LexRegion> = f.regions;
		final shape: Null<Shape> = structuralShape(ternary, source, cfg);
		if (shape == null) return null;
		final recv: QueryNode = shape.recv;
		final read: QueryNode = shape.read;
		final fallback: QueryNode = shape.fallback;
		final name: String = shape.name;
		final bindingFrom: Null<Int> = mapBindingOf(recv, f, cfg);
		if (bindingFrom == null) return null;
		final ternarySpan: Null<Span> = ternary.span;
		final readSpan: Null<Span> = read.span;
		final fallbackSpan: Null<Span> = fallback.span;
		if (ternarySpan == null || readSpan == null || fallbackSpan == null) return null;
		// The rewrite keeps the index read and the default verbatim and drops everything
		// between them; a comment in either dropped region would be deleted with it.
		if (
			LexicalRegions.commentIntersects(ternarySpan.from, readSpan.from, regions())
			|| LexicalRegions.commentIntersects(readSpan.to, fallbackSpan.from, regions())
		)
			return null;
		final fallbackSource: String = source.substring(fallbackSpan.from, fallbackSpan.to);
		return {
			span: ternarySpan,
			name: name,
			bindingFrom: bindingFrom,
			readSource: source.substring(readSpan.from, readSpan.to),
			fallbackSource: fallbackSource
		};
	}

	/**
	 * The `m.exists(k) ? m[k] : d` shape of `ternary`, with the two `m` and the two `k`
	 * occurrences proven textually identical and the key proven pure — or null. The TYPE gate and
	 * the comment gate belong to `match`, which layers them on top; this half needs no resolution.
	 */
	private static function structuralShape(ternary: QueryNode, source: String, cfg: Cfg): Null<Shape> {
		if (!BranchChain.hasElse(ternary)) return null;
		final test: Null<ExistsTest> = existsTest(BranchChain.condOf(ternary), cfg);
		if (test == null) return null;
		final read: QueryNode = BranchChain.thenOf(ternary);
		return isRead(read, test, source, cfg) ? {
			recv: test.recv,
			read: read,
			fallback: BranchChain.elseBranch(ternary),
			name: test.name
		} : null;
	}

	/**
	 * The `m.exists(k)` test `cond` spells on a bare identifier with a pure key — or null. `m` and `k` are evaluated
	 * once by the test and once by every read, and once after either rewrite, so an impure key means the original is
	 * already order-dependent; the rule fails closed there.
	 */
	private static function existsTest(cond: QueryNode, cfg: Cfg): Null<ExistsTest> {
		if (cond.kind != cfg.callKind || cond.children.length != EXISTS_CALL_CHILDREN) return null;
		final callee: QueryNode = cond.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != cfg.fieldAccessKind || method == null || !cfg.existsMethods.contains(method) || callee.children.length != 1)
			return null;
		final recv: QueryNode = callee.children[0];
		final name: Null<String> = recv.name;
		if (recv.kind != cfg.identKind || name == null) return null;
		final key: QueryNode = cond.children[1];
		for (k in cfg.mutationKinds) if (MemberKinds.subtreeContainsKind(key, k)) return null;
		return { recv: recv, key: key, name: name };
	}

	/** Whether `node` is the index read `m[k]` of `test`'s receiver and key, both textually identical. */
	private static function isRead(node: QueryNode, test: ExistsTest, source: String, cfg: Cfg): Bool {
		return node.kind == cfg.indexAccessKind && node.children.length == INDEX_CHILD_COUNT
			&& MemberKinds.sameSource(test.recv, node.children[0], source)
			&& MemberKinds.sameSource(test.key, node.children[1], source);
	}

	/**
	 * If `stmt` is `if (m.exists(k)) <then>` on a bare Map-typed identifier whose then-branch reads `m[k]` and reaches
	 * `m` no other way (`thenReads`), and no comment sits in a span the rewrite re-spells, the once-read rewrite or why
	 * none is written; else null. `scope` is the declaration the new local lands in, the region its name must be free in.
	 */
	private static function statementMatch(stmt: QueryNode, scope: QueryNode, f: FileScan, cfg: Cfg): Null<StatementMatch> {
		if (!BranchChain.hasThen(stmt)) return null;
		final cond: QueryNode = BranchChain.condOf(stmt);
		final test: Null<ExistsTest> = existsTest(cond, cfg);
		if (test == null) return null;
		final reads: Null<Array<QueryNode>> = thenReads(BranchChain.thenOf(stmt), test, f.source, cfg);
		if (reads == null) return null;
		final bindingFrom: Null<Int> = mapBindingOf(test.recv, f, cfg);
		final span: Null<Span> = stmt.span;
		if (bindingFrom == null || span == null) return null;
		final spans: Array<Span> = [];
		for (n in [cond].concat(reads)) {
			final at: Null<Span> = n.span;
			if (at == null || LexicalRegions.commentIntersects(at.from, at.to, f.regions())) return null;
			spans.push(at);
		}
		final local: Null<String> = localName(test, cfg);
		final type: Null<String> = localType(f.declaredTypeSources[bindingFrom], cfg);
		final refusal: Null<String> = nameRefusal(local, test, scope, f, cfg) ?? (type == null ? UNTYPED_REFUSAL : null);
		return {
			span: span,
			name: test.name,
			bindingFrom: bindingFrom,
			rewrite: refusal == null && local != null && type != null ? rewriteOf(span, spans, local, type, f.source) : null,
			refusal: refusal
		};
	}

	/**
	 * Every `m[k]` read of `then` in document order, when there is one and `then` reaches the map no other way: no other
	 * occurrence of its name, no read that is a write's target or sits in a body that runs later or again (a closure, a loop —
	 * code textually after the read runs before its next turn), and no write or call that runs before the last read; each could
	 * change what a later read answers. Null otherwise. A syntactic gate on purpose: it fails closed, and also covers a
	 * reassigned key, which a reach question about the map (`MemberReach.mayMutateNamed`) does not.
	 */
	private static function thenReads(then: QueryNode, test: ExistsTest, source: String, cfg: Cfg): Null<Array<QueryNode>> {
		final reads: Array<QueryNode> = [];
		if (!gatherReads(then, null, false, test, source, cfg, reads) || reads.length == 0) return null;
		final last: Null<Span> = reads[reads.length - 1].span;
		return last == null || runsBefore(then, last, cfg) ? null : reads;
	}

	/** Push each read under `node` onto `out`; false at the first occurrence of the map `thenReads` refuses. */
	private static function gatherReads(
		node: QueryNode, parent: Null<QueryNode>, deferred: Bool, test: ExistsTest, source: String, cfg: Cfg, out: Array<QueryNode>
	): Bool {
		if (cfg.opaqueKinds.contains(node.kind)) return false;
		if (isRead(node, test, source, cfg)) {
			if (deferred || (parent != null && cfg.writeParentKinds.contains(parent.kind) && parent.children[0] == node)) return false;
			out.push(node);
			return true;
		}
		if (node.name == test.name) return false;
		final inner: Bool = deferred || cfg.deferredKinds.contains(node.kind);
		return node.children.foreach(c -> gatherReads(c, node, inner, test, source, cfg, out));
	}

	/** Whether a write or a call inside `node` ends before `last` starts — code that runs before that read. */
	private static function runsBefore(node: QueryNode, last: Span, cfg: Cfg): Bool {
		final at: Null<Span> = node.span;
		if (at == null || at.from >= last.from) return false;
		return (cfg.mutationKinds.contains(node.kind) && at.to <= last.from) || node.children.exists(c -> runsBefore(c, last, cfg));
	}

	/** The local's name: the map's name singularized (`ElementLoopRewrite.elementNameOf`), else the key's name with a suffix. */
	private static function localName(test: ExistsTest, cfg: Cfg): Null<String> {
		final singular: Null<String> = ElementLoopRewrite.elementNameOf(test.name);
		if (singular != null) return singular;
		final key: Null<String> = test.key.name;
		return test.key.kind == cfg.identKind && key != null ? key + KEY_VALUE_SUFFIX : null;
	}

	/**
	 * Why `local` cannot be declared in `scope`, or null. A name spelled anywhere in active text of the declaration is
	 * taken: a binding of it would be shadowed, or a later read of it captured.
	 */
	private static function nameRefusal(local: Null<String>, test: ExistsTest, scope: QueryNode, f: FileScan, cfg: Cfg): Null<String> {
		if (local == null) return 'no local name derives from `${test.name}`, and its key is not a bare name';
		if (cfg.reservedWords.contains(local)) return 'the local name `$local` is a reserved word';
		final at: Null<Span> = scope.span;
		final taken: Bool = at == null
			|| OccurrenceScan.referencedInRange(f.source, local, at.from, at.to, [], OccurrenceScan.inertRegions(f.source, f.regions()));
		return taken ? 'the local name `$local` is already spelled in the enclosing declaration' : null;
	}

	/**
	 * The local's written type: the map's value type from its declared `Map<K, V>` (through a nullable wrapper), itself when
	 * already nullable, else wrapped in the grammar's nullable wrapper — or null when the declaration writes no such type.
	 */
	private static function localType(declared: Null<String>, cfg: Cfg): Null<String> {
		if (declared == null || cfg.nullableWrappers.length == 0) return null;
		final written: Null<TypeSyntax> = cfg.typeSyntax(declared);
		if (written == null) return null;
		final map: TypeSyntax = written.wrapped(cfg.nullableWrappers) ?? written;
		return switch map.shape {
			case Nominal(path, [_, value]) if (cfg.mapTypes.contains(SourceText.lastSegment(path))):
				value.wrapped(cfg.nullableWrappers) != null ? value.text : '${cfg.nullableWrappers[0]}<${value.text}>';
			case _: null;
		};
	}

	/**
	 * The statement at `span` with its test (`spans[0]`) re-spelled `local != null` and each read (the rest) re-spelled
	 * `local`, after a declaration that reads the map once — on its own line at the statement's indent, or before it on a
	 * shared line.
	 */
	private static function rewriteOf(whole: Span, spans: Array<Span>, local: String, type: String, source: String): String {
		final lead: String = source.substring(source.lineStart(whole.from), whole.from);
		final first: Span = spans[1];
		var out: String = 'final $local: $type = ${source.substring(first.from, first.to)};${lead.isBlank() ? '\n$lead' : ' '}';
		var at: Int = whole.from;
		for (i => piece in spans) {
			out += source.substring(at, piece.from) + (i == 0 ? '$local != null' : local);
			at = piece.to;
		}
		return out + source.substring(at, whole.to);
	}

	/**
	 * The once-read rewrite of each reported statement whose proof clears. The statements are found again by the walk `run`
	 * takes, since `fix` is handed spans, not matches.
	 */
	private static function statementEdits(
		violations: Array<Violation>, f: FileScan, cfg: Cfg, proofOf: (String, Int) -> Bool
	): Array<{ span: Span, text: String }> {
		final reported: Map<String, Bool> = [ for (v in violations) '${v.span?.from}:${v.span?.to}' => true ];
		final out: Array<{ span: Span, text: String }> = [];
		collect(f.root, null, f.root, f, cfg, _ -> {}, s -> {
			final rewrite: Null<String> = s.rewrite;
			if (rewrite != null && reported.exists('${s.span.from}:${s.span.to}') && proofOf(s.name, s.bindingFrom))
				out.push({ span: s.span, text: rewrite });
		});
		return out;
	}

	/** One file's walk inputs, its declared types read once. */
	private static function fileScan(source: String, root: QueryNode, regions: () -> Array<LexRegion>, cfg: Cfg): FileScan {
		return {
			source: source,
			regions: regions,
			root: root,
			declaredTypes: cfg.typed.declaredTypes(source),
			declaredTypeSources: cfg.typed.declaredTypeSources(source)
		};
	}

	private static function mapBindingOf(recv: QueryNode, f: FileScan, cfg: Cfg): Null<Int> {
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(recv, f.root, cfg.shape);
		if (bindingFrom == null) return null;
		final typeName: Null<String> = f.declaredTypes[bindingFrom];
		return typeName != null
			&& MapNominal.isMap(typeName, f.declaredTypeSources[bindingFrom], cfg.mapTypes, cfg.nullableWrappers, cfg.typeSyntax)
			? bindingFrom
			: null;
	}

	/** Resolve the per-grammar seams + type provider, or null when the grammar lacks a needed kind / type info. */
	private static function config(plugin: GrammarPlugin): Null<Cfg> {
		final shape: RefShape = plugin.refShape();
		final ternaryKind: Null<String> = shape.ternaryKind;
		if (ternaryKind == null) return null;
		final callKind: Null<String> = shape.callKind;
		if (callKind == null) return null;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null) return null;
		final indexAccessKind: Null<String> = shape.indexAccessKind;
		if (indexAccessKind == null) return null;
		final existsMethods: Array<String> = shape.mapExistsMethods ?? [];
		final mapTypes: Array<String> = shape.mapAbstractTypeNames ?? [];
		if (existsMethods.length == 0 || mapTypes.length == 0) return null;
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final functionKinds: Array<String> = shape.functionKinds ?? [];
		return provider == null ? null : {
			shape: shape,
			typed: provider,
			ternaryKind: ternaryKind,
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			indexAccessKind: indexAccessKind,
			identKind: shape.identKind,
			existsMethods: existsMethods,
			mapTypes: mapTypes,
			nullableWrappers: shape.nullableWrapperTypeNames ?? [],
			typeSyntax: plugin.typeSyntax,
			opaqueKinds: shape.opaqueKinds ?? [],
			mutationKinds: CheckScan.mutationKinds(shape),
			ifStatementKinds: shape.ifStatementKinds ?? [],
			blockKinds: [ for (k in [shape.blockStmtKind, shape.blockBodyKind]) if (k != null) k ],
			writeParentKinds: shape.writeParentKinds,
			reservedWords: shape.reservedWords ?? [],
			functionKinds: functionKinds,
			deferredKinds: functionKinds.concat(shape.lambdaKinds ?? [])
				.concat(shape.inlineFunctionKinds ?? [])
				.concat(ShapeVocab.loopKinds(shape))
		};
	}

}
