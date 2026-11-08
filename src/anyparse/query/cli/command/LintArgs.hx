package anyparse.query.cli.command;

import anyparse.check.Check;
import anyparse.check.EffectiveRules;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.RuleCategory;
import anyparse.check.RuleIndex;
import anyparse.check.Severity;
import anyparse.query.ExitCode.EXIT_OK;
import anyparse.query.ExitCode.EXIT_RUNTIME;
import anyparse.query.ExitCode.EXIT_USAGE;
import anyparse.query.cli.CliArgs.ResolvedInputs;
import anyparse.query.cli.command.LintCommand.CheckPartition;
import anyparse.query.cli.command.LintCommand.LintOpts;
import anyparse.query.cli.command.LintCommand.LintRange;

using Lambda;

/**
 * The one answer to "what did this lint invocation ask for": its arguments read into `LintOpts`, the usage text, the `--range`
 * windows, the rule set that `--rule` / `--category` and the project config resolve to, and the `--list-rules` listing, which
 * is terminal like `--help`.
 */
@:nullSafety(Strict)
final class LintArgs {

	public static inline final FORMAT_JSON: String = 'json';
	public static inline final FORMAT_CHECKSTYLE: String = 'checkstyle';
	public static inline final FORMAT_TEXT: String = 'text';

	/** The `--list-rules` rendering as the markdown rule index (`RuleIndex`); no lint run has this format. */
	private static inline final FORMAT_MARKDOWN: String = 'markdown';

	/** The `--summary` flag, named where the parser and the list-rules refusal both speak of it. */
	private static inline final SUMMARY_FLAG: String = '--summary';

