package anyparse.grammar.haxe;

import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingPolicy;
import haxe.Json;

using Lambda;

/**
 * Adapts an existing haxe-checkstyle `checkstyle.json` onto the neutral
 * `NamingPolicy`, exactly as `HaxeFormatConfigLoader` adapts an `hxformat.json`
 * onto the writer's options — maximum compatibility with a config a project
 * already ships, NOT a re-implementation of checkstyle.
 *
 * Only the naming-family checks are mapped (`TypeName`, `MemberName`,
 * `MethodName`, …); every other check `type` is ignored — that is the
 * "not a clone" boundary. Each mapped check contributes one rule keyed on its
 * `props.format` regex; a check that is not naming-family, or that carries no
 * `format`, is skipped. A valid config that configured no naming checks simply
 * yields an empty policy (naming disabled for that project), which the caller
 * distinguishes from a malformed file (a thrown `Json.parse`) that falls back
 * to the built-in default.
 */
@:nullSafety(Strict)
final class CheckstyleConfigLoader {

	/**
	 * Parse `jsonContent` (a `checkstyle.json`) and map its naming-family
	 * checks to a `NamingPolicy`. Throws whatever `Json.parse` throws on
	 * malformed input — the caller catches and falls back to the default.
	 */
	public static function load(jsonContent: String): NamingPolicy {
		final root: Dynamic = Json.parse(jsonContent);
		final checks: Null<Array<Dynamic>> = root.checks;
		final policy: NamingPolicy = [];
		if (checks == null) return policy;
		for (check in checks) {
			final type: Null<String> = check.type;
			if (type == null) continue;
			final category: Null<NamingCategory> = categoryOf(type);
			if (category == null) continue;
			final props: Dynamic = check.props;
			final format: Null<String> = props != null ? props.format : null;
			if (format == null) continue;
			// Re-bind to non-null finals: strict null-safety does not narrow a
			// guarded local inside an anonymous struct literal.
			final categoryValue: NamingCategory = category;
			final label: String = type;
			policy.push({
				category: categoryValue,
				requireMods: [],
				forbidMods: [],
				format: new EReg(format, ''),
				label: label
			});
		}
		return policy;
	}

	/**
	 * Parse `jsonContent` and return the maximum cyclomatic complexity a
	 * function may have before the `complexity` check flags it — mapped from the
	 * config's `CyclomaticComplexity` thresholds — or null when the config does
	 * not configure that check (the check then keeps its built-in default).
	 *
	 * checkstyle flags a function whose complexity is `>=` the lowest configured
	 * threshold; this check flags `>` its max, so the returned max is that onset
	 * minus one. A configured check with no explicit thresholds uses checkstyle's
	 * own default warning onset. Throws whatever `Json.parse` throws on malformed
	 * input — the caller catches and falls back.
	 */
	public static function loadComplexityMax(jsonContent: String): Null<Int> {
		final root: Dynamic = Json.parse(jsonContent);
		final checks: Null<Array<Dynamic>> = root.checks;
		if (checks == null) return null;
		final check: Null<Dynamic> = checks.find(c -> c.type == 'CyclomaticComplexity');
		if (check == null) return null;
		// checkstyle's own default warning onset when the check lists no thresholds.
		final defaultWarningOnset: Int = 20;
		var onset: Int = defaultWarningOnset;
		final props: Dynamic = check.props;
		final thresholds: Null<Array<Dynamic>> = props != null ? props.thresholds : null;
		if (thresholds != null && thresholds.length > 0) {
			var lowest: Int = -1;
			for (threshold in thresholds) if (threshold.severity != 'IGNORE') {
				final complexity: Int = Std.int(threshold.complexity);
				if (lowest < 0 || complexity < lowest) lowest = complexity;
			}
			if (lowest > 0) onset = lowest;
		}
		return onset - 1;
	}

	/** Map a checkstyle naming-check `type` to a neutral category, or null if not naming-family. */
	private static function categoryOf(type: String): Null<NamingCategory> {
		return switch type {
			case 'TypeName': NamingCategory.Type;
			case 'MemberName': NamingCategory.Field;
			case 'MethodName': NamingCategory.Method;
			case 'ConstantName': NamingCategory.Constant;
			case 'LocalVariableName': NamingCategory.Local;
			case 'ParameterName': NamingCategory.Param;
			case 'EnumValueName': NamingCategory.EnumValue;
			case 'CatchParameterName': NamingCategory.CatchVar;
			case _: null;
		}
	}

}
