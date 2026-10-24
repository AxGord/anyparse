package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.GroupedFix;
import anyparse.check.Check.RiskyFix;
import anyparse.check.scan.CheckScan;
import anyparse.check.scan.RunScan;
import anyparse.query.IndexScope;
import anyparse.query.InertRegions;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.MemberKinds;
import anyparse.query.ModuleScan;
import anyparse.query.OccurrenceScan;
import anyparse.query.ParseGate;
import anyparse.query.SourceComments;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeRefPrinter;
import anyparse.query.TypeResolver;
import anyparse.query.ValueDoors;
import anyparse.runtime.Span;

using StringTools;

/**
 * One written occurrence of a qualified type path: the exact byte range of the path ITSELF
 * (never the construct around it), the path as written, and the two contexts a
 * rewrite of it has to answer for: whether it sits inside a `#if … #end` region, and whether it
 * sits in the body of a `macro` function.
 */
private typedef Occurrence = {
	var path: String;
	var span: Span;
	var conditional: Bool;

	/**
	 * Whether the occurrence sits in the body of a MACRO function — code the compiler types only
	 * in its own macro context, where a `sys.*` path is legal on every target. See the
	 * `Macro-time bodies` gate.
	 */
	var macroBody: Bool;

	/**
	 * The static-access chain node when the occurrence is written in a VALUE position (an expression), null in a type
	 * position. A value lookup tries locals, fields, module-level values and constructors before a type, so the short name
	 * there needs its own freedom proof (`valueNameFree`).
	 */
	var valueSite: Null<QueryNode>;
}

/**
 * The verdict for ONE written path in one file: how `TypeRefPrinter` says it should be spelled,
 * the import that spelling needs (null when none), whether the resolution index proves the
 * original names the declaration the reprint denotes, and the occurrences this rule rewrites.
 */
private typedef PathPlan = {
	var path: String;
	var text: String;
	var importPath: Null<String>;
	var proven: Bool;
	var targets: Array<Span>;
}

/**
 * One file's plan: every path verdict, plus the printer that produced them — it carries the
 * pending-import set the add-import arm promised, which is what `fix` materialises.
 */
private typedef FilePlan = {
	var printer: TypeRefPrinter;
	var plans: Array<PathPlan>;
}

/** The immutable inputs the occurrence scan reads, threaded through the recursion. */
private typedef ScanContext = {
	var source: String;
	var shape: RefShape;
	var typeKinds: Array<String>;
	var metaKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var functionKinds: Array<String>;
	var macroKind: Null<String>;
	var comments: Array<Span>;
	var tree: QueryNode;

	/** The path spans of every type-position node, filled by the scan — a name spelled there reads a type, never a value. */
	var typeSpans: Array<Span>;

	/** Every byte that cannot bind a name — comments and literal string TEXT (`InertRegions`). */
	var inert: Array<Span>;
}

