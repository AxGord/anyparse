package anyparse.check;

import anyparse.check.AccessorClauseText.AccessorClause;
import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.CrossFileEdits;
import anyparse.check.Check.CrossFileFix;
import anyparse.check.Check.FrameworkAware;
import anyparse.check.Check.RiskyArm;
import anyparse.check.Check.RiskyCrossFileEdit;
import anyparse.check.ConstantHoist.Hoist;
import anyparse.check.NamingPrivatize.PrivatizeCandidate;
import anyparse.check.NamingPrivatize.Privatized;
import anyparse.check.NamingRenames.CrossFileRename;
import anyparse.check.NamingRenames.DeclRename;
import anyparse.check.NamingRenames.RenameRefusal;
import anyparse.query.CanonicalEdit;
import anyparse.query.IndexScope;
import anyparse.query.NamingPolicy.FrameworkContract;
import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.query.NamingPolicy.NamingRule;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.NamingPolicy.PropertyClause;
import anyparse.query.ParseGate;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags declarations whose identifier violates a naming convention. The check
 * is grammar-agnostic: it asks the plugin's `NamingSupport` to project the
 * declarations worth checking (each with a neutral category and modifier set)
 * and to resolve the effective `NamingPolicy` for the file — a discovered
 * `checkstyle.json` when present, else the grammar's built-in default. Every
 * declaration is matched against the first applicable rule; a name failing the
 * rule's `format` is a `Warning`.
 *
 * ## checkstyle compatibility
 *
 * The policy comes from the plugin: for Haxe, `HaxeNamingSupport.policyFor`
 * adapts an existing `checkstyle.json` via `CheckstyleConfigLoader`, mirroring
 * how the writer honours an `hxformat.json`. A project that already ships a
 * checkstyle config gets its naming rules out of the box; the check itself
 * never parses that format — it stays language- and config-neutral.
 *
 * ## No naming support → no-op
 *
 * A grammar without a naming convention (a binary format) returns null from
 * `namingSupport`; the check skips it.
 *
 * ## Not every odd name is a finding
 *
 * A declaration the grammar marks `contractName` — a field of an anonymous structure / typedef,
 * whose identifier is part of the structural type and of whatever wire format it mirrors — is not
 * reported at all: the project does not own that name, so there is nothing to correct. Distinct
 * from `renameUnsafe` (an accessor-backed property, an `@:rtti` member), which IS the project's
 * own name and stays reported — only the autofix keeps away from it.
 *
 * A THIRD suppression is the PROJECT's rather than the grammar's: a member a framework reaches BY
 * NAME — its enclosing type extends a root declared in `apqlint.json` (`frameworks`), and that
 * contract names it — carries the framework's spelling, not a name the project chose, so `run`
 * drops the finding too.
 */
@:nullSafety(Strict)
final class Naming implements Check implements CrossFileFix implements RiskyArm implements ConfigAware implements FrameworkAware {

	/**
	 * A lowercase head over an all-uppercase / digit tail of four or more characters - see `normalizerArtifactName`.
	 */
	private static final ARTIFACT_NAME_PATTERN: EReg = new EReg("^[a-z][A-Z0-9]{4,}$", '');

	/**
	 * The member renames this `--fix` PASS has already accepted, across BOTH seams the pass drives
	 * (`crossFileFix` and `fix`) — see `RenameClaims`.
	 */
	private final _runClaims: RenameClaims = new RenameClaims();

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	/**
	 * The privatize arm's verdicts from the latest `run`, keyed by `CheckScan.spanKey(file, declaration span)`:
	 * every whole-project gate is asked there, where the entire file set is in hand, and read back by
	 * span from `crossFileFix` (which steps aside) and `riskyFix` (which writes the edit).
	 */
	private var _privatized: Map<String, Privatized> = [];