	/**
	 * Split `checks` into the sets `lint --fix` applies differently.
	 *
	 * A RiskyFix check is verified against the compiler oracle and is EXCLUDED from the
	 * unverified safe loop. The `OracleRelaxable` checks (prefer-inline among them) are
	 * the exception: each has a byte-identical safe subset, so WITHOUT an oracle it runs in
	 * the safe loop (null-safety gate on) instead of being left report-only, and WITH an oracle
	 * it joins the verified risky set with its candidate set widened (`setOracleRelaxed`,
	 * applied by the caller). Every OTHER RiskyFix check (avoid-dynamic) keeps the contract: verified when an
	 * oracle is configured, report-only via `verifyRiskyFixes` otherwise — its risky fix is
	 * NEVER applied unverified. So a RiskyFix check only leaves the risky set for the safe loop
	 * when it is OracleRelaxable AND no oracle is configured.
	 *
	 * A `RiskyArm` check is in BOTH sets when an oracle is configured: the safe loop runs its safe
	 * arms, and the verifier its `riskyFix`.
	 *
	 * The safe set then splits by lint SCOPE: a per-file check decides a file's findings from
	 * that file alone, so later passes re-lint only the files a prior pass changed. A cross-file
	 * check must see every file or it mis-resolves on the active subset — those run over the
	 * full set each pass.
	 */
	public static function partitionChecks(checks: Array<Check>, oracleConfigured: Bool): CheckPartition {
		final relaxableNoOracle: (Check) -> Bool = c -> !oracleConfigured && c is OracleRelaxable;
		final safeChecks: Array<Check> = [for (c in checks) if (!(c is RiskyFix) || relaxableNoOracle(c)) c];
		final fullScopeIds: Array<String> = [
			'unused-private',
			'prefer-final-field',
			'unused-parameter',
			'prefer-final-public-field',
			'prefer-read-only-field',
			'field-init-at-declaration',
			// Resolves a path receiver's member types through a SymbolIndex over the set it is
			// given — on the active SUBSET a type declared elsewhere reads as unresolvable, which
			// re-flags the very loops the type gate is meant to skip.
			'map-keys-lookup',
			// Same cross-file path-receiver resolution as map-keys-lookup: on the active SUBSET a
			// declaring type reads as unresolvable and a Map get/set finding re-exposed by an earlier
			// pass (a nested lookup) is re-skipped, so the fixed-point loop never converges on it.
			'prefer-index-access',
			// Its no-null-value census is OWNER-scoped, not name-scoped — the
			// name-scoped form refused realistic map names on std collisions alone, and
			// `MapValueScan` documents the replacement. What a narrow set costs it is therefore the
			// three cross-file doors, not an occurrence count. Two of them — an `@:access` grant
			// and a subtype that could store a null through the map — are asked of
			// `IndexScope.resolutionIndexOf(plugin) ?? report`; the third,
			// `privateMemberScanIsSound`, is asked of the REPORT index alone and so narrows with
			// it. On the active SUBSET of a
			// project that declares no resolution scope a subtype in an untouched file reads as
			// absent, which turns an unprovable site into a wrongly PROVEN one — the unsound
			// direction, unlike the misses the other ids here guard against. Pinned by
			// `CrossScopeSoundnessTest`'s `subtype-map-write` cell (arm
			// `M-MAPVALUE-SUBTYPE-REPORT-INDEX`).
			'redundant-map-exists',
			// prefer-static-extension's shadow gate resolves the receiver type — and its whole
			// supertype / alias closure — through the index. On the active SUBSET a declaring type
			// or a `typedef` target declared elsewhere reads as unresolvable, so a site an earlier
			// pass exposed degrades to report-only and the loop never converges on it.
			'prefer-static-extension',
			// redundant-tostring's fix gates resolve the receiver's TYPE through the index — is it
			// declared, extern, a class. On the active SUBSET a type declared elsewhere reads as
			// unresolvable, so a site an earlier pass exposed degrades to report-only and the loop
			// never converges on it; worse, run() and fix() would then disagree, since
			// computeFileLintEdits hands fix() the whole-report index either way.
			'redundant-tostring',
			// prefer-inline's soundness gates are ALL whole-project: the subtype-override gate
			// (SubtypeGraph.hasSubtype + a strict-subtype member lookup), the value-reference name scan, and
			// the interface gate. On the active SUBSET a subtype / value-use / interface declared elsewhere
			// reads as absent, so an overridden or value-referenced method is wrongly inlined ("Field X is
			// inlined and cannot be overridden").
			'prefer-inline',
			// trivial-getter's collapse gates are whole-project too: subtypeBlocks /
			// subtypeFieldBlocks resolve the owner's subtypes through the index. On the
			// active SUBSET a subtype declared elsewhere reads as absent, so a later
			// pass can collapse a property whose backing field a subtype still uses.
			'trivial-getter',
			// naming's cross-file field rename (crossFileFix) resolves an owner's subtype /
			// @:access-grant files through the whole-project index; on the active SUBSET a subtype
			// declared elsewhere reads as absent. Full-scope also re-reports the declaring file's
			// violation every pass, so a rename deferred by a same-file conflict re-fires until it lands.
			'naming',
			// prefer-typed-throw's verdict is whole-scope: a `catch (e:String)` ANYWHERE degrades the
			// rule to report-only. When no resolution scope exists the gate falls back to the file set
			// it is handed, so on the active SUBSET a catch declared elsewhere reads as absent and a
			// throw a first pass correctly refused would be boxed by a later one. Pinned by
			// `CrossScopeSoundnessTest`'s `string-catch` cell (arm
			// `M-TYPEDTHROW-CATCH-REPORT-ONLY`) — the one entry on this list whose gate degrades the
			// RULE rather than a candidate, so its cell carries no in-cell control.
			'prefer-typed-throw',
			// orphan-accessor's every deletion gate is whole-project: the property is resolved through
			// the supertype chain, and the zero-direct-call proof scans every file in report scope. On
			// the active SUBSET a supertype declared elsewhere reads as unresolvable and a call site in
			// an unchanged file reads as absent — the first would silence a real finding, the second
			// would delete a method something still calls.
			'orphan-accessor',
			// unused-public-member's every gate is whole-project: the supertype chain resolution
			// and the reference scan over the whole token map. On the active SUBSET a call site
			// in an unchanged file reads as absent, so `--fix` would delete a method the rest of
			// the project still calls. Its DELETIONS reach the tree through the RiskyFix verifier
			// (which runs the whole set too) rather than this loop. `fullScopeIds` is read ONLY to
			// partition `safeChecks`, which a RiskyFix check never joins (it is not
			// `OracleRelaxable`), so the entry is INERT today — it is kept because it would carry
			// the fixes again if the rule ever stopped being risky.
			'unused-public-member',
			// redundant-isvar's accessor-body, bypass and reflection scans read every file in scope.
			// On the active SUBSET a subclass override in an unchanged file that writes the field
			// reads as absent, and `--fix` would strip the metadata that override needs to compile.
			// The entry acts only WITHOUT an oracle: the rule is `OracleRelaxable`, so that is when it
			// joins the safe loop; with one it is verified as a `RiskyFix` over the whole set.
			'redundant-isvar',
			// inline-constant's reflection gate is the same whole-project string scan its three
			// siblings on this list share (`orphan-accessor` and `unused-public-member` above,
			// `static-constant` below), and it gates the FINDING rather than the fix. On the
			// active SUBSET a `Reflect.field(o, "NAME")` in an unchanged file reads as absent, so a
			// constant pass 1 correctly refused is marked `inline` by pass 2 — on a two-file
			// fixture the whole-set REPORT names one finding and the same command's `--fix` fixes
			// two.
			'inline-constant',
			// static-constant's reachability gates are all whole-project: the subtype MENTION gate
			// (a subtype's unqualified read of a private static does not resolve) and the
			// reflection-name scan over every string literal in scope. On the active SUBSET a
			// subtype or a `Reflect.field(o, "NAME")` in an unchanged file reads as absent, so a
			// later pass would promote a field whose read then fails to compile.
			'static-constant',
			// hoist-common-import weighs the SHARE of a directory's modules that spell a statement. On
			// the active SUBSET the denominator is whatever the last pass rewrote, so the same directory
			// answers a different share each pass and the decision flips under the fixed-point loop.
			'hoist-common-import',
			// scratch-field's reference gates are whole-project like unused-private's: a subtype or an
			// `@:access` grantee MENTIONING the field, and the reflection-name scan over every string literal.
			// On the active subset an unchanged file that spells the name reads as absent.
			'scratch-field'
		];
		return {
			// A `RiskyArm` check keeps its place in the safe loop below (its safe arm declines the
			// findings the risky arm owns) and joins the verified set only when there is an oracle to
			// verify with - without one its risky arm is report-only and the run never mentions it.
			risky: [
				for (c in checks) if ((c is RiskyFix && !relaxableNoOracle(c)) || (oracleConfigured && c is RiskyArm)) c
			],
			safe: safeChecks,
			activeScope: [for (c in safeChecks) if (!fullScopeIds.contains(c.id())) c],
			fullScope: [for (c in safeChecks) if (fullScopeIds.contains(c.id())) c]
		};
	}

