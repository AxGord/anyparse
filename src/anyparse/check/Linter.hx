package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;

using Lambda;

import anyparse.query.CachingGrammarPlugin;
import anyparse.check.SimplifyBooleanTernary;

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
			new DoubleNegation(),
			new PreferNullCoalescing(),
			new PreferArrayLiteral(),
			new PreferMapLiteral(),
			new PreferInterpolation(),
			new PreferFinal(),
			new SimplifyBooleanReturnChain(),
			new PreferTernaryReturn(),
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
			new RedundantThis()
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
	 * per-check exceptions.
	 */
	public static function run(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?checks: Array<Check>, ?config: LintConfig
	): Array<Violation> {
		final active: Array<Check> = checks ?? builtins();
		// Parse each file once and share the trees across all checks — each check
		// parses independently otherwise, so N checks over M files is N*M parses.
		final cached: GrammarPlugin = plugin is CachingGrammarPlugin ? plugin : new CachingGrammarPlugin(plugin);
		final out: Array<Violation> = [];
		for (check in active) for (violation in check.run(files, cached)) out.push(violation);
		if (config != null) for (violation in out) {
			final sev: Null<Severity> = config.severityFor(violation.rule);
			if (sev != null) violation.severity = sev;
		}
		return Suppression.apply(out, files);
	}

}