	/**
	 * The findings of the latest `run` whose fix is the cross-file rename arm (`NamingCrossRename`), keyed like
	 * `_privatized`: a type or an enum value. Only candidacy is decided there — it reads the declaration alone —
	 * and every gate is asked by `riskyCrossFileFix`, which only a compiler-oracle run reaches.
	 */
	private var _crossRenamed: Array<String> = [];

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return 'naming';
	}

	public function description(): String {
		return 'declaration name violates the naming convention (default, or a discovered checkstyle.json)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final contracts: Array<FrameworkContract> = LintConfig.frameworksFor(_resolveConfig, files);
		final indexOf: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		final privatizable: Array<PrivatizeCandidate> = [];
		final crossRenamed: Array<String> = [];
		final out: Array<Violation> = RunScan.collectWith(files, plugin, plugin.namingSupport(), (entry, tree, support, violations) -> {
			// The values of an enum abstract written `@:enum` (or through the `#if` version guard)
			// project as fields of a plain abstract, where the FIELD naming rule governs them — and an
			// enum value is PascalCase by convention, so each one reads as a violation.
			final guarded: Array<Int> = EnumAbstractForms.valueStarts(plugin, tree);
			final decls: Array<NamedDecl> = [
				for (d in support.project(tree, propertyFacts(plugin, entry.source))) if (!EnumAbstractForms.isValue(d.span, guarded)) d
			];
			final byStart: Map<Int, NamedDecl> = [];
			for (decl in decls) {
				final span: Null<Span> = decl.span;
				if (span != null) byStart[span.from] = decl;
			}
			final policy: NamingPolicy = support.policyFor(entry.file);
			for (v in violationsFor(entry.file, decls, policy)) if (!frameworkOwned(v, byStart, support, indexOf, contracts)) {
				final at: Null<Span> = v.span;
				final decl: Null<NamedDecl> = at == null ? null : byStart[at.from];
				violations.push(v);
				if (decl != null && at != null && NamingCrossRename.isCandidate(decl)) crossRenamed.push(CheckScan.spanKey(entry.file, at));
				if (decl == null || !NamingPrivatize.isCandidate(decl, policy)) continue;
				// Re-bound: strict null-safety does not narrow inside a struct literal.
				final candidate: NamedDecl = decl;
				privatizable.push({
					file: entry.file,
					source: entry.source,
					tree: tree,
					decl: candidate
				});
			}
		});
		_privatized = NamingPrivatize.verdicts(privatizable, files, plugin);
		_crossRenamed = crossRenamed;
		for (v in out) {
			final arm: Null<Privatized> = privatizedOf(v);
			if (arm != null) v.message += ' — nothing outside ${arm.owner} reads it, so the fix makes it private';
		}
		return out;
	}

	/**
	 * Autofix: rename each flagged binding to a mechanically-corrected name when
	 * the rename is provably complete in this one file. A function-body-scoped
	 * binding (Local / Param / CatchVar) is a candidate; a private FIELD is one
	 * only when the WIDEST index available proves it confined (no subtype, no
	 * `@:access`, no `@:allow`, no skip-parse file that could hide one) and no
	 * OTHER indexed file names it through a reflection call
	 * (`reflectionNamesInOtherFiles` — an AST verdict, not a text scan). Every
	 * candidate is then held to two in-file guards: every textual occurrence of
	 * the old name must be covered by the resolved rename spans (an uncovered one
	 * — a bare `$name` interpolation the resolver misses, a reflection string —
	 * means an incomplete rename, so bail), and the new name must not already be
	 * bound in the file (a collision would duplicate or shadow it). The new name
	 * comes from the applicable `normalize`; the occurrences from
	 * `Rename.renameOccurrences`, emitted as edits the caller batches and
	 * re-parse-validates.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final support: Null<NamingSupport> = plugin.namingSupport();
		if (support == null) return RenameRefusal.all(violations, RenameRefusal.NO_SUPPORT);
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (tree == null) return RenameRefusal.all(violations, RenameRefusal.NO_TREE);

		final policy: NamingPolicy = support.policyFor(violations[0].file);
		final shape: RefShape = plugin.refShape();

		final flaggedFroms: Array<Int> = [];
		// The violation each flagged declaration came from, so a gate deep in the rename chain can
		// write its refusal onto the finding the caller will report (`Violation.declineReason`).
		// `fix` is handed the caller's OWN objects, which is what makes a note set here reach it.
		final flaggedAt: Map<Int, Violation> = [];
		for (v in violations) {
			final s: Null<Span> = v.span;
			if (s == null) continue;
			flaggedFroms.push(s.from);
			flaggedAt[s.from] = v;
		}

		// Hoisted ONCE per fix() call (not per finding): the flagged names any OTHER indexed
		// file reaches through a reflection call's string argument (the cross-file reflection
		// rename guard), plus a per-owner confinement memo so a type with many flagged private
		// members runs the project-wide confinement scan a single time.
		final decls: Array<NamedDecl> = support.project(tree, propertyFacts(plugin, source));
		final flaggedNames: Array<String> = [];
		for (decl in decls) {
			final s: Null<Span> = decl.span;
			if (s != null && flaggedFroms.contains(s.from) && !flaggedNames.contains(decl.name)) flaggedNames.push(decl.name);
		}
		final confinedMemo: Map<String, Bool> = [];
		// The inherited-member proof of a `_`-prefix field rename walks the FULL supertype
		// closure, so it resolves through the plugin's resolution scope (report files UNION the
		// configured libraries) when present — a field of an `openfl` / `lime` subclass is then
		// provable rather than blocked as unresolvable. The two CROSS-FILE proofs below take a
		// DIFFERENT index from this one, and neither takes the report index once the project declares
		// a resolution scope. With no declared scope both fall back to `index`, which is the state
		// every unit test holding a bare plugin exercises.
		final resolutionIndex: Null<SymbolIndex> = IndexScope.resolutionIndexOf(plugin) ?? index;
		// Those two cross-file proofs — is this private member confined, and does another file name
		// it in a reflection call — share ONE index, and it is the WIDEST rather than the report one.
		// `IndexScope.widestScopeIndex` refuses a scope that exists ONLY because a Haxe std was
		// discovered, so a project declaring nothing keeps the report index; a project that DID declare
		// `resolutionRoots` / `resolutionLibs` gets the std inside this index too, and since both
		// proofs are keyed on a NAME, a std or haxelib coincidence can decide them. The direction is
		// safe (an extra subtype or reflection name only adds a refusal), so it costs usefulness, not
		// correctness. The narrower PROJECT scope is the wrong one for a name-keyed scan: with the
		// reflective string in the LIBRARY half of the same declared scope, the narrow seam licenses a
		// member DELETION the wide one refuses. Both name-keyed scans share
		// `ReflectionScan.scopeFiles`, so `wideIndex` is the CONFINEMENT half's index here and the
		// reflection scan's FALLBACK for a run with no declared scope, not its scope; that fallback
		// asks the discovered std too, where the report index alone would not — same direction, only
		// refusals are added. It runs once per `fix()` call, not once per run.
		//
		// This is the decision that lets the SINGLE-FILE rename go ahead. CONFINEMENT: a false
		// "confined" — a subtype or an `@:access` grantee declared in a file the run does not lint —
		// lets a one-file `--fix` rename the member in that file alone and leave the grantee's access
		// standing. REFLECTION: with `Reflect.field(c, 'My_Field')` in a file the run does not lint, a
		// one-file `--fix` renames the field and the reflective read goes on naming a field that no
		// longer exists, where a project-wide run refuses with `REFLECTION_NAME`.
		//
		// Each widening is one-way, and both point the same way. Widening only ever ADDS a subtype /
		// grant, so `confined` can only go true -> false; it only ever ADDS reflection names, so
		// `REFLECTION_NAME` only fires more often. So this path can only LOSE a rename to a refusal,
		// never gain one.
		final wideIndex: Null<SymbolIndex> = IndexScope.widestScopeIndex(plugin, index);
		// The REPORT index goes to the reflection scan, not `wideIndex`: the SCOPE is
		// `ReflectionScan.scopeFiles`, and an index is only the fallback for a run that declared none —
		// where the report set IS the whole world. Handing the wide one would have made the two
		// interchangeable (on a declared scope it is a subset of what the seam adds anyway) and hidden
		// which of them the guard actually depends on.
		final reflectionNames: Array<String> = NamingRenames.reflectionNamesInOtherFiles(
			index, violations[0].file, flaggedNames, plugin, support
		);

		// The HOIST arm runs FIRST. A flagged LOCAL that is an author-intended CONSTANT — an
		// UPPER_SNAKE name over a compile-time-constant initializer — moves to its enclosing type
		// KEEPING its spelling, which at class level is what the Constant rule wants; camelCasing it
		// in place would destroy the intent the name states. Every gate failure leaves the
		// declaration to the ordinary rename arm below, silently. The occupancy gate reads THIS
		// check's own occurrence resolution, handed over as a resolver so `ConstantHoist` needs
		// nothing private of it.
		final hoists: Array<Hoist> = ConstantHoist.hoistsFor(
			decls, source, tree, policy, plugin, support, flaggedFroms, resolutionIndex, violations[0].file,
			(declFrom, name) ->
				resolutionIndex == null
					? null
					: NamingRenames.declaringFileRenameSpans(
						source, tree, declFrom, name, shape, plugin, NamingRenames.isDistinctiveName(name), true,
						{ index: resolutionIndex, file: violations[0].file }
					)
		);
		final hoistedFroms: Array<Int> = [for (h in hoists) h.declFrom];
		final edits: Array<{ span: Span, text: String }> = ConstantHoist.edits(hoists);
		final claims: Array<DeclRename> = [];
		for (decl in decls) {
			final declSpan: Null<Span> = decl.span;
			if (declSpan != null && hoistedFroms.contains(declSpan.from)) continue;
			final rename: Null<DeclRename> = NamingRenames.renameEditsFor(
				decl, source, tree, policy, shape, plugin, flaggedFroms, reflectionNames, confinedMemo, resolutionIndex, wideIndex,
				violations[0].file, flaggedAt
			);
			final owner: Null<String> = RenameClaims.memberOwnerOf(decl);
			if (rename == null || deferred(rename, edits, claims, owner, resolutionIndex, flaggedAt, declSpan)) continue;
			_runClaims.claim(owner, rename.newName, resolutionIndex);
			claims.push(rename);
			for (edit in rename.edits) edits.push(edit);
		}
		return edits;
	}

	/**
	 * Cross-file autofix (the `CrossFileFix` seam): rename each flagged member whose references can reach
	 * beyond its declaring file — a NON-confined private field / constant / method (reachable from its
	 * subtypes / `@:access`-grant files), or ANY public one (reachable from anywhere). The single-file
	 * `fix` skips both (a non-confined member is not provably contained; a public one is refused outright by
	 * `RenameRefusal.of`); here the rename is proven complete across EVERY affected report file and emitted
	 * as one atomic multi-file edit set. The declaring file resolves scope-correctly (the occurrence
	 * set + completeness gate), and a collision with a constructor PARAMETER there is repaired by
	 * qualifying through `this.` rather than refused; each other affected file classifies every occurrence
	 * of the old name — an `ActiveCode` one is a reference to rename, a `CommentTrivia` one renames along
	 * when the name is distinctive, and a `ConditionalRaw` / `StringLiteral` / `DirectiveComment`
	 * occurrence (or a `targetName` already colliding in a file, an unresolvable hierarchy, an `@:rtti` /
	 * reflection-string hazard) turns the WHOLE rename report-only. A public member's affected set is every
	 * scope file MENTIONING the name (plus the owner's own hierarchy), so the completeness proof spans the
	 * whole lint scope: a narrow `--fix` scope refuses rather than half-applying. The caller
	 * (`apq lint --fix`) commits every affected file or none.
	 */
	public function crossFileFix(
		files: Array<{ file: String, source: String }>, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<Array<CrossFileEdits>> {
		if (violations.length == 0 || index == null) return [];
		final support: Null<NamingSupport> = plugin.namingSupport();
		if (support == null) return [];
		final idx: SymbolIndex = index;
		final shape: RefShape = plugin.refShape();
		final resolutionIndex: SymbolIndex = IndexScope.resolutionIndexOf(plugin) ?? idx;
		final sourceByFile: Map<String, String> = [for (f in files) f.file => f.source];
		final out: Array<Array<CrossFileEdits>> = [];
		for (v in violations) {
			// The privatize arm owns this finding: the rename steps aside, and the edit comes from `riskyFix`.
			if (privatizedOf(v) != null) {
				RenameRefusal.note(v, RenameRefusal.PRIVATIZE_ARM);
				continue;
			}
			final rename: Null<CrossFileRename> = NamingRenames.crossFileRenameFor(
				v, sourceByFile, support, shape, plugin, idx, resolutionIndex
			);
			if (rename == null) continue;
			if (_runClaims.defers(rename.owner, rename.newName, resolutionIndex)) {
				if (v.declineReason == null) v.declineReason = RenameRefusal.NAME_CLAIMED;
				continue;
			}
			_runClaims.claim(rename.owner, rename.newName, resolutionIndex);
			out.push(rename.slices);
		}
		return out;
	}

	public function riskyArmFindings(violations: Array<Violation>): Array<Violation> {
		return [for (v in violations) if (privatizedOf(v) != null) v];
	}

	public function riskyCrossFileFindings(violations: Array<Violation>): Array<Violation> {
		return [for (v in violations) if (crossRenamedBy(v)) v];
	}

	/** The cross-file rename arm (`NamingCrossRename`): one atomic edit set per type / enum value its gates admit. */
	public function riskyCrossFileFix(
		files: Array<{ file: String, source: String }>, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<RiskyCrossFileEdit> {
		final support: Null<NamingSupport> = plugin.namingSupport();
		if (support != null) return NamingCrossRename.edits(files, violations, plugin, support);
		for (v in violations) RenameRefusal.note(v, RenameRefusal.NO_SUPPORT);
		return [];
	}

	/** The privatize arm: each finding `run` proved confined gets its `public` keyword rewritten to `private`. */
	public function riskyFix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final arm: Null<Privatized> = privatizedOf(v);
			if (arm != null) edits.push({ span: arm.keywordSpan, text: NamingPrivatize.keyword() });
		}
		return edits;
	}

	/**
	 * Whether `rename` must DEFER to an edit already accepted in this pass, for any of the three
	 * reasons a same-pass conflict takes.
	 *
	 * Its spans OVERLAP an accepted edit: two flagged declarations can want the SAME token, because
	 * the qualification arm rewrites a bare reference to a MEMBER that may itself be flagged and
	 * renamed in this very pass, and overlapping edits have no defined winner in `applyEdits`
	 * (`dropContainedEdits` resolves by array index).
	 *
	 * Or an accepted rename already CLAIMED the same new name over an overlapping SCOPE. That reason
	 * exists because `collidesInScope` reads the ORIGINAL source, where the new name does not yet
	 * exist: `CAPS` and `Caps` both correcting to `_caps` each see a clean scope and would otherwise
	 * both land, producing the duplicate declaration `haxe` rejects. Overlap, not equality, is the
	 * scope test - a file-wide member claim covers every function scope inside it, and a closure's
	 * scope is nested in its host's, while two DISJOINT function scopes genuinely may share a target
	 * name (`remove(__id)` and `for (__id in ...)` both correcting to `id`).
	 *
	 * Or a rename accepted for ANOTHER FILE of this pass already claimed the same new name on a type in
	 * the same inheritance chain (`RenameClaims`, which `owner` and `index` address). The two
	 * reasons above are file-local, and `claims` only ever holds this one `fix(source, ...)` call's
	 * renames - a pass also drives `crossFileFix`, and a superclass and its subclass do not even take
	 * the same seam, since a type with a subtype is never confined.
	 *
	 * Deferral is not refusal, but the two kinds recover differently. A file-local loser re-fires on the
	 * next `--fix` pass: `naming` is a full-scope check and the file it lost in was edited, so the
	 * driver keeps it active, and by then the ordinary collision scan judges it against a source that
	 * holds the name. A RUN-CLAIM loser may be the only finding in its file, in which case that file
	 * receives no edit, drops out of the driver's `active` set, and waits for the next `--fix` RUN
	 * instead - which is why `RenameClaims` says "a later pass or run".
	 */
	private function defersToAnAcceptedRename(
		rename: DeclRename, edits: Array<{ span: Span, text: String }>, claims: Array<DeclRename>, owner: Null<String>,
		index: Null<SymbolIndex>
	): Bool {
		if (CanonicalEdit.editsOverlapAny(rename.edits, edits)) return true;
		for (c in claims) if (c.newName == rename.newName && c.scope.from < rename.scope.to && rename.scope.from < c.scope.to) return true;
		return _runClaims.defers(owner, rename.newName, index);
	}

	/**
	 * Does `rename` yield to one this run has already accepted — and, when it does, record THAT as
	 * the reason on the finding it came from?
	 *
	 * The two halves belong in one call. Spelled at the call site as
	 * `if (defers(…)) { note(…); continue; }` the loop pays a branch it does not need and drops the
	 * refusal helper's answer on the floor, and the reason is what the whole seam exists to carry.
	 */
	private function deferred(
		rename: DeclRename, edits: Array<{ span: Span, text: String }>, claims: Array<DeclRename>, owner: Null<String>,
		index: Null<SymbolIndex>, flaggedAt: Map<Int, Violation>, declSpan: Null<Span>
	): Bool {
		if (!defersToAnAcceptedRename(rename, edits, claims, owner, index)) return false;
		if (declSpan != null) RenameRefusal.note(flaggedAt[declSpan.from], RenameRefusal.NAME_CLAIMED);
		return true;
	}

	/** Whether `run` gave `v` to the cross-file rename arm. */
	private function crossRenamedBy(v: Violation): Bool {
		final s: Null<Span> = v.span;
		return s != null && _crossRenamed.contains(CheckScan.spanKey(v.file, s));
	}

	/** The privatize arm's verdict for `v`, or null when its fix is the rename. */
	private function privatizedOf(v: Violation): Null<Privatized> {
		final s: Null<Span> = v.span;
		return s == null ? null : _privatized[CheckScan.spanKey(v.file, s)];
	}

	/**
	 * The violations for `decls` under `policy`: each declaration is tested
	 * against the first rule whose category matches and whose `requireMods` are
	 * all present and `forbidMods` all absent; a name failing that rule's
	 * `format` is a `Warning`. A declaration with no span is skipped (no
	 * location to report), as is one no rule applies to and one whose name is a
	 * language idiom outside any policy (`NamedDecl.reservedName`).
	 */
	public static function violationsFor(file: String, decls: Array<NamedDecl>, policy: NamingPolicy): Array<Violation> {
		final out: Array<Violation> = [];
		for (decl in decls) {
			final span: Null<Span> = decl.span;
			if (span == null || decl.reservedName == true || decl.contractName == true) continue;
			final rule: Null<NamingRule> = applicableRule(decl, policy);
			if (rule == null) continue;
			final artifact: Null<String> = artifactCorrection(decl.name, rule);
			if (artifact == null && rule.format.match(decl.name)) continue;
			out.push({
				file: file,
				span: span,
				rule: 'naming',
				severity: Severity.Warning,
				message: artifact == null
					? '${rule.label}: \'${decl.name}\''
					: 'all-caps tail after a lowercase head (normalizer artifact): \'${decl.name}\''
			});
		}
		return out;
	}

	/**
	 * The property facts `NamingSupport.project` asks for, read off `source` the first time the projection
	 * needs them, or null for a grammar with no type info: WHICH members declare an accessor clause is the
	 * grammar fact `TypeInfoProvider.propertyAccessors` (through the plugin's own memo), and what each clause
	 * says about storage is `AccessorClauseText`'s reading of it (`propertyClauseAt`). Every projection this
	 * check and its rename paths make goes through here, so a declaration has ONE category and ONE modifier
	 * set whichever of them asks.
	 */
	public static function propertyFacts(plugin: GrammarPlugin, source: String): Null<() -> Map<Int, PropertyClause>> {
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		if (provider == null) return null;
		final known: TypeInfoProvider = provider;
		var memo: Null<Map<Int, PropertyClause>> = null;
		return () -> {
			final held: Null<Map<Int, PropertyClause>> = memo;
			if (held != null) return held;
			final read: Map<Int, PropertyClause> = [
				for (from in known.propertyAccessors(source).keys()) from => propertyClauseAt(source, from)
			];
			memo = read;
			return read;
		};
	}

	/**
	 * Whether the declaration `v` reports carries a FRAMEWORK's name rather than one the project chose —
	 * its enclosing type extends a declared contract's root and the contract claims its whole spelling.
	 * `Start` spelled anything else is a method Unity never calls, so the finding is wrong rather than
	 * merely unfixable, and the check drops it exactly as it drops a `contractName`. Dropping it in `run`
	 * also settles the autofix for free — `fix` is only ever handed findings `run` reported.
	 *
	 * Asked as `frameworkOwnsName` and NOT as `frameworkReachable`, which is the wider question the
	 * unused-* rules ask: a prefix contract can reach a member without owning its name. No correction the
	 * Haxe grammar ships can eat utest's `test` / `spec` / `setup` / `teardown`, so what follows one is
	 * the project's to choose and a finding there is right — where a prefix no correction can keep
	 * (Godot's `_`) owns the spelling like an exact name does. That is also what keeps this gate inert
	 * for every project that declares nothing: the only built-in contract is utest's, and its fragments
	 * are of the surviving kind.
	 *
	 * Asked of the FINDING and not of every projected declaration, which is what keeps it cheap: the
	 * answer can cost a whole-scope supertype closure, and a name the policy already accepts never
	 * needed one.
	 */
	private static function frameworkOwned(
		v: Violation, byStart: Map<Int, NamedDecl>, support: NamingSupport, index: () -> Null<SymbolIndex>,
		contracts: Array<FrameworkContract>
	): Bool {
		final span: Null<Span> = v.span;
		if (span == null) return false;
		final decl: Null<NamedDecl> = byStart[span.from];
		return decl != null && support.frameworkOwnsName(decl, index, contracts);
	}

	/** The first rule in `policy` applicable to `decl` (category + modifier filters), or null. */
	private static function applicableRule(decl: NamedDecl, policy: NamingPolicy): Null<NamingRule> {
		return policy.find(
			rule ->
				rule.category == decl.category && rule.requireMods.foreach(m -> decl.mods.contains(m))
				&& !rule.forbidMods.exists(m -> decl.mods.contains(m))
		);
	}

	/**
	 * The lowercased spelling of `name` when it is a normalizer ARTIFACT - a lowercase head over an
	 * all-uppercase / digit tail of at least FOUR characters (`hEIGHT`, `wIDTH`), the shape the
	 * former first-letter-lowercasing normalizer produced out of a screaming constant. Null when
	 * `name` is not one, or when lowercasing changes nothing (a digit-only tail such as `x1234`).
	 *
	 * The four-character floor is a deliberate TRADE-OFF, not a complete test. A head plus a
	 * three-letter acronym is a name people write on purpose (`sRGB`, `xDPI`, `dBFS`, `mRNA`) and is
	 * spelled identically to an artifact of a three-letter constant (`HTML` -> `hTML`), so the two
	 * cannot be told apart here. The floor buys silence on the deliberate names at the cost of
	 * letting three-letter-acronym artifacts through; lowercasing an `sRGB` someone chose is the
	 * worse error, since the check's own autofix would destroy it.
	 */
	private static function normalizerArtifactName(name: String): Null<String> {
		if (!ARTIFACT_NAME_PATTERN.match(name)) return null;
		final lowered: String = name.toLowerCase();
		return lowered == name ? null : lowered;
	}

	/**
	 * The lowercased correction for a name the policy's `format` ACCEPTS but that is a normalizer
	 * artifact, or null when `name` is not one or the correction is not what `rule` wants. The
	 * `rule.format.match(lowered)` gate is load-bearing: it keeps the arm inside whatever policy
	 * governs the file - a checkstyle policy spelling the category UPPER_SNAKE rejects `height`, and
	 * there the arm stays silent instead of reporting a violation nothing can correct - and it
	 * guarantees every reported artifact is fixable.
	 */
	private static function artifactCorrection(name: String, rule: NamingRule): Null<String> {
		final lowered: Null<String> = normalizerArtifactName(name);
		return lowered != null && rule.format.match(lowered) ? lowered : null;
	}

	/**
	 * The corrected spelling for `name` under `rule`: the normalizer ARTIFACT correction when the
	 * name is one, else the rule's own `normalize`. Null when neither applies, the result is
	 * unchanged, or it does not itself satisfy the rule's format. The single decision point for
	 * what a name should become, shared by the report side and both fix paths so they cannot drift.
	 */
	private static function correctedName(name: String, rule: NamingRule, ?refusal: (String) -> Void): Null<String> {
		final artifact: Null<String> = artifactCorrection(name, rule);
		if (artifact != null) return artifact;
		final say: Null<(String) -> Void> = refusal;
		final normalize: Null<String -> Null<String>> = rule.normalize;
		// Announced HERE rather than reconstructed by the caller: which of the two ways this can
		// answer nothing happened is knowable only inside, and a caller that guessed would be
		// re-implementing the condition it is describing.
		if (normalize == null) {
			if (say != null) say(RenameRefusal.NO_NORMALIZER);
			return null;
		}
		final newName: Null<String> = normalize(name);
		if (newName != null && newName != name && rule.format.match(newName)) return newName;
		if (say != null) say(RenameRefusal.NORMALIZER_DECLINED);
		return null;
	}

	/**
	 * What the accessor clause of the property whose declaration starts at `from` says about storage. A clause
	 * `AccessorClauseText` cannot read says nothing - both answers false - so the projection keeps the reading it gives
	 * a property without facts.
	 */
	private static function propertyClauseAt(source: String, from: Int): PropertyClause {
		final clause: Null<AccessorClause> = AccessorClauseText.accessorClauseAt(source, from);
		if (clause == null) return { storageless: false, readOnly: false };
		final storageless: Bool = AccessorClauseText.storageless(clause);
		return { storageless: storageless, readOnly: storageless && AccessorClauseText.writesNever(clause) };
	}

}