	public static function printLintUsage(): Void {
		CliIo.sysPrint('Usage: apq lint <scope...> [options]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Run the analysis checks over the scope (one or more file/dir/glob specs) and\n');
		CliIo.sysPrint('report violations grouped by file as <line>:<col>: [severity] message (rule).\n');
		CliIo.sysPrint('Info advisories are hidden from the TEXT report unless --all; json and\n');
		CliIo.sysPrint('checkstyle always carry every finding, since their stdout is the answer a\n');
		CliIo.sysPrint('machine consumer gets. The exit code is success unless\n');
		CliIo.sysPrint('--fail-on selects a severity present in the findings. Run --list-rules for\n');
		CliIo.sysPrint('the full check list (id + description, one per line).\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Inline suppression: a trailing "// noqa" (or "// noqa: <rule>,<rule>") clears\n');
		CliIo.sysPrint('findings on its line; "// CHECKSTYLE:OFF" ... "// CHECKSTYLE:ON" clears a region.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Project config: an "apq.json" discovered by walking up from a linted file\n');
		CliIo.sysPrint('enables/disables rules and overrides their severity or options, e.g.\n');
		CliIo.sysPrint('{ "rules": { "naming": { "severity": "error" }, "complexity": { "max": 15 },\n');
		CliIo.sysPrint('"fold-adjacent-string-literals": false } }. A rule entry is true / false or an\n');
		CliIo.sysPrint('object of options, which enables the rule unless it says "enabled". A\n');
		CliIo.sysPrint('"categories": { "docs": true } entry switches a whole category, default-off\n');
		CliIo.sysPrint('rules included; a rule entry outranks its category entry.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('A top-level "compilerOracle" key (path to an .hxml, relative to the config)\n');
		CliIo.sysPrint('runs "haxe <hxml> --no-output" as a ground-truth typecheck: a compile error\n');
		CliIo.sysPrint('fails the run, a RiskyFix rule fix is reverted under --fix if it breaks the\n');
		CliIo.sysPrint('build, and an OracleAssisted rule (explicit-local-type, explicit-type) asks a\n');
		CliIo.sysPrint('warm display server for the type of each finding it cannot resolve structurally,\n');
		CliIo.sysPrint('reverting any annotated file that fails to typecheck. Without the key no\n');
		CliIo.sysPrint('compiler is ever spawned.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --rule <id>       Run only this check (repeatable; default: all)\n');
		CliIo.sysPrint('  --category <id>   Run only the rules of this category the config enables\n');
		CliIo.sysPrint('                    (repeatable; not with --rule, which force-runs what it\n');
		CliIo.sysPrint('                    names). With --list-rules, list only that category\n');
		CliIo.sysPrint('  --list-rules      List every registered check and exit. Given a scope, list\n');
		CliIo.sysPrint('                    each rule as on/off for those files instead, one block per\n');
		CliIo.sysPrint('                    distinct apq.json chain (config, default-off and\n');
		CliIo.sysPrint('                    languageVersion resolved); nothing is linted\n');
		CliIo.sysPrint('  --fix            Apply autofixes in place (e.g. delete unused imports)\n');
		CliIo.sysPrint('  --fix-probes <n>  With --fix: the typechecks the safe-pass net may spend in one\n');
		CliIo.sysPrint('                    run isolating the edits that broke the build (default 32);\n');
		CliIo.sysPrint('                    past it the safe pass is reverted whole\n');
		CliIo.sysPrint('  --review-budget <n>  With --fix: the source lines one member-order reorder may\n');
		CliIo.sysPrint('                    move before it is declined as too large to review (default\n');
		CliIo.sysPrint('                    200, or the rule\'s maxRelocatedLines); n replaces it for\n');
		CliIo.sysPrint('                    this run only, and the --fix summary line names it\n');
		CliIo.sysPrint('  --fail-on <sev>   Exit non-zero if a finding at-or-above <sev> exists\n');
		CliIo.sysPrint('                    (error|warning|info)\n');
		CliIo.sysPrint('  --no-oracle       Skip the compiler-oracle typecheck (a PROJECT-WIDE build\n');
		CliIo.sysPrint('                    regardless of scope: 16s of an 18.7s single-file run).\n');
		CliIo.sysPrint('                    Report mode: findings are unchanged, the run just cannot\n');
		CliIo.sysPrint('                    claim compiler-confirmed nullSafety trust. With --fix it\n');
		CliIo.sysPrint('                    ALSO turns off every oracle-backed net, as if no\n');
		CliIo.sysPrint('                    compilerOracle were configured: a fix that breaks the build\n');
		CliIo.sysPrint('                    is NOT reverted, RiskyFix rules stay report-only and\n');
		CliIo.sysPrint('                    OracleAssisted rules are inert. Use it in an iteration loop\n');
		CliIo.sysPrint('                    (the only way to see the fixer raw), NEVER in a gate\n');
		CliIo.sysPrint('  --format <fmt>    Output format: text (default), json, checkstyle; with an\n');
		CliIo.sysPrint('                    unscoped --list-rules, markdown prints the rule index by\n');
		CliIo.sysPrint('                    category and json one {id, category, description,\n');
		CliIo.sysPrint('                    defaultOn, scopeDependent} record per rule\n');
		CliIo.sysPrint('  --all, -a        Include Info-severity advisories in the report (text format only —\n');
		CliIo.sysPrint('                   json and checkstyle are never capped)\n');
		CliIo.sysPrint('  --flat           One <file>:<line>:<col> per line (text format only)\n');
		CliIo.sysPrint('  --full           Always list every finding (text format only)\n');
		CliIo.sysPrint('  --summary        Always print the per-rule summary instead (text format only)\n');
		CliIo.sysPrint('                   Without either, a text report listing more findings than the\n');
		CliIo.sysPrint('                   apq.json reportSummaryThreshold (default 200; 0 = never)\n');
		CliIo.sysPrint('                   prints the summary instead: one line per rule (count, severity,\n');
		CliIo.sysPrint('                   files) sorted by count, each with its top 3 files — a single\n');
		CliIo.sysPrint('                   rule gets its top 10 files one per line. --rule follows the\n');
		CliIo.sysPrint('                   same threshold; json and checkstyle always list everything\n');
		CliIo.sysPrint('  --range <a>:<b>  Only findings whose span STARTS on a line in [a, b], 1-based\n');
		CliIo.sysPrint('                   and inclusive; several windows join with commas (1:4,9:9).\n');
		CliIo.sysPrint('                   The scope must be exactly one file. Narrows\n');
		CliIo.sysPrint('                   the report AND --fix. It narrows FINDINGS, not EDITS: an\n');
		CliIo.sysPrint('                   atomic fix off a finding inside the window still writes\n');
		CliIo.sysPrint('                   wherever its own fix says\n');
		CliIo.sysPrint('  --baseline <p>   Report only the findings the snapshot at <p> does not already\n');
		CliIo.sysPrint('                   carry, then refresh <p> with EVERY finding of this run. The\n');
		CliIo.sysPrint('                   comparison is lint-diff\'s multiset over (file, rule, severity,\n');
		CliIo.sysPrint('                   message) — family/function/subject for a finding carrying\n');
		CliIo.sysPrint('                   data — so an edit that shifts line numbers does not\n');
		CliIo.sysPrint('                   manufacture a delta. It narrows the report, the summary and\n');
		CliIo.sysPrint('                   --fail-on alike; a missing or unreadable <p> reports\n');
		CliIo.sysPrint('                   everything and says so. Refused with --fix\n');
		CliIo.sysPrint('  --explain-long   After the findings, say why thread-safety holds each lock long:\n');
		CliIo.sysPrint('                   per lock every reason (crossing, leak, blind, untraced,\n');
		CliIo.sysPrint('                   unnamed, spans-blocking with the long lock it waits for) at\n');
		CliIo.sysPrint('                   every site, what it is long by once its own\n');
		CliIo.sysPrint('                   reasons are set aside, and the main-thread takes of locks that\n');
		CliIo.sysPrint('                   are not long. With --format json the report becomes the\n');
		CliIo.sysPrint('                   {"findings": [...], "longLocks": {...} | null} envelope (null,\n');
		CliIo.sysPrint('                   with a note, when thread-safety explained nothing). Adds\n');
		CliIo.sysPrint('                   output, never a finding; refused with --fix and checkstyle\n');
		CliIo.sysPrint('  --verbose        Bring back the accounting a quiet run withholds: the --fix\n');
		CliIo.sysPrint('                   rule census (silent on a run that wrote nothing) and the\n');
		CliIo.sysPrint('                   --no-oracle net notice. Adds output, never behaviour\n');
		CliIo.sysPrint('  --lang <name>    Grammar plugin (default: by file extension)\n');
		CliIo.sysPrint('  -h, --help       Show this help\n');
	}

	public static function parseLintArgs(args: Array<String>): LintOpts {
		var lang: String = 'haxe';
		var flat: Bool = false;
		var includeInfo: Bool = false;
		var fix: Bool = false;
		var noOracle: Bool = false;
		var fixProbes: Int = LintFixSafePass.PROBE_CAP;
		var reviewBudget: Null<Int> = null;
		var failOn: Null<Severity> = null;
		var format: String = FORMAT_TEXT;
		final ruleFilters: Array<String> = [];
		final categoryFilters: Array<String> = [];
		final inputSpecs: Array<String> = [];
		var range: Null<LintRange> = null;
		var baseline: Null<String> = null;
		var verbose: Bool = false;
		var explainLong: Bool = false;
		var listRules: Bool = false;
		var summary: Null<Bool> = null;

		for (arg in new LintCommand().flags().walk(args)) {
			final a: String = arg.token;
			switch arg.flag {
				case '--lang':
					lang = arg.value();
				case '--rule':
					ruleFilters.push(arg.value());
				case '--category':
					categoryFilters.push(arg.value());
				case '--all', '-a':
					includeInfo = true;
				case '--flat':
					flat = true;
				case '--fix':
					fix = true;
				case '--no-oracle':
					noOracle = true;
				case '--fix-probes':
					final count: Null<Int> = Std.parseInt(arg.value());
					if (count == null || count < 0) {
						CliIo.stderr('apq lint: --fix-probes expects a count of typechecks, 0 or more\n');
						return lintParseExit(EXIT_USAGE);
					}
					fixProbes = count;
				case '--review-budget':
					final lines: Null<Int> = SourceText.parseStrictInt(arg.value());
					if (lines == null || lines < 1) {
						CliIo.stderr('apq lint: --review-budget expects a number of source lines, 1 or more\n');
						return lintParseExit(EXIT_USAGE);
					}
					reviewBudget = lines;
				case '--verbose':
					verbose = true;
				case '--explain-long':
					explainLong = true;
				case '--full', '--summary':
					final wanted: Bool = a == SUMMARY_FLAG;
					if (summary == !wanted) {
						CliIo.stderr('apq lint: --full and --summary contradict each other — pass one\n');
						return lintParseExit(EXIT_USAGE);
					}
					summary = wanted;
				case '--baseline':
					baseline = arg.value();
				case '--range':
					final spec: String = arg.value();
					range = parseLintRange(spec);
					if (range == null) {
						CliIo.stderr(
							'apq lint: --range expects <from>:<to>[,<from>:<to>…], 1-based inclusive line numbers with from <= to — got "'
							+ '$spec"\n'
						);
						return lintParseExit(EXIT_USAGE);
					}
				case '--fail-on':
					final level: String = arg.value();
					failOn = Severity.fromName(level);
					if (failOn == null) {
						CliIo.stderr('apq lint: unknown --fail-on value "$level" (expected error|warning|info)\n');
						return lintParseExit(EXIT_USAGE);
					}
				case '--format':
					format = arg.value();
					if (![FORMAT_TEXT, FORMAT_JSON, FORMAT_CHECKSTYLE, FORMAT_MARKDOWN].contains(format)) {
						CliIo.stderr(
							'apq lint: unknown --format value "$format'
							+ '" (expected text|json|checkstyle, or markdown with an unscoped --list-rules)\n'
						);
						return lintParseExit(EXIT_USAGE);
					}
				case '-h', '--help':
					printLintUsage();
					return lintParseExit(EXIT_OK);
				case '--list-rules':
					listRules = true;
				case null:
					inputSpecs.push(a);
			}
		}
		// Listing rules is terminal like `--help`, but only once the whole argv is read: the scope
		// that narrows it to effective state may follow the flag.
		final opts: LintOpts = {
			lang: lang,
			flat: flat,
			includeInfo: includeInfo,
			fix: fix,
			noOracle: noOracle,
			fixProbes: fixProbes,
			reviewBudget: reviewBudget,
			failOn: failOn,
			format: format,
			ruleFilters: ruleFilters,
			categoryFilters: categoryFilters,
			inputSpecs: inputSpecs,
			range: range,
			baseline: baseline,
			verbose: verbose,
			explainLong: explainLong,
			summary: summary,
			errExit: null
		};
		final selection: Null<String> = selectionError(opts, listRules);
		if (selection != null) {
			CliIo.stderr('apq lint: $selection\n');
			return lintParseExit(EXIT_USAGE);
		}
		// A machine format is never summarised, so asking for a summary of one is a mistake the run
		// could only honour by ignoring it. `--full` is what such a format does anyway and passes.
		if (explainLong && format == FORMAT_CHECKSTYLE) {
			CliIo.stderr('apq lint: --explain-long has no checkstyle form — use --format text or json\n');
			return lintParseExit(EXIT_USAGE);
		}
		if (summary != true || format == FORMAT_TEXT) return listRules ? lintParseExit(runListRules(opts)) : opts;
		CliIo.stderr('apq lint: --summary applies to the text report — --format $format always lists every finding\n');
		return lintParseExit(EXIT_USAGE);
	}

	/**
	 * The usage error this argv earns for an option it cannot honour, or null when it can.
	 *
	 * Two refusals, both about NARROWING. A `--range` window is a claim about ONE file's lines:
	 * applied to a directory it would narrow every file in it to the same line numbers, which
	 * is not a narrower version of anything the caller asked for. A `--baseline` narrows the
	 * REPORT only, so pairing it with `--fix` would hand the fixer a set the snapshot had already thinned. A `--rule` naming
	 * a rule the scope's grammar never runs is refused too (`foreignRuleError`): its empty report would read as a clean file.
	 *
	 * One function rather than two branches in `runLint` because that function sits AT its
	 * complexity budget — either refusal written inline takes it past the limit — and because
	 * a refusal that reads the whole argv belongs beside its sibling rather than in the middle
	 * of the run.
	 */
	public static function optionScopeError(o: LintOpts, paths: Array<String>, checks: Array<Check>, lang: String): Null<Int> {
		final foreign: Null<Int> = foreignRuleError(o, checks, lang);
		if (foreign != null) return foreign;
		// REFUSED rather than ignored. `--baseline` narrows what the run REPORTS; `--fix` acts on
		// what it FINDS, and a fixer handed a narrowed set would leave every finding the snapshot
		// happens to carry standing while reporting a converged run.
		if (o.baseline != null && o.fix) {
			CliIo.stderr('apq lint: --baseline narrows the REPORT and cannot be combined with --fix (--range narrows both)\n');
			return EXIT_USAGE;
		}
		if (o.reviewBudget != null && !o.fix) {
			CliIo.stderr('apq lint: --review-budget sets the budget of a REORDER and applies to --fix only\n');
			return EXIT_USAGE;
		}
		if (o.explainLong && o.fix) {
			CliIo.stderr('apq lint: --explain-long explains a REPORT and cannot be combined with --fix\n');
			return EXIT_USAGE;
		}
		if (o.range == null || paths.length == 1) return null;
		CliIo.stderr(
			'apq lint: --range needs a scope of exactly one file — ${CliArgs.quotedSpecs(o.inputSpecs)} matched ${paths.length}\n'
		);
		return EXIT_USAGE;
	}

	public static function resolveLintChecks(ruleFilters: Array<String>, categoryFilters: Array<String>): Null<Array<Check>> {
		final checks: Array<Check> = [];
		if (ruleFilters.length == 0) {
			for (check in Linter.builtins()) if (categoryFilters.length == 0 || categoryFilters.contains(check.category()))
				checks.push(check);
		} else {
			for (id in ruleFilters) {
				final check: Null<Check> = Linter.byId(id);
				if (check == null) {
					CliIo.stderr('apq lint: unknown rule "$id"\n');
					return null;
				}
				checks.push(check);
			}
		}
		return checks;
	}

	private static inline function lintParseExit(code: Int): LintOpts {
		return {
			lang: '',
			flat: false,
			includeInfo: false,
			fix: false,
			noOracle: false,
			fixProbes: LintFixSafePass.PROBE_CAP,
			reviewBudget: null,
			failOn: null,
			format: FORMAT_TEXT,
			ruleFilters: [],
			categoryFilters: [],
			inputSpecs: [],
			range: null,
			baseline: null,
			verbose: false,
			explainLong: false,
			summary: null,

			errExit: code
		};
	}

	/**
	 * Why the argv's rule selection cannot be honoured, or null when it can: a `--category` naming no `RuleCategory`,
	 * `--category` beside `--rule` (one narrows to what the config enables, the other force-runs what it names), or the
	 * markdown rule index asked of a lint run.
	 */
	private static function selectionError(o: LintOpts, listRules: Bool): Null<String> {
		final unknown: Null<String> = o.categoryFilters.find(id -> RuleCategory.fromId(id) == null);
		return if (unknown != null)
			'unknown category "$unknown" (expected ${RuleCategory.ALL.join('|')})'
		else if (o.ruleFilters.length > 0 && o.categoryFilters.length > 0)
			'--rule runs the rules it names whatever the config says, --category the enabled rules of a category — pass one'
		else if (o.format == FORMAT_MARKDOWN && !listRules)
			'--format markdown renders the rule index — pass it with --list-rules'
		else
			null;
	}

	/**
	 * `<from>:<to>`, or several of them joined by commas — both ends required, 1-based,
	 * `from <= to`. Null on anything else, and the caller turns that into a usage error
	 * naming the spec it was given.
	 *
	 * Deliberately stricter than `apq source --range`, which clamps to the file and lets
	 * either end be omitted: this one is a FILTER, and a silently clamped window would
	 * narrow a fix run to a region the caller never asked for.
	 *
	 * A raw `Std.parseInt` on each bound parses a leading digit PREFIX and silently drops
	 * trailing garbage, so `--range 1x:2` / `--range 1:2x` would pass while `--range 1,2` (no
	 * colon at all) is caught by the `colon <= 0` guard below. `SourceText.parseStrictInt`
	 * is the shared whole-token digit check `apq source --range` already uses.
	 */
	private static function parseLintRange(spec: String): Null<LintRange> {
		final windows: LintRange = [];
		for (part in spec.split(',')) {
			final colon: Int = part.indexOf(':');
			if (colon <= 0 || colon == part.length - 1) return null;
			final lo: Null<Int> = SourceText.parseStrictInt(part.substring(0, colon));
			if (lo == null) return null;
			final hi: Null<Int> = SourceText.parseStrictInt(part.substring(colon + 1));
			if (hi == null) return null;
			final from: Int = lo;
			final to: Int = hi;
			if (from < 1 || to < from) return null;
			windows.push({ from: from, to: to });
		}
		return windows;
	}

	/**
	 * `EXIT_USAGE`, said on stderr, when `--rule` names a rule the grammar `lang` never runs — answering it with an empty
	 * report would read as a clean file; null otherwise. A `--category` or default selection drops such a rule silently.
	 */
	private static function foreignRuleError(o: LintOpts, checks: Array<Check>, lang: String): Null<Int> {
		if (o.ruleFilters.length == 0) return null;
		for (check in checks) if (check is LanguageBound && !Linter.runsOn(check, lang)) {
			final bound: Array<String> = (cast check: LanguageBound).languages();
			CliIo.stderr('apq lint: rule "${check.id()}" runs on ${bound.join(', ')} only, and this run reads $lang\n');
			return EXIT_USAGE;
		}
		return null;
	}

	/**
	 * `--list-rules`: with no scope, the bare registry, one `<id>  <description>` line per rule, exactly
	 * as before a scope was accepted; with one, `printEffectiveRules`. A flag that only means something
	 * to a lint run is a usage error rather than silently ignored — a listing is not narrowed by `--rule`.
	 */
	private static function runListRules(o: LintOpts): Int {
		final ignored: Null<String> = lintOnlyFlag(o);
		if (ignored != null) {
			CliIo.stderr('apq lint: --list-rules takes only a scope, --category and --lang — $ignored applies to a lint run\n');
			return EXIT_USAGE;
		}
		final checks: Array<Check> = resolveLintChecks([], o.categoryFilters) ?? [];
		if (o.inputSpecs.length > 0) return printEffectiveRules(o.lang, o.inputSpecs, checks);
		if (o.format != FORMAT_TEXT) {
			CliIo.sysPrint(o.format == FORMAT_MARKDOWN ? RuleIndex.markdown(checks) : RuleIndex.json(checks));
			return EXIT_OK;
		}
		var width: Int = 0;
		for (c in checks) if (c.id().length > width) width = c.id().length;

		// The minimum language version a rule's FIX needs is printed with the rule, not
		// discovered after a run that silently dropped it: a project whose `languageVersion`
		// is below it never sees the finding, and this is where that becomes visible.
		for (c in checks) {
			final requires: String = c is VersionGated ? ' [needs ${(cast c: VersionGated).minLanguageVersion()}]' : '';
			final bound: String = c is LanguageBound ? ' [${RuleIndex.languageOf(c)} only]' : '';
			CliIo.sysPrint('${c.id().rpad(' ', width)}  ${c.description()}$requires$bound\n');
		}
		return EXIT_OK;
	}

	/**
	 * `--list-rules <scope>`: every registered rule with the state a lint of the scope's files would run
	 * it in, as `EffectiveRules.render` lays it out. The registry alone is an upper bound; configs are
	 * resolved exactly as a lint run resolves them, and nothing is parsed or linted.
	 */
	private static function printEffectiveRules(lang: String, inputSpecs: Array<String>, checks: Array<Check>): Int {
		final io: ResolvedInputs = CliArgs.resolveInputPaths(lang, inputSpecs);
		final paths: Array<String> = io.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq lint: ${CliArgs.noFilesMatched(lang, inputSpecs)}\n');
			return EXIT_RUNTIME;
		}
		// A rule the scope's grammar never runs is no state of this scope's lint: it is left out, as a run leaves it out.
		for (path in paths) OracleProviders.reportDrops(LintConfig.discover(path), io.plugin);
		final runs: Array<Check> = checks.filter(c -> Linter.runsOn(c, io.plugin.langName()));
		CliIo.sysPrint(EffectiveRules.render(EffectiveRules.resolve(paths, runs)));
		return EXIT_OK;
	}

	/** The first lint-run flag `o` carries, as the user spelled it, or null when there is none. */
	private static function lintOnlyFlag(o: LintOpts): Null<String> {
		final given: Array<{ flag: String, set: Bool }> = [
			{ flag: '--rule', set: o.ruleFilters.length > 0 },
			{ flag: '--fix', set: o.fix },
			{ flag: '--review-budget', set: o.reviewBudget != null },
			{ flag: '--all', set: o.includeInfo },
			{ flag: '--flat', set: o.flat },
			{ flag: '--no-oracle', set: o.noOracle },
			{ flag: '--fail-on', set: o.failOn != null },
			{
				flag: '--format',
				set: o.format != FORMAT_TEXT && (![FORMAT_MARKDOWN, FORMAT_JSON].contains(o.format) || o.inputSpecs.length != 0)
			},
			{ flag: '--range', set: o.range != null },
			{ flag: '--baseline', set: o.baseline != null },
			{ flag: '--verbose', set: o.verbose },
			{ flag: '--explain-long', set: o.explainLong },
			{ flag: o.summary == true ? SUMMARY_FLAG : '--full', set: o.summary != null }
		];
		return given.find(g -> g.set)?.flag;
	}

}
