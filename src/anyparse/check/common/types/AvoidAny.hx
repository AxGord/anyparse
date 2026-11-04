package anyparse.check.common.types;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FileGated;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.NoAutofix;
import anyparse.check.common.types.DynamicShape.DynCtx;
import anyparse.check.common.types.DynamicShape.DynPos;
import anyparse.check.common.types.DynamicShape.DynReport;
import anyparse.query.ParseGate;
import anyparse.query.SymbolIndex;

/**
 * Flags `Any` in a DECLARED type position — a field type, a parameter or return type, a generic type argument or an
 * annotated local — through the walk `avoid-dynamic` runs for `Dynamic`, so the two rules share what a declared
 * position is and read the same `excludePaths` / `excludeMeta` options. `Any` is the safe top type, so a finding is
 * not an error: it asks whether a narrower type exists. A value from a JSON document is the usual one, and the
 * message names the way: a schema typedef of the JSON grammar with its generated parser.
 *
 * A seam that must hold any value (a generic container's payload, a macro value, a reflection result) is the
 * declared exception: a file or a declaration carrying one is left out with `excludePaths` / `excludeMeta`.
 * Off by default; report-only.
 */
@:nullSafety(Strict)
final class AvoidAny extends RuleBase implements ConfigAware implements FileGated implements NoAutofix implements DefaultOff {

	private static inline final RULE_ID: String = 'avoid-any';
	private static inline final ADVICE: String = ' — name the narrower type; a value read from a JSON document is read through a '
		+ 'schema typedef of the JSON grammar and its generated parser';

	/** The identity and wording this rule's findings carry. */
	private static final REPORT: DynReport = { rule: RULE_ID, message: (position: DynPos, _: Bool) -> 'Any ${where(position)}$ADVICE' };

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(RULE_ID, 'Any in a declared type position (field, parameter, return, type argument, or annotated local)', RuleCategory.Types);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final topName: Null<String> = shape.topTypeName;
		if (topName == null) return [];
		final ctx: DynCtx = DynamicShape.buildCtx(shape, topName, plugin.typeSyntax, REPORT);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final cfg: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
			final excludeMeta: Array<String> = cfg.stringListOption(RULE_ID, 'excludeMeta') ?? [];
			for (v in AvoidDynamic.scanDeclared(entry, tree, plugin, ctx, excludeMeta, [])) violations.push(v);
		}
		return violations;
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'the narrower type is the author\'s choice';
	}

	/** `config-excluded` for a file whose path contains an `excludePaths` entry. */
	public function skipReason(file: String, config: LintConfig): Null<String> {
		return AvoidDynamic.pathExcluded(file, config.stringListOption(RULE_ID, 'excludePaths') ?? []) ? 'config-excluded' : null;
	}

	private static function where(position: DynPos): String {
		return switch position {
			case Field: 'field type';
			case Param: 'parameter type';
			case Return: 'return type';
			case TypeArg: 'type argument';
			case Local: 'local variable type';
		};
	}

}