/**
 * Flags a DOTTED type reference the file itself spells differently — the shared
 * `TypeRefPrinter` decides how the reference SHOULD be written here, and any disagreement is
 * the finding. Three arms, and only the first is a correctness matter:
 *
 * ## ARM 1 — the `pack.SubType` hybrid (why the rule exists)
 *
 * A SECONDARY (sub-module) type has two spellings that both compile:
 * `pkg.sub.Listing.Entry` — the module-qualified path, which
 * always resolves — and `pkg.sub.Entry`, the HYBRID a compiler prints
 * and a hand-written annotation copies. The hybrid resolves ONLY while an
 * `import pkg.sub.Listing.Entry;` happens to be in the file: drop
 * that import (as an unused-import sweep eventually will, once the short name's last use goes)
 * and the reference stops compiling, at a site that never changed. The fix repairs it to a
 * spelling that stands on its own — the short name when the import is there, the
 * module-qualified path when it is not.
 *
 * ## ARM 2 — plain over-qualification
 *
 * A dotted path whose short name RESOLVES here to the same type: an import, an alias, this module, the MAIN type of a
 * module in this package or an enclosing one, a builtin or its transparent root alias (`Map` for `haxe.ds.Map`).
 * `TypeRefPrinter` owns that judgement, `shadowedLocally` included — so a path kept
 * long BECAUSE the short name is taken (`pkg.sub.Listing` in a file whose bare
 * `Listing` means `other.Listing`, any name a wildcard / `using` binds, or
 * a name a `#if`-GUARDED import claims for a different path) is left exactly as written. No
 * occurrence threshold: one over-qualified use is one finding.
 *
 * ## ARM 3 — add the import (the printer's route 2)
 *
 * A path with NO short form in scope that this call SHORTENS at least `IMPORT_THRESHOLD` times —
 * outside `#if`, and surviving suppression on a fix path — whose simple name nothing else in the
 * file binds: the fix adds `import <path>;`, placed by `ImportOrder` so an already-sorted block
 * keeps its sort, and shortens those occurrences.
 *
 * The arm exists because the printer's freeness gate would otherwise close route 2 by
 * construction HERE and only here: the gate refuses an import whose simple name occurs anywhere
 * in the source, and the very text being shortened contains that name as its own last segment.
 * `print`'s `owned` parameter is the exemption — the occurrences of the path ITSELF, which are
 * bound to it by the qualification. Every OTHER occurrence of the simple name in CODE still
 * refuses the import, so a local type declaration, a second import, a type parameter or a
 * `#if`-guarded import of the same name all keep the path long; a mention in INERT text does
 * not, since neither a comment nor a literal TEXT binds anything (`TypeRefPrinter.inertRegions`).
 * Only the TEXT of a literal is inert: a single-quoted Haxe string interpolates, so a name
 * read through one is a reference and keeps the path long.
 *
 * ## What counts as an occurrence
 *
 * The scan runs over the grammar's TYPE-REFS projection (`parseFileTypeRefs`), which is the
 * plain tree plus one node per nominal in a declaration's `:Type` annotation. So every type
 * position is one node with an EXACT span — `is` right-hand sides, `new`, heritage,
 * type-parameter constraints, `from` / `to` clauses, typedef right-hand sides, and local, field,
 * parameter, return, anonymous-field and enum-constructor-parameter annotations alike, each
 * generic component on its own. A static-access chain in expression position
 * (`sys.FileSystem.exists(…)`) is the one shape the grammar spreads over several nodes; the path
 * is rebuilt from it, gated on a receiver chain whose root binds no value, and — being a VALUE position — shortened only
 * where nothing binds the short name as a value there (`valueNameFree`: a value lookup outranks every type route).
 *
 * ## Gates — fail closed
 *
 *  - **Same-declaration proof.** A changed reference is only fixed when
 *    `TypeRefPrinter.resolvePath` proves — against the resolution index — which DECLARATION the
 *    ORIGINAL text names. The printed form denotes the printer's canonical path by construction
 *    (that is its contract), and `resolvePath` answers the same canonical path for the original,
 *    so an equal, non-null answer IS "same module + name". No index, or no indexed declaration
 *    at that path, means unproven — the finding stays, the edit does not, and arm 3 is not even
 *    offered (an unproven path never receives the freeness exemption, so it never promises an
 *    import).
 *  - **Conditional compilation.** An occurrence inside a `#if … #end` region is never rewritten
 *    and never counted toward the import threshold: what is in scope there depends on the build,
 *    which neither the import map nor the index models — and the house preference is to keep a
 *    guarded `new haxe.Exception(…)` fully qualified anyway. It IS exempted from the freeness
 *    scan, since it is still the path's own text. The test is the DIRECTIVE, not a node kind —
 *    every conditional region opens with `#if` whichever of the grammar's dozen positional
 *    conditional ctors projects it (`opensConditionalRegion`).
 *  - **Metadata arguments.** Skipped wholesale. `@:access(pkg.Type)` and its siblings are
 *    dot-paths the compiler resolves WITHOUT the file's imports — verified against the compiler,
 *    `@:access(Type)` beside an `import pkg.Type;`, and even from inside `pkg` itself, silently
 *    grants nothing. An expression-position `@:privateAccess pkg.Type.f()` body is ordinary
 *    expression resolution and is NOT skipped.
 *  - **Sub-module access.** A static chain under an upper-initial field access
 *    (`a.b.Module.SubType`) is refused: shortening the module half has resolution semantics this
 *    rule does not model.
 *  - **Reification.** An `opaqueKinds` subtree — a `macro { … }` quotation, a `macro : T` type
 *    reification, a `macro class { … }` — is skipped, both here and centrally by
 *    `ReificationScan`: its spliced code is not literal source but a template the surrounding
 *    program hands to ANOTHER module, where an import added to THIS file does not apply.
 *  - **Macro-time bodies.** A path whose every SHORTENED occurrence sits in the body of a
 *    `macro` function earns no MODULE-LEVEL import. Such a body typechecks only in the macro
 *    context, where `sys.io.File` is legal on every target; a module-level import resolves in
 *    EVERY context, so hoisting the path breaks the module on js / flash with `You cannot
 *    access the sys package while targeting js`. One shortened occurrence outside a macro body
 *    lifts the gate — the module already requires the type at runtime — and shortening against
 *    an import the file ALREADY carries is unaffected, since that import is not this rule's to
 *    justify. Counting SHORTENED occurrences rather than written ones is what keeps a
 *    SUPPRESSED runtime occurrence from lifting the gate for a fix that only reaches
 *    macro-time ones; that is fail-closed policy and not a compile repair, since an
 *    unguarded runtime occurrence makes the module fail on the restricted target with or
 *    without the import.
 *
 * ## Locating a path the grammar gives no span for
 *
 * Every type-position node's span STARTS at the path, so the rewrite range is its leading `name`
 * bytes. ONE shape breaks that: a `new pkg.T(...)` node's span opens on the `new` keyword and the
 * grammar projects no separate node for the type name, so the path is SEARCHED for inside the
 * span — as a whole path token, and skipping COMMENT regions. The only thing that can sit between
 * `new` and the path is trivia, so a block comment naming the same path would otherwise win the
 * search; and losing that race is not a compile error but a silent one — the COMMENT gets
 * rewritten, the real path stays qualified, the file still compiles, the verifier confirms it, and
 * the next fixpoint pass shortens the real path with the mangled comment left behind.
 *
 * ## Verified, not trusted — `RiskyFix`
 *
 * The proof above is `canonicalize`'s, so it inherits `canonicalize`'s precondition: a
 * `pack.SubType` is read as a hybrid only when the index declares no type AT that path, and a
 * module the index never saw (outside the lint scope, or one it could not parse) removes that
 * veto — a REAL `pack.SubType` main type would then be repaired onto an imported sub-type of the
 * same simple name. No index can detect its own incompleteness, so the rule is a `RiskyFix`:
 * `apq lint --fix` applies its edits speculatively, typechecks, and reverts any file the edit
 * breaks, and with no `compilerOracle` configured the rule stays report-only wholesale. This is
 * also what makes true the claim `TypeRefPrinter` makes about all of its callers.
 *
 * ## Default OFF — opt-in
 *
 * A `DefaultOff` marker: dropped from the default set and from a bare `lint … --all` report
 * unless a project opts in via `apqlint.json`
 * (`"rules": { "shorten-type-ref": { "enabled": true } }`), or an explicit
 * `--rule shorten-type-ref` selects it. How qualified a type reference should be is a project
 * style decision; only the hybrid arm is universal, and it is not separable from the print.
 */
