package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;

using Lambda;

import anyparse.query.CachingGrammarPlugin;
import anyparse.check.SimplifyBooleanTernary;
import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;

/**
 * Runs a set of `Check`s over a file set and concatenates their
 * violations. Doubles as the built-in check registry: `builtins()` is the
 * default check set the `lint` CLI runs, and `byId` resolves a `--rule`
 * selection against it. A second registry abstraction is deliberately not
 * introduced — there is one check today and the registry is a one-line
 * factory; it grows into a richer form only when a real config / plugin
 * source of checks exists.
 */
@:nullSafety(Strict)
final class Linter {

	/**
	 * The default check set. New built-in checks are appended here; a
	 * grammar-specific check registers by being added alongside the
	 * generic ones (the `Check` contract is language-agnostic — it
	 * receives the plugin).
	 */
	public static function builtins(): Array<Check> {
		return [
			new UnusedImport(),
			new UnusedLocal(),
			new DuplicateImport(),
			new Naming(),
			new UnusedPrivate(),
			new Complexity(),
			new FoldStringLiterals(),
			new DeadCode(),
			new IfFalseDeadCode(),
			new EmptyBlock(),
			new IdenticalOperands(),
			new SelfAssignment(),
			new DuplicateCase(),
			new RedundantParens(),
			new ConstantCondition(),
			new EmptyStatement(),
			new RedundantElse(),
			new ComparisonToBoolean(),
			new CollapsibleIf(),
			new CollapsibleElseIf(),
			new DoubleNegation(),
			new InvertNegatedIfElse(),
			new PreferNullCoalescing(),
			new PreferArrayLiteral(),
			new PreferMapLiteral(),
			new PreferInterpolation(),
			new PreferFinal(),
			new SimplifyBooleanReturnChain(),
			new PreferTernaryReturn(),
			new PreferTernaryAssignment(),
			new PreferIfExpressionReturn(),
			new PreferIfExpressionAssignment(),
			new JoinDeclarationAssignment(),
			new JoinReturn(),
			new PreferSingleQuotes(),
			new SimplifyBooleanTernary(),
			new AssignmentInCondition(),
			new DuplicateTernaryBranches(),
			new PreferBind(),
			new RedundantMapIterKey(),
			new UnusedParameter(),
			new SwallowedException(),
			new PreferSwitch(),
			new MissingVisibility(),
			new ModifierOrder(),
			new MemberOrder(),
			new FragmentedDocComment(),
			new ExplicitType(),
			new PreferFinalField(),
			new PreferFinalPublicField(),
			new PreferReadOnlyField(),
			new UnnecessaryBlock(),
			new RedundantVoidReturn(),
			new MagicNumber(),
			new PreferEnumAbstract(),
			new RedundantThis(),
			new UnnecessaryNullCheck(),
			new RedundantCast(),
			new RedundantNullCoalescing(),
			new UnnecessarySafeNav(),
			new RedundantIsCheck(),
			new ImpossibleIsCheck(),
			new UnreachableCatch(),
			new ImpossibleCast(),
			new RedundantUpcast(),
			new DeadNullGuard(),
			new DeadNullCoalescing(),
			new DeadSafeNav(),
			new AlwaysNullComparison(),
			new NullDereference(),
			new DeadStore(),
			new ThreadSafety(),
			new UncheckedNullable(),
			new PossibleNullDereference(),
			new UnguardedNullableDeref(),
			new OversizedType(),
			new PreferIndexAccess(),
			new CatchDynamic(),
			new PreferCaseWildcard(),
			new OptionalParamShorthand(),
			new PreferFinalClass(),
			new PreferSafeNav(),
			new EnglishComments(),
			new PreferComprehension(),
			new PreferFind(),
			new LoopGuard(),
			new GuardContinue(),
			new MapKeysLookup(),
			new PreferRangeLoop(),
			new TrivialGetter(),
			new NullableSwitchMissingNull(),
			new DuplicateCode(),
			new ListenerSymmetry(),
			new StringLiteralDup(),
			new AvoidDynamic(),
			new UnusedReturnValue(),
			new DocCoverage(),
			new ExplicitLocalType(),
			new RedundantBypassAccessor(),
			new FieldInitAtDeclaration()
		];
	}

	/** The built-in check whose `id()` equals `id`, or null. */
	public static function byId(id: String): Null<Check> {
		return builtins().find(c -> c.id() == id);
	}

	/**
	 * Run each check in `checks` (default: `builtins()`) over `files` and
	 * return all violations, check by check in registry order. A check
	 * must be skip-parse tolerant (see `Check`); the linter does not catch
	 * per-check exceptions. `ConfigAware` checks receive `resolveConfig`
	 * (or null) before running, so they read their per-file options through it.
	 *
	 * `resolveConfig` maps a file path to the `apqlint.json` in effect there
	 * (walk-up discovered, per-directory memoised by the caller): each finding
	 * is remapped to its own file's configured severity, and — ONLY when
	 * `applyEnablement` is true — DROPPED when that file disables its rule. A
	 * null resolver leaves every finding untouched.
	 *
	 * `applyEnablement` defaults to FALSE: a programmatic caller passing a
	 * resolver for severity/options is NOT silently robbed of findings whose
	 * rule a config disables (the trap when it defaulted true) — matching
	 * `--rule` semantics, where an explicitly selected check runs regardless
	 * of `enabled`. The CLI's non-`--rule` path passes true explicitly to keep
	 * config-disabled rules out of a full report.
	 */
	public static function run(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?checks: Array<Check>,
		?resolveConfig: (String) -> LintConfig, applyEnablement: Bool = false
	): Array<Violation> {
		final active: Array<Check> = checks ?? builtins();
		// A DefaultOff rule is excluded from the default set: its finding survives only
		// when the file explicitly opts in (`enabled:true`) — the inverse default the
		// per-file enablement gate below applies via `enabledFor`'s `defaultOn`.
		final defaultOffIds: Array<String> = [for (c in active) if (c is DefaultOff) c.id()];
		// Parse each file once and share the trees across all checks — each check
		// parses independently otherwise, so N checks over M files is N*M parses.
		final cached: GrammarPlugin = plugin is CachingGrammarPlugin ? plugin : new CachingGrammarPlugin(plugin);
		// Thread the caller's memoised per-file config resolver into the option-reading
		// checks so they don't re-walk ancestor dirs + re-parse the JSON per file; a null
		// resolver resets them to their own `LintConfig.discover` fallback.
		for (check in active) if (check is ConfigAware) (cast check: ConfigAware).setConfigResolver(resolveConfig);
		final out: Array<Violation> = [for (check in active) for (violation in check.run(files, cached)) violation];
		if (resolveConfig == null) return Suppression.apply(out, files);
		// Per-file config: resolve the apqlint.json for each finding's OWN file, drop
		// it when its rule is disabled there (unless an explicit --rule selection
		// bypasses enablement), then apply that file's severity override.
		final kept: Array<Violation> = [];
		for (violation in out) {
			final config: LintConfig = resolveConfig(violation.file);
			if (!(!applyEnablement || config.enabledFor(violation.rule, !defaultOffIds.contains(violation.rule)))) continue;
			final sev: Null<Severity> = config.severityFor(violation.rule);
			if (sev != null) violation.severity = sev;
			kept.push(violation);
		}
		return Suppression.apply(kept, files);
	}

}
