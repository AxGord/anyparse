package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.CrossFileEdits;
import anyparse.check.Check.CrossFileFix;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.Violation;
import anyparse.check.Check.VolatileMessage;
import anyparse.query.AddImport;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.cli.CliArgs;
import anyparse.runtime.Span;
import haxe.ds.ArraySort;

using StringTools;
using Lambda;

/**
 * One statement an ambient source could carry: its module `path`, whether it is a `using`, and the
 * simple name it binds. The name travels with the path because every soundness question is about
 * the NAME and every edit is about the path.
 */
private typedef Hoistable = {
	final path: String;
	final isUsing: Bool;
	final simple: String;
}

/**
 * One module that SPELLS a statement, and where: the `file` the removal lands in and the `span` of
 * the statement itself. A plan carries a list of these because a hoist is one insertion and many
 * deletions, each of which a finding has to be able to point at.
 */
private typedef Spelled = {
	final file: String;
	final span: Span;
}

/**
 * One decided hoist: `statement` moves into `site`, out of each `from` module. `holders` of
 * `governed` modules already had it, which is what the threshold was read against.
 */
private typedef HoistPlan = {
	final site: String;
	final statement: Hoistable;
	final from: Array<Spelled>;
	final governed: Int;
	final holders: Int;
}

/**
 * One run's view of the directories: the candidate `sites` DEEPEST FIRST, the modules each governs,
 * each module's own index entry and its ladder of possible ambient positions, the statements every
 * EXISTING ambient source already carries, and what this run has decided to put at each site.
 */
private typedef HoistContext = {
	final sites: Array<String>;
	final governedAt: Map<String, Array<String>>;
	final infoOf: Map<String, FileInfo>;
	final ladderOf: Map<String, Array<String>>;
	final existingAt: Map<String, Array<ImportInfo>>;
	final decided: Map<String, Array<Hoistable>>;
}

/**
 * One site's census: every candidate statement in discovery order, how many of the site's modules
 * already HOLD it (spelled or received from the chain), and the modules it can be lifted out of.
 */
private typedef HoistCensus = {
	final keys: Array<String>;
	final byKey: Map<String, Hoistable>;
	final holders: Map<String, Int>;
	final spellers: Map<String, Array<Spelled>>;
}

/**
 * Flags an `import` (or an allow-listed `using`) that stands in at least a threshold share of the
 * modules one directory's AMBIENT SOURCE would govern, and moves it there: the fix creates or
 * extends that source and deletes the statement from every module it hoisted from.
 *
 * DEFAULT OFF — where a project keeps its shared imports is a convention, not a defect.
 *
 * The positions an ambient source could occupy come from the grammar, and the modules one governs
 * come from the same seam the rules judging such a file already read, so there is one notion of "the
 * modules of this directory" and no second directory walk. A site is weighed only when the run holds
 * every module it governs, and the widest position is weighed first, so a statement lands as high as
 * its share reaches and a nested position takes only what its parents did not.
 *
 * The candidate criterion is POSITIVE: a plain import or an allow-listed `using`, unguarded, whose
 * simple name has one declaration reachable by any band the ambient statement would outrank, in a
 * chain that is bounded and carries neither a guarded statement nor a second binder of that name. A
 * module's own declaration and its own explicit import both outrank the addition, so a module that
 * already has the right one is simply unaffected.
 *
 * A `using` binds a name AND a position: hoisting one out of a module demotes it below every own
 * `using` that stays, so it is removed only where every remaining own `using` is on the allow-list.
 * Adding one to a module that had none is safe in the other direction — the new candidates sit below
 * every own `using` and below every field.
 *
 * The refusals, the nesting rule and the config keys: `docs/cli-query-tool.md`.
 */