@:nullSafety(Strict)
final class ShortenTypeRef extends RuleBase implements DefaultOff implements RiskyFix implements GroupedFix {

	/** The rule's stable identifier — the `apqlint.json` key and the `--rule` selector. */
	private static inline final RULE_ID: String = 'shorten-type-ref';

	/**
	 * How many occurrences a path must be SHORTENED at before ADDING an import for it is worth
	 * the line. One is a wash — the import trades a qualified use for an import line plus a bare
	 * name — so the add-import arm starts at the second. Counted over the occurrences the CALL
	 * rewrites, never over the ones the file merely holds: outside `#if`, and, on a fix path,
	 * surviving suppression. An occurrence left qualified buys nothing towards the line.
	 */
	private static inline final IMPORT_THRESHOLD: Int = 2;

	/** The finding message when the short name is ALREADY reachable — the rewrite needs no import. */
	private static inline final MSG_FIXABLE: String = 'an over-qualified type reference - the short name resolves to the same type here';

	/** The finding message when the rewrite comes WITH a fresh import (the add-import arm). */
	private static inline final MSG_IMPORTABLE: String =
		'a fully-qualified type reference repeated in this file - an import would let it be spelled short';

	/** The finding message when the index could not prove a changed reference names the same declaration. */
	private static inline final MSG_UNPROVEN: String =
		'an over-qualified type reference (report-only: the resolution index does not prove the shorter spelling names the same declaration)';

	/**
	 * What the fix ledger is told about an `MSG_UNPROVEN` finding — report-only BY DESIGN, not a
	 * fixer that failed. Shorter than the message because the ledger already names the rule.
	 */
	private static inline final DECLINE_UNPROVEN: String =
		'report-only by design: the resolution index does not prove the shorter spelling names the same declaration';

	/**
	 * Where the backward scan for a `macro` modifier stops: the first preceding sibling that is not
	 * a bare modifier node. A modifier projects as a childless, nameless sibling, so anything with a
	 * child or a name is the previous DECLARATION (or its annotation) and ends the run. Same reading
	 * `CallGraph` uses for the same question.
	 */
	private static final MODIFIER_RUN_BOUNDARY: QueryNode -> Bool = c -> c.children.length > 0 || c.name != null;

