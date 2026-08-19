package anyparse.grammar.haxe;

import anyparse.grammar.haxe.checkstyle.CheckstyleCheck;
import anyparse.grammar.haxe.checkstyle.CheckstyleCheckProps;
import anyparse.grammar.haxe.checkstyle.CheckstyleConfig;
import anyparse.grammar.haxe.checkstyle.CheckstyleConfigParser;
import anyparse.grammar.haxe.checkstyle.CheckstyleThreshold;
import anyparse.query.GrammarPlugin.CheckOverrides;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingPolicy;

using Lambda;

/**
 * Adapts an existing haxe-checkstyle `checkstyle.json` onto the neutral
 * `NamingPolicy`, exactly as `HaxeFormatConfigLoader` adapts an `hxformat.json`
 * onto the writer's options — maximum compatibility with a config a project
 * already ships, NOT a re-implementation of checkstyle.
 *
 * The JSON is read through the declared `CheckstyleConfig` schema and its
 * macro-generated `CheckstyleConfigParser` — the same typed route
 * `hxformat.json` takes. Keys the schema does not model are dropped by the
 * `UnknownPolicy.Skip` inherited from `JsonFormat`, so a full checkstyle
 * config loads fine; a key it DOES model but whose value carries the wrong
 * type is a parse error, and the caller falls back wholesale.
 *
 * Only the naming-family checks are mapped (`TypeName`, `MemberName`,
 * `MethodName`, …); every other check `type` is ignored — that is the
 * "not a clone" boundary. Each mapped check contributes one rule keyed on its
 * `props.format` regex; a check that is not naming-family, or that carries no
 * `format`, is skipped. A valid config that configured no naming checks simply
 * yields an empty policy (naming disabled for that project), which the caller
 * distinguishes from a malformed file (a thrown `CheckstyleConfigParser.parse`)
 * that falls back to the built-in default.
 */
@:nullSafety(Strict)
final class CheckstyleConfigLoader {

	/**
	 * Parse `jsonContent` (a `checkstyle.json`) and map its naming-family
	 * checks to a `NamingPolicy`. Throws whatever `CheckstyleConfigParser.parse`
	 * throws on malformed input — the caller catches and falls back to the
	 * default.
	 */
	public static function load(jsonContent: String): NamingPolicy {
		final config: CheckstyleConfig = CheckstyleConfigParser.parse(jsonContent);
		final policy: NamingPolicy = [];
		final checks: Null<Array<CheckstyleCheck>> = config.checks;
		if (checks == null) return policy;
		for (check in checks) {
			final type: Null<String> = check.type;
			if (type == null) continue;
			final category: Null<NamingCategory> = categoryOf(type);
			if (category == null) continue;
			final format: Null<String> = check.props?.format;
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
	 * own default warning onset. Throws whatever `CheckstyleConfigParser.parse`
	 * throws on malformed input — the caller catches and falls back.
	 */
	public static function loadComplexityMax(jsonContent: String): Null<Int> {
		final config: CheckstyleConfig = CheckstyleConfigParser.parse(jsonContent);
		final checks: Null<Array<CheckstyleCheck>> = config.checks;
		if (checks == null) return null;
		final check: Null<CheckstyleCheck> = checks.find(c -> c.type == 'CyclomaticComplexity');
		if (check == null) return null;
		// checkstyle's own default warning onset when the check lists no thresholds.
		final defaultWarningOnset: Int = 20;
		var onset: Int = defaultWarningOnset;
		final thresholds: Null<Array<CheckstyleThreshold>> = check.props?.thresholds;
		if (thresholds != null && thresholds.length > 0) {
			var lowest: Int = -1;
			for (threshold in thresholds) if (threshold.severity != 'IGNORE') {
				final complexity: Int = Std.int(threshold.complexity ?? 0);
				if (lowest < 0 || complexity < lowest) lowest = complexity;
			}
			if (lowest > 0) onset = lowest;
		}
		return onset - 1;
	}

	/**
	 * Map a `checkstyle.json` onto the neutral `CheckOverrides` the checks read.
	 * One pass over `checks`; each recognised `type` fills its field, applying
	 * checkstyle's own default when the check is present but omits the option.
	 * Throws whatever `CheckstyleConfigParser.parse` throws on malformed input —
	 * the caller catches and falls back to no overrides.
	 */
	public static function loadOverrides(jsonContent: String): CheckOverrides {
		final config: CheckstyleConfig = CheckstyleConfigParser.parse(jsonContent);
		final overrides: CheckOverrides = {};
		final checks: Null<Array<CheckstyleCheck>> = config.checks;
		if (checks == null) return overrides;
		for (check in checks) {
			final type: Null<String> = check.type;
			if (type == null) continue;
			final props: Null<CheckstyleCheckProps> = check.props;
			switch type {
				case 'MagicNumber':
					overrides.magicNumberIgnore = props?.ignoreNumbers ?? [-1, 0, 1, 2];
				case 'UnusedImport':
					overrides.unusedImportIgnoreModules = props?.ignoreModules ?? [];
				case 'ModifierOrder':
					overrides.modifierOrder = modifierOrder(props?.modifiers);
				case 'StringLiteral':
					overrides.preferSingleQuotesEnabled = singleQuotesEnabled(props?.policy);
				case 'Type':
					overrides.explicitTypeIgnoreEnumAbstract = props?.ignoreEnumAbstractValues ?? true;
				case 'EmptyBlock':
					overrides.emptyBlockEnabled = emptyBlockEnabled(props?.option);
				case _:
			}
		}
		return overrides;
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

	/**
	 * checkstyle `ModifierOrder.modifiers` (UPPER_SNAKE) mapped to our RefShape
	 * modifier kinds; the modifiers our `modifier-order` check does not rank
	 * (MACRO / DYNAMIC / EXTERN / …) are dropped. Absent → checkstyle's
	 * own default order.
	 */
	private static function modifierOrder(modifiers: Null<Array<String>>): Array<String> {
		final tokens: Array<String> = modifiers ?? ['MACRO', 'OVERRIDE', 'PUBLIC_PRIVATE', 'STATIC', 'INLINE', 'DYNAMIC', 'FINAL'];
		final order: Array<String> = [];
		for (token in tokens) switch token {
			case 'OVERRIDE':
				order.push('Override');
			case 'PUBLIC_PRIVATE':
				order.push('Public');
				order.push('Private');
			case 'STATIC':
				order.push('Static');
			case 'INLINE':
				order.push('Inline');
			case 'FINAL':
				order.push('Final');
			case _:
		}
		return order;
	}

	/**
	 * `prefer-single-quotes` is active only when checkstyle `StringLiteral.policy`
	 * enforces single quotes; the default and any double-preferring policy turn it
	 * off. Matched leniently by substring so the exact enum casing does not matter.
	 */
	private static function singleQuotesEnabled(policy: Null<String>): Bool {
		final p: String = policy?.toLowerCase() ?? '';
		return p.indexOf('single') >= 0 && p.indexOf('double') < 0;
	}

	/**
	 * `empty-block` is active only when checkstyle `EmptyBlock.option` demands
	 * content (`text` / `stmt`); the default `empty` (allow empty blocks) turns it
	 * off. Lenient substring match.
	 */
	private static function emptyBlockEnabled(option: Null<String>): Bool {
		final o: String = option?.toLowerCase() ?? '';
		return o.indexOf('text') >= 0 || o.indexOf('stmt') >= 0;
	}

}