@:nullSafety(Strict)
final class HoistCommonImport implements Check implements CrossFileFix implements ConfigAware implements DefaultOff
		implements VolatileMessage {

	/** The share of a directory's modules a statement must stand in, as a percentage. */
	public static inline final DEFAULT_THRESHOLD: Int = 50;

	/** How many modules a directory must govern before a share of them means anything. */
	public static inline final DEFAULT_MIN_MODULES: Int = 3;

	private static inline final RULE_ID: String = 'hoist-common-import';

	/** The denominator a percentage threshold is read against. */
	private static inline final PERCENT: Int = 100;

	/** The keyword an `import` statement's identity opens with. */
	private static inline final IMPORT_WORD: String = 'import';

	/** The keyword a `using` statement's identity opens with. */
	private static inline final USING_WORD: String = 'using';

	/** The fragment before the SHARE in a message — the anchor `messageIdentity` masks from. */
	private static inline final SHARE_LEAD: String = ' stands in ';

	/** The `using` modules allowed in an ambient source unless a project names its own list. */
	private static final DEFAULT_USING_ALLOW: Array<String> = ['StringTools', 'Lambda'];

	/** The linter's memoised per-file config resolver; null when run outside it. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'an import most modules of a directory spell, which the directory\'s ambient source could carry';
	}

	public function messageIdentity(message: String): String {
		return MessageMask.maskAfter(message, SHARE_LEAD);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [
			for (plan in planFor(files, plugin, null)) for (spelled in plan.from)
				{
					file: spelled.file,
					span: spelled.span,
					rule: RULE_ID,
					severity: Severity.Warning,
					message: '${plan.statement.isUsing ? USING_WORD : IMPORT_WORD} \'${plan.statement.path}\'$SHARE_LEAD${plan.holders} of '
						+ '${plan.governed} module(s) governed by \'${plan.site}\' — it belongs there'
				}
		];
	}

	/** The whole fix is cross-file — a hoist is one ambient source plus a deletion in every module it lifted from. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	public function crossFileFix(
		files: Array<{ file: String, source: String }>, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<Array<CrossFileEdits>> {
		final sourceOf: Map<String, String> = [];
		for (entry in files) sourceOf[entry.file] = entry.source;
		final plans: Array<HoistPlan> = planFor(files, plugin, index);
		final out: Array<Array<CrossFileEdits>> = [];
		final sites: Array<String> = [];
		for (plan in plans) if (!sites.contains(plan.site)) sites.push(plan.site);
		for (site in sites) {
			final slice: Null<Array<CrossFileEdits>> = siteSlice(site, plans, violations, sourceOf, plugin);
			if (slice != null) out.push(slice);
		}
		return out;
	}

	/**
	 * Every hoist this file set supports, deepest site first and with a statement an ancestor site
	 * also takes dropped from its descendants.
	 *
	 * `run` and `crossFileFix` both derive from here, so the report and the edits cannot disagree
	 * about which statement moves where.
	 */
	private function planFor(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, index: Null<SymbolIndex>
	): Array<HoistPlan> {
		final report: SymbolIndex = index ?? SymbolIndex.build(files, plugin);
		final resolve: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? report;
		final ctx: HoistContext = contextOf(report, plugin);
		final plans: Array<HoistPlan> = [];
		for (site in ctx.sites) planSite(site, ctx, resolve, plans);
		return plans;
	}

	/**
	 * Weigh one site and append every statement that earns a place in it, recording the decision so a
	 * parent site counts a module served by this one as having the statement.
	 */
	private function planSite(site: String, ctx: HoistContext, resolve: SymbolIndex, plans: Array<HoistPlan>): Void {
		final governed: Array<String> = ctx.governedAt[site] ?? [];
		final cfg: LintConfig = LintConfig.resolveWith(_resolveConfig, site);
		if (governed.length < (cfg.intOption(RULE_ID, 'minModules') ?? DEFAULT_MIN_MODULES)) return;
		final threshold: Int = cfg.intOption(RULE_ID, 'threshold') ?? DEFAULT_THRESHOLD;
		final allow: Array<String> = cfg.stringListOption(RULE_ID, 'usingAllowList') ?? DEFAULT_USING_ALLOW;
		final above: Array<String> = providedAtOrAbove(site, ctx);
		final census: HoistCensus = censusOf(governed, ctx, allow);
		for (key in census.keys) {
			final statement: Null<Hoistable> = census.byKey[key];
			final lifted: Null<Array<Spelled>> = census.spellers[key];
			final count: Int = census.holders[key] ?? 0;
			if (statement == null || lifted == null || lifted.length == 0 || above.contains(key)) continue;
			if (count * PERCENT >= threshold * governed.length) take(statement, lifted, count, site, ctx, resolve, plans);
		}
	}

	/** One statement's identity: the kind and the path, which is all an ambient source carries. */
	private static inline function keyOf(statement: Hoistable): String {
		return '${statement.isUsing ? USING_WORD : IMPORT_WORD}|${statement.path}';
	}

	/** One import statement's hoist identity, whatever its shape — for asking whether a chain already carries it. */
	private static inline function statementKeyOf(imp: ImportInfo): String {
		return '${imp.kind == ImportKind.Using ? USING_WORD : IMPORT_WORD}|${imp.raw}';
	}

	/**
	 * Every candidate statement under `governed`, with the count of modules that HOLD it and the ones
	 * it may be lifted out of.
	 *
	 * A module HOLDS a statement whether it spells it or receives it from an existing ambient source —
	 * a module the chain already serves is not one that is missing the statement. It is a source of
	 * removals only where the statement may leave it.
	 */
	private static function censusOf(governed: Array<String>, ctx: HoistContext, allow: Array<String>): HoistCensus {
		final census: HoistCensus = {
			keys: [],
			byKey: [],
			holders: [],
			spellers: []
		};
		for (file in governed) {
			final info: Null<FileInfo> = ctx.infoOf[file];
			if (info == null) continue;
			final held: Array<String> = inForce(info);
			for (imp in info.imports) {
				final statement: Null<Hoistable> = hoistableOf(imp, allow);
				if (statement == null) continue;
				final key: String = keyOf(statement);
				if (!census.byKey.exists(key)) {
					census.byKey[key] = statement;
					census.keys.push(key);
				}
				if (!held.contains(key)) held.push(key);
				if (removable(info, statement, allow)) noteSpeller(census, key, file, imp.span);
			}
			for (key in held) census.holders[key] = (census.holders[key] ?? 0) + 1;
		}
		return census;
	}

	/** Record that `file` spells `key` at `span` and may be lifted out of. */
	private static function noteSpeller(census: HoistCensus, key: String, file: String, span: Span): Void {
		var out: Null<Array<Spelled>> = census.spellers[key];
		if (out == null) {
			out = [];
			census.spellers[key] = out;
		}
		out.push({
			file: file,
			span: span
		});
	}

	/**
	 * One site's whole edit set — the ambient source created or extended, plus the deletion in each
	 * module — or null when nothing survives justification or the writer refuses the source.
	 *
	 * Only a deletion a violation IN THIS CALL asks for is emitted, and a statement left with no
	 * surviving deletion is dropped from the source too: an ambient statement nothing was lifted
	 * out of is an edit no finding asked for.
	 */
	private static function siteSlice(
		site: String, plans: Array<HoistPlan>, violations: Array<Violation>, sourceOf: Map<String, String>, plugin: GrammarPlugin
	): Null<Array<CrossFileEdits>> {
		final removals: Array<CrossFileEdits> = [];
		final statements: Array<Hoistable> = [];
		for (plan in plans) if (plan.site == site) {
			final asked: Array<Spelled> = plan.from.filter(f -> justified(violations, f));
			if (asked.length == 0) continue;
			statements.push(plan.statement);
			for (f in asked) removals.push({
				file: f.file,
				edits: [
					{
						span: f.span,
						text: ''
					}
				]
			});
		}
		if (statements.length == 0) return null;
		final existing: Null<String> = sourceOf[site];
		final built: Null<String> = builtAmbientSource(site, existing, statements, plugin);
		if (built == null || built == existing) return null;
		final head: CrossFileEdits = existing == null
			? {
				file: site,
				edits: [],
				create: built
			}
			: {
				file: site,
				edits: [
					{
						span: new Span(0, existing.length),
						text: built
					}
				]
			};
		return [head].concat(removals);
	}

	/** Whether a violation of this rule in THIS call asks for `spelled`'s deletion. */
	private static function justified(violations: Array<Violation>, spelled: Spelled): Bool {
		return violations.exists(v -> {
			final span: Null<Span> = v.span;
			return v.rule == RULE_ID && v.file == spelled.file && span != null && span.from == spelled.span.from
			&& span.to == spelled.span.to;
		});
	}

	/**
	 * The ambient source's whole text with `statements` added, or null when the writer refuses one.
	 *
	 * Built by the same seat every inserting fixer uses (`AddImport`), statement by statement, so an
	 * existing source keeps its own statements and their order and a new one is placed by the
	 * project's own import ordering rather than by this rule's idea of it.
	 */
	private static function builtAmbientSource(
		site: String, existing: Null<String>, statements: Array<Hoistable>, plugin: GrammarPlugin
	): Null<String> {
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(site);
		// An EMPTY source is not at the writer's fixed point, so the inserting seat refuses it: a new
		// source is SEEDED with its first statement instead, and every later one is placed by that seat
		// exactly as it would be in an existing file. Imports lead, so the seed is one whenever there is
		// one — a `using` opens its own block below them.
		final ordered: Array<Hoistable> = statements.filter(s -> !s.isUsing).concat(statements.filter(s -> s.isUsing));
		if (ordered.length == 0) return null;
		var text: String = existing ?? '${ordered[0].isUsing ? USING_WORD : IMPORT_WORD} ${ordered[0].path};\n';
		for (i in (existing == null ? 1 : 0) ... ordered.length) {
			final statement: Hoistable = ordered[i];
			switch AddImport.addImport(text, statement.path, statement.isUsing, false, plugin, optsJson) {
				case EditResult.Ok(next, _):
					text = next;
				case EditResult.Err(_):
					return null;
			}
		}
		return text;
	}

	/**
	 * The run's directory view: every candidate position, the modules each governs, and what the
	 * chain already carries.
	 *
	 * A site is DROPPED unless the run holds every module it governs. The share is a property of the
	 * directory, so a run holding half of it would decide on half the evidence — and the governed set
	 * is the seam's, never a walk of this rule's own.
	 */
	private static function contextOf(report: SymbolIndex, plugin: GrammarPlugin): HoistContext {
		final infoOf: Map<String, FileInfo> = [];
		final ladderOf: Map<String, Array<String>> = [];
		final existingAt: Map<String, Array<ImportInfo>> = [];
		final order: Array<String> = [];
		for (info in report.allFiles()) {
			infoOf[info.file] = info;
			for (group in info.ambientImports) if (!existingAt.exists(group.file)) existingAt[group.file] = group.imports;
			final ladder: Array<String> = plugin.ambientImportSites(info.file, info.pkg);
			if (ladder.length == 0) continue;
			ladderOf[info.file] = ladder;
			for (site in ladder) if (!order.contains(site)) order.push(site);
		}
		final governedAt: Map<String, Array<String>> = [];
		for (site in order) {
			final governance: Null<AmbientImportGovernance> = plugin.ambientImportGovernance(site);
			if (governance == null || !governance.bounded) continue;
			final names: Array<String> = [for (governed in governance.governs) governed.file];
			if (names.length > 0 && names.foreach(name -> infoOf.exists(name))) governedAt[site] = names;
		}
		final sites: Array<String> = [for (site in order) if (governedAt.exists(site)) site];
		// SHALLOWEST first, by governed COUNT: a site below another governs a SUBSET of its modules, so
		// the count orders the containment with no path arithmetic. Weighing the widest position first
		// is what makes a statement land as HIGH as its share reaches while a nested position takes
		// only what its parents did not — and the two together leave no statement in two sources of one
		// chain, which is the shape that would read as a redundant import of its own parent. The sort
		// is stable, so ties keep discovery order and the plan is deterministic.
		ArraySort.sort(sites, (a, b) -> (governedAt[b] ?? []).length - (governedAt[a] ?? []).length);
		return {
			sites: sites,
			governedAt: governedAt,
			infoOf: infoOf,
			ladderOf: ladderOf,
			existingAt: existingAt,
			decided: []
		};
	}

	/** Record one sound statement's hoist into `site`, so a parent site counts the modules this one serves. */
	private static function take(
		statement: Hoistable, lifted: Array<Spelled>, holders: Int, site: String, ctx: HoistContext, resolve: SymbolIndex,
		plans: Array<HoistPlan>
	): Void {
		if (!hoistSound(statement, site, ctx, resolve)) return;
		final taken: Array<Hoistable> = ctx.decided[site] ?? [];
		taken.push(statement);
		ctx.decided[site] = taken;
		plans.push({
			site: site,
			statement: statement,
			from: lifted,
			governed: (ctx.governedAt[site] ?? []).length,
			holders: holders
		});
	}

	/**
	 * Every statement already in force AT or ABOVE `site`. A statement the chain above a directory
	 * already provides binds nothing new there, and proposing it again is how a nested ambient source
	 * comes to repeat its own parent.
	 */
	private static function providedAtOrAbove(site: String, ctx: HoistContext): Array<String> {
		final governed: Array<String> = ctx.governedAt[site] ?? [];
		if (governed.length == 0) return [];
		final ladder: Array<String> = ctx.ladderOf[governed[0]] ?? [];
		// The DECIDED half is what keeps a nested source from repeating its own parent: the widest
		// position is weighed first, so by the time a nested one is, every statement an ancestor took is
		// already in force under it.
		final at: Int = ladder.indexOf(site);
		return at < 0
			? []
			: [
				for (i in at ... ladder.length) for (imp in ctx.existingAt[ladder[i]] ?? []) statementKeyOf(imp)
			].concat([
				for (i in at ... ladder.length) for (statement in ctx.decided[ladder[i]] ?? []) keyOf(statement)
			]);
	}

	/**
	 * Every statement `info` already receives without spelling it — from an EXISTING ambient source
	 * anywhere in its chain, which is what keeps a module served by a nested source from reading as one
	 * that is missing the statement.
	 */
	private static function inForce(info: FileInfo): Array<String> {
		return [
			for (group in info.ambientImports) for (imp in group.imports) statementKeyOf(imp)
		];
	}

	/**
	 * Whether adding `statement` to `site` leaves every name in every governed module bound as before.
	 *
	 * The evidence, each part positive: the name has ONE declaration in the resolution scope and the
	 * path names it; every governed module's chain is bounded and carries neither a guarded statement
	 * nor a binder of that name; and no module binds the name twice, since within one file the last
	 * binder wins. A `using` needs one more — no ambient source may carry a `using` already, or this
	 * site would insert itself above one and re-rank the extensions.
	 */
	private static function hoistSound(statement: Hoistable, site: String, ctx: HoistContext, resolve: SymbolIndex): Bool {
		if (retargetsSomeModule(statement, site, ctx, resolve)) return false;
		for (file in ctx.governedAt[site] ?? []) {
			final info: Null<FileInfo> = ctx.infoOf[file];
			if (info == null || !info.ambientImportsBounded) return false;
			for (group in info.ambientImports) for (imp in group.imports) {
				if (imp.guarded || SymbolIndex.bindsSimpleName(imp, statement.simple)) return false;
				if (statement.isUsing && imp.kind == ImportKind.Using) return false;
			}
			var binders: Int = 0;
			for (imp in info.imports) if (SymbolIndex.bindsSimpleName(imp, statement.simple)) {
				if (imp.guarded) return false;
				binders++;
			}
			if (binders > 1) return false;
		}
		return true;
	}

	/**
	 * Whether adding `statement` could make its simple name mean something ELSE in any module `site`
	 * governs.
	 *
	 * An ambient explicit import outranks exactly three bands a module does not spell — its own
	 * package, the root package, and its own WILDCARD imports — each checked against the compiler. So
	 * a second declaration of the name is a retarget only where one of those bands carries it, and a
	 * namesake in an unrelated package of a library no governed module reaches is none. The path must
	 * also name exactly ONE declaration: two files claiming one module path leave nothing to compare.
	 */
	private static function retargetsSomeModule(statement: Hoistable, site: String, ctx: HoistContext, resolve: SymbolIndex): Bool {
		final targets: Array<ResolvedType> = resolve.refs.resolveQualifiedRefAll(statement.path);
		if (targets.length != 1) return true;
		final owner: String = targets[0].file.file;
		final rivals: Array<FileInfo> = resolve.refs.declaringFiles(statement.simple).filter(found -> found.file != owner);
		if (rivals.length == 0) return false;
		for (file in ctx.governedAt[site] ?? []) {
			final info: Null<FileInfo> = ctx.infoOf[file];
			if (info == null) return true;
			for (rival in rivals) if (rival.pkg == info.pkg || rival.pkg == '' || reachesByWildcard(info, rival)) return true;
		}
		return false;
	}

	/** Whether one of `info`'s PACKAGE wildcards (`p.*`) reaches `rival`'s package — a static wildcard brings members, never a type. */
	private static function reachesByWildcard(info: FileInfo, rival: FileInfo): Bool {
		return info.imports.exists(
			imp -> imp.kind == ImportKind.Wild && imp.raw.endsWith('.*') && imp.raw.substr(0, imp.raw.length - 2) == rival.pkg
		);
	}

	/**
	 * Whether `statement` may be REMOVED from `info` — always, for an import; for a `using`, only when
	 * every own `using` the module keeps is on the allow-list.
	 *
	 * Hoisting a `using` demotes it below every own `using` that stays, so a module carrying one this
	 * rule cannot vouch for keeps its own statement instead and is left unaffected: own outranks
	 * ambient either way.
	 */
	private static function removable(info: FileInfo, statement: Hoistable, allow: Array<String>): Bool {
		return !statement.isUsing || info.imports.foreach(imp -> imp.kind != ImportKind.Using || allow.contains(imp.raw));
	}

	/**
	 * `imp` as a hoistable statement, or null when its shape is one this rule cannot reason about:
	 * a guarded statement, an alias, a wildcard, a member import, or a `using` off the allow-list.
	 */
	private static function hoistableOf(imp: ImportInfo, allow: Array<String>): Null<Hoistable> {
		if (imp.guarded) return null;
		final simple: String = SourceText.lastSegment(imp.raw);
		return switch imp.kind {
			case ImportKind.Import: SourceText.isUpperInitial(simple) ? {
				path: imp.raw,
				isUsing: false,
				simple: simple
			} : null;
			case ImportKind.Using: allow.contains(imp.raw) ? {
				path: imp.raw,
				isUsing: true,
				simple: simple
			} : null;
			case ImportKind.Alias, ImportKind.Wild: null;
		};
	}

}