	public function new() {
		super(
			RULE_ID, 'a dotted type reference whose short name resolves to the same type here, or that repeats often enough to import',
			RuleCategory.Imports
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: Null<SymbolIndex> = IndexScope.resolutionIndexOf(plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final plan: Null<FilePlan> = planFor(entry.source, plugin, index, null, entry.file);
			if (plan == null) continue;
			for (path in plan.plans) for (target in path.targets) violations.push({
				file: entry.file,
				span: target,
				rule: RULE_ID,
				severity: Severity.Warning,
				message: messageFor(path)
			});
		}
		return violations;
	}

	/**
	 * The flat projection of `fixGrouped` — the `Check.fix` contract, for the callers that never
	 * split an edit set. Grouping is the ONLY thing dropped here, which is the obligation
	 * `GroupedFix` states: the two views can never disagree about WHICH edits a fix produces.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [
			for (edit in fixGrouped(source, violations, plugin, index)) { span: edit.span, text: edit.text }
		];
	}

	/**
	 * Rewrite each proven occurrence and splice the imports the short forms rely on, one atomic
	 * GROUP per import bucket. The decision is RE-DERIVED here rather than carried on the violation —
	 * `run`'s verdict travels only as the message, so a finding the report left unproven yields no edit
	 * even if this call sees a wider index.
	 *
	 * ATOMICITY. An import edit and every use-site rewrite that depends on it form ONE group, so
	 * `FixVerifier`'s bisect keeps or drops them together and can no longer strand an orphan import —
	 * which compiles, so the confirming typecheck would have accepted it. The printer MERGES paths
	 * landing on one anchor offset into a single edit, so the group is the whole BUCKET: every path in
	 * it binds its rewrites to the same unit, and no probe can split two shortenings that share an
	 * import line either.
	 *
	 * The cost is COARSENESS, and how coarse depends on the anchoring `ImportOrder.insertOffset`
	 * picks. Fresh paths that interleave into a sorted import run get distinct offsets and therefore
	 * independent buckets; paths that all sort past the run's end, and every path in a file whose block
	 * is unsorted (the fallback anchors them all after the last import), collapse into ONE bucket — and
	 * then a single failing path drags every import-driven shortening in the file back with it.
	 * Splitting a bucket is not available: `RefactorSupport.applyEdits` gives no defined relative order
	 * to several zero-width edits at one offset, which is exactly why the printer merges them.
	 *
	 * What a fix path is handed is always a strict SUBSET of what `run` reported — `Linter.collect`
	 * drops the quoted and the `noqa`-suppressed before either `FixVerifier` or the oracle batch
	 * ever sees a finding. The plan is still re-derived from the WHOLE file, so the surviving set
	 * has to reach it: `planFor` takes it and counts BOTH import gates over the survivors, which is
	 * what keeps a promised import from outliving the rewrites that justify it (`Check.GroupedFix`,
	 * the justification contract). Before those gates counted survivors, two `noqa` lines on the
	 * only two occurrences of a path left the import behind on its own, and ONE of them still
	 * bought an import for a single rewrite.
	 */
	public function fixGrouped(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<GroupedEdit> {
		final wanted: Array<String> = [];
		for (violation in violations) {
			// Said HERE, on the caller's own violation object, because this is the site that
			// decides: an unproven finding is report-only by design and nothing downstream asks
			// again. It reaches the ledger on the RISKY path only since `FixVerifyTally` began
			// carrying the check's own sentences out of the verifier's private collect.
			if (violation.message == MSG_UNPROVEN) {
				violation.declineReason = DECLINE_UNPROVEN;
				continue;
			}
			final span: Null<Span> = violation.span;
			if (span != null) wanted.push(spanKey(span));
		}
		if (wanted.length == 0) return [];
		// The resolution index (report UNION libraries) is the wider proof. The `?? index` fallback
		// is defensive only: through `run` a null resolution index makes EVERY finding unproven, so
		// the empty `wanted` has already returned above — it exists for a caller that hands in
		// violations it built itself.
		final scope: Null<SymbolIndex> = IndexScope.resolutionIndexOf(plugin) ?? index;
		final plan: Null<FilePlan> = planFor(source, plugin, scope, wanted, violations[0].file);
		if (plan == null) return [];
		// One bucket can serve SEVERAL paths (the printer merges imports landing on one anchor), so
		// the group is the bucket and every path in it binds its own rewrites to that same unit.
		final importEdits: Array<PendingImportEdit> = plan.printer.pendingImportEdits();
		final byPath: Map<String, Int> = [];
		for (group => importEdit in importEdits) for (importPath in importEdit.paths) byPath[importPath] = group;
		final edits: Array<GroupedEdit> = [
			for (path in plan.plans) if (path.proven)
				for (target in path.targets) if (wanted.contains(spanKey(target)))
					{ span: target, text: path.text, group: groupOf(byPath, path.importPath) }
		];
		// Every promised import belongs to a path that contributed rewrites above: `planFor` was
		// handed `wanted`, so it only promised one for a path with at least `IMPORT_THRESHOLD`
		// SURVIVING targets, and such a path always comes back with a changed spelling — so each of
		// those targets is one of the edits just built. With no rewrites there are no imports
		// either, which is why the empty case needs no early-out of its own.
		for (group => importEdit in importEdits) edits.push({ span: importEdit.span, text: importEdit.text, group: group });
		return edits;
	}

	/**
	 * The atomic group a use-site rewrite joins: the bucket of the import edit its short spelling
	 * needs, or null when the spelling needs no import and the rewrite stands alone. The map-miss arm
	 * is unreachable for a `planFor` plan — a non-null `importPath` is by construction the canonical
	 * `print` pushed onto the printer's pending set, and every pending path lands in some bucket — so
	 * it exists only for a caller that builds a plan itself, and it degrades to the pre-grouping
	 * per-edit behaviour rather than to anything less safe.
	 */
	private static inline function groupOf(byPath: Map<String, Int>, importPath: Null<String>): Null<Int> {
		return importPath == null ? null : byPath[importPath];
	}

	/** Whether `c` can sit INSIDE a dotted type path — an identifier character or the separator itself. */
	private static inline function isPathChar(c: Int): Bool {
		return c == '.'.code || SourceText.isIdentChar(c);
	}

	/** A span as the key `fix` matches a re-derived occurrence against the violation it was reported as. */
	private static inline function spanKey(span: Span): String {
		return '${span.from}:${span.to}';
	}

	/** Which of the three messages `plan` earns — unproven first, then the import-free arm, then the add-import one. */
	private static function messageFor(plan: PathPlan): String {
		return if (!plan.proven)
			MSG_UNPROVEN;
		else if (plan.importPath == null)
			MSG_FIXABLE;
		else
			MSG_IMPORTABLE;
	}

	/**
	 * One file's verdicts: every qualified type path it writes, grouped, each carrying the
	 * printer's answer for it. Null when the file does not parse.
	 *
	 * ONE printer serves the whole file (its per-file state is the resolution input, so a second
	 * instance would answer the same), and its pending-import set is authoritative for the plan:
	 * `print` is handed the freeness exemption ONLY for a path that has cleared the index proof and
	 * both import gates, and those gates count the occurrences THIS call will rewrite — so a
	 * promised import always belongs to a plan this rule will act on.
	 *
	 * `wanted` is the caller's surviving findings as `spanKey`s, or null for "every occurrence
	 * counts". `run` reports the whole file and passes null; a fix path was handed a SUBSET
	 * (`Linter.collect` drops the quoted and the suppressed) and passes it, because an import
	 * promised to the printer here can no longer be taken back at the emit site.
	 */
	private static function planFor(
		source: String, plugin: GrammarPlugin, index: Null<SymbolIndex>, wanted: Null<Array<String>>, path: String
	): Null<FilePlan> {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		// The type-refs projection is the same tree PLUS one `TypeRef` node per nominal in a
		// declaration's `:Type` annotation — the positions the default projection drops. It is what
		// makes field / parameter / return annotations reachable with an exact span instead of the
		// three per-shape textual searches an annotation region slice would need.
		final refsTree: Null<QueryNode> = CheckScan.parseTypeRefsOrNull(plugin, source);
		if (tree == null || refsTree == null) return null;
		// Re-bind: a null-check does not narrow into an anonymous-structure literal.
		final scoped: QueryNode = tree;
		final shape: RefShape = plugin.refShape();
		final lexical: Array<LexRegion> = plugin.lexicalRegions(source);
		final context: ScanContext = {
			source: source,
			shape: shape,
			typeKinds: plugin.typeRefShape().typeRefKinds,
			metaKinds: plugin.metaShape().metaKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			functionKinds: shape.functionKinds ?? [],
			macroKind: shape.macroModifierKind,
			comments: SourceComments.collectCommentRegions(lexical),
			tree: scoped,
			typeSpans: [],
			inert: InertRegions.of(scoped, lexical, shape)
		};
		final occurrences: Array<Occurrence> = [];
		scan(refsTree, context, false, false, false, occurrences);
		final printer: TypeRefPrinter = printerFor(source, scoped, plugin, index, path);
		final plans: Array<PathPlan> = [];
		final file: String = path;
		for (path in distinctPaths(occurrences)) {
			final mine: Array<Occurrence> = rewritable(path, occurrences, context, index, file);
			// `targets` stays WHOLE-file — the finding set the fix path filters against `wanted` itself — while the two
			// counts both import gates read are taken over the SURVIVING occurrences, the ones THIS call will rewrite: how
			// many there are (the threshold), and how many sit outside a macro-time body (the `Macro-time bodies` gate). A
			// value site whose short name something else may bind is in neither: it is left as written.
			final targets: Array<Span> = [for (o in mine) o.span];
			final surviving: Array<Occurrence> = mine.filter(o -> wanted == null || wanted.contains(spanKey(o.span)));
			final survivingUses: Int = surviving.length;
			final runtimeUses: Int = surviving.filter(o -> !o.macroBody).length;
			if (targets.length == 0) continue;
			final proven: Bool = printer.resolvePath(path) != null;
			// An import is promised to the PRINTER here, and the printer is source-driven: it cannot
			// know that a caller dropped this path's findings on the way in. `wanted` is that
			// knowledge, and both counts above are taken over it, so the promise is measured against
			// the rewrites that will actually pay for it — a path with no surviving target claims
			// neither the import nor the simple name (claiming the name would keep a path whose
			// findings DID survive qualified for a collision nobody will write).
			final importable: Bool = proven && runtimeUses > 0 && survivingUses >= IMPORT_THRESHOLD;
			// `owned` is WHOLE-file too: the freeness exemption has to cover every byte range the file still spells as this
			// path, suppressed ones included, or a suppressed occurrence's own last segment would veto the import.
			final owned: Null<Array<Span>> = importable ? [for (o in occurrences) if (o.path == path) o.span] : null;
			final printed: PrintedTypeRef = printer.print(path, owned);
			if (printed.text == path) continue;
			final kept: Array<Span> = keptTargets(printed.text, path, mine, context, index, file);
			if (kept.length > 0) plans.push({
				path: path,
				text: printed.text,
				importPath: printed.importPath,
				proven: proven,
				targets: kept
			});
		}
		return { printer: printer, plans: plans };
	}

	/**
	 * The occurrences of `path` this call may rewrite: outside `#if`, and — at a value site — only where the short name
	 * binds nothing but the type (`valueNameFree`).
	 */
	private static function rewritable(
		path: String, occurrences: Array<Occurrence>, context: ScanContext, index: Null<SymbolIndex>, file: String
	): Array<Occurrence> {
		final simple: String = SourceText.lastSegment(path);
		return occurrences.filter(
			o -> o.path == path && !o.conditional && (o.valueSite == null || valueNameFree(simple, o, context, index, file))
		);
	}

	/**
	 * The spans of `mine` to rewrite to `text`: all of them, unless `text` is an ALIAS spelling whose head is neither the
	 * path's simple name nor its own head — a name `rewritable` never asked about, so each value site asks again for it.
	 */
	private static function keptTargets(
		text: String, path: String, mine: Array<Occurrence>, context: ScanContext, index: Null<SymbolIndex>, file: String
	): Array<Span> {
		final head: String = text.split('.')[0];
		return head == SourceText.lastSegment(path) || head == path.split('.')[0] ? [for (o in mine) o.span] : [
			for (o in mine) if (o.valueSite == null || valueNameFree(head, o, context, index, file)) o.span
		];
	}

	/**
	 * Whether the short name `name` may replace the static-access chain of the value site `o`: no CODE byte of the file
	 * outside a type position, a comment and a member access spells it — so no local, parameter or field of this file declares
	 * it, the half `ValueDoors.bindsNoValue` cannot ask at a site that writes no identifier yet — and that predicate finds no
	 * value either: a member the enclosing type declares or inherits, a module-level field or constructor of the module,
	 * anything an import may bring. Without an index, or for a file it does not hold, nothing is proven.
	 */
	private static function valueNameFree(name: String, o: Occurrence, context: ScanContext, index: Null<SymbolIndex>, file: String): Bool {
		final site: Null<QueryNode> = o.valueSite;
		final info: Null<FileInfo> = index?.fileInfo(file);
		if (index == null || info == null || site == null) return false;
		final source: String = context.source;
		return !OccurrenceScan.referencedUnqualifiedInRange(
				source, name, 0, source.length, context.typeSpans.concat(context.inert), context.comments
			) && ValueDoors.bindsNoValue(site, name, o.span, info, context.tree, context.shape, file, index);
	}

	/** A printer over `source` with the file's plain-import map and the run's resolution index. */
	private static function printerFor(
		source: String, tree: QueryNode, plugin: GrammarPlugin, index: Null<SymbolIndex>, path: String
	): TypeRefPrinter {
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		return TypeRefPrinter.forFile(path, source, tree, provider != null ? provider.importMap(source, path) : [], plugin, index);
	}

	/** The written paths of `occurrences`, deduplicated, in first-seen order — the plan's iteration order. */
	private static function distinctPaths(occurrences: Array<Occurrence>): Array<String> {
		final out: Array<String> = [];
		for (occurrence in occurrences) if (!out.contains(occurrence.path)) out.push(occurrence.path);
		return out;
	}

	/**
	 * Visit every node of `node`'s subtree, collecting each qualified type-path occurrence. Two
	 * subtree kinds are skipped WHOLESALE:
	 *
	 *  - a reification (`opaqueKinds`) — `macro { … }`, `macro : T`, `macro class { … }` — whose
	 *    spliced code is not literal source but a template for another module;
	 *  - a metadata annotation's arguments (`metaShape().metaKinds` — `MetaCall` carries them as
	 *    its children). `@:access(pkg.Type)` and its siblings are dot-paths the compiler resolves
	 *    WITHOUT the file's imports: verified against the compiler, `@:access(Type)` beside an
	 *    `import pkg.Type;` — and even from inside `pkg` itself — silently grants nothing, and the
	 *    build then fails at the private access the annotation was written for. `MetaExpr` is not
	 *    one of these kinds, so a `@:privateAccess pkg.Type.f()` body, which IS ordinary expression
	 *    resolution, keeps being scanned.
	 *
	 * A `#if … #end` region is NOT skipped — it is FLAGGED. Its occurrences are exempted from the
	 * printer's short-name freeness scan (they are still the path's own text) but never rewritten
	 * and never counted toward the import threshold, since what is in scope inside a region
	 * depends on the build, which neither the import map nor the index models.
	 *
	 * A `macro` FUNCTION body is flagged the same way, and for one narrower purpose: its occurrences
	 * are still rewritable, but they do not entitle the path to a module-level import (see the
	 * `Macro-time bodies` gate). The `macro` keyword projects as a childless modifier SIBLING ahead
	 * of the declaration, so the flag is set while descending into the function and inherited by its
	 * whole subtree.
	 */
	private static function scan(
		node: QueryNode, context: ScanContext, conditional: Bool, underUpperField: Bool, macroBody: Bool, out: Array<Occurrence>
	): Void {
		if (context.opaqueKinds.contains(node.kind) || context.metaKinds.contains(node.kind)) return;
		final region: Bool = conditional || ModuleScan.opensConditionalRegion(node, context.source, context.shape.conditionalIfKeyword);
		final found: Null<Occurrence> = occurrenceOf(node, context, region, underUpperField, macroBody);
		if (found != null) out.push(found);
		final upperReceiver: Bool = node.kind == context.shape.fieldAccessKind && SourceText.isUpperInitial(node.name ?? '');
		final kids: Array<QueryNode> = node.children;
		for (i in 0...kids.length) {
			final child: QueryNode = kids[i];
			// The modifier is a SIBLING that precedes the declaration, so the flag is set on the way
			// DOWN into the function and inherited by its whole subtree.
			final inMacro: Bool = macroBody
				|| (context.functionKinds.contains(child.kind)
					&& MemberKinds.macroModifierPrecedes(kids, i, context.macroKind, MODIFIER_RUN_BOUNDARY));
			scan(child, context, region, upperReceiver, inMacro, out);
		}
	}

	/**
	 * The occurrence `node` itself is, or null when it is not one. Two shapes reach here:
	 *
	 *  - a TYPE-POSITION node (`typeRefShape().typeRefKinds`), whose `name` slot already holds the
	 *    whole dotted path — an `is` right-hand side, a return type, heritage, a type-parameter
	 *    constraint, a `new`, and (through the type-refs projection) every `:Type` annotation;
	 *  - a static-access CHAIN in expression position (`pkg.sub.Type.member`), which the grammar
	 *    projects as nested field accesses rather than one node, so the path is rebuilt from it.
	 *
	 * `underUpperField` refuses the second shape under an upper-initial field access — the
	 * `a.b.Module.SubType` sub-module access, whose short form has resolution semantics this rule
	 * does not model.
	 */
	private static function occurrenceOf(
		node: QueryNode, context: ScanContext, conditional: Bool, underUpperField: Bool, macroBody: Bool
	): Null<Occurrence> {
		final name: Null<String> = node.name;
		if (name == null) return null;
		if (context.typeKinds.contains(node.kind)) {
			final span: Null<Span> = pathSpanOf(node, name, context);
			if (span != null) context.typeSpans.push(span);
			return name.indexOf('.') == -1 || !SourceText.isUpperInitial(SourceText.lastSegment(name)) || span == null ? null : {
				path: name,
				span: span,
				conditional: conditional,
				macroBody: macroBody,
				valueSite: null
			};
		}
		if (node.kind != context.shape.fieldAccessKind || underUpperField || !SourceText.isUpperInitial(name)) return null;
		final path: Null<String> = staticChainPath(node, context);
		final span: Null<Span> = node.span;
		// The chain's own span must BE the path verbatim. A chain broken by a comment or a newline
		// is refused rather than sliced: the rewrite replaces the whole span with the short name.
		return if (path == null || span == null)
			null
		else if (context.source.substring(span.from, span.to) == path)
			{
				path: path,
				span: span,
				conditional: conditional,
				macroBody: macroBody,
				valueSite: node
			}
		else
			null;
	}

	/**
	 * The exact byte range of the PATH inside `node`. A type-position node's span STARTS at the
	 * path (a generic head's span runs on past it, to the closing `>`), so the leading `name`
	 * bytes are the answer. A `new pkg.T(...)` node's span opens on the `new` keyword and closes
	 * after the argument list instead, so the path is located inside it — as a whole token, since
	 * a bare `indexOf` would also match a longer path's tail.
	 */
	private static function pathSpanOf(node: QueryNode, name: String, context: ScanContext): Null<Span> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		if (span.from + name.length <= span.to && context.source.substring(span.from, span.from + name.length) == name)
			return new Span(span.from, span.from + name.length);
		final at: Int = tokenOffset(context, name, span.from, span.to);
		return at < 0 ? null : new Span(at, at + name.length);
	}

	/**
	 * The dotted path a static-access chain rooted at `node` spells (`sys.FileSystem` for the
	 * `FileSystem` field access of `sys.FileSystem.exists(...)`), or null when the chain is not
	 * one. Every segment BELOW the type must be lower-initial — Haxe package names are — and the
	 * root must be a bare identifier that resolves to NO value binding: a receiver that resolves
	 * to a local, parameter or field is a value, so `holder.Member` is an instance field access
	 * that merely looks like a package path.
	 */
	private static function staticChainPath(node: QueryNode, context: ScanContext): Null<String> {
		final identKind: Null<String> = context.shape.identKind;
		if (identKind == null) return null;
		final segments: Array<String> = [node.name ?? ''];
		var cursor: QueryNode = node;
		while (cursor.children.length == 1) {
			final child: QueryNode = cursor.children[0];
			final name: Null<String> = child.name;
			if (name == null || name == '' || SourceText.isUpperInitial(name)) return null;
			segments.unshift(name);
			if (child.kind == identKind) {
				final span: Null<Span> = child.span;
				return span == null || TypeResolver.resolveBindingFrom(name, span, context.tree, context.shape) != null
					? null
					: segments.join('.');
			}
			if (child.kind != context.shape.fieldAccessKind) return null;
			cursor = child;
		}
		return null;
	}

	/**
	 * The offset of `token` inside `source[from...to)` as a whole PATH token in CODE — neither
	 * neighbour an identifier character or a `.`, so the tail of a longer dotted path never matches,
	 * and never inside a comment — or -1 when it does not occur.
	 *
	 * The comment mask is the whole point. The only caller is the `new pkg.T(...)` shape, whose node
	 * span opens on the `new` keyword, and the only thing that can sit between that keyword and the
	 * path is trivia — so a BLOCK COMMENT naming the same path is a first-match trap: the rewrite then
	 * lands in the COMMENT and leaves the real path qualified. That output COMPILES, so the `RiskyFix`
	 * verifier confirms it rather than reverting, and the next fixpoint pass shortens the real path
	 * with the mangled comment left behind.
	 */
	private static function tokenOffset(context: ScanContext, token: String, from: Int, to: Int): Int {
		final source: String = context.source;
		var i: Int = from;
		while (i + token.length <= to) {
			final at: Int = source.indexOf(token, i);
			if (at < 0 || at + token.length > to) return -1;
			final after: Int = at + token.length;
			final boundedLeft: Bool = at == 0 || !isPathChar(source.fastCodeAt(at - 1));
			final boundedRight: Bool = after >= source.length || !isPathChar(source.fastCodeAt(after));
			if (boundedLeft && boundedRight && !OccurrenceScan.offsetWithinAny(at, context.comments)) return at;
			i = at + 1;
		}
		return -1;
	}

}
