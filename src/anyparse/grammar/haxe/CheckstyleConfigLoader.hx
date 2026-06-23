package anyparse.grammar.haxe;

import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingPolicy;
import haxe.Json;

using Lambda;

import anyparse.query.GrammarPlugin.CheckOverrides;

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

	/**
	 * Map a `checkstyle.json` onto the neutral `CheckOverrides` the checks read.
	 * One pass over `checks`; each recognised `type` fills its field, applying
	 * checkstyle's own default when the check is present but omits the option.
	 * Throws whatever `Json.parse` throws on malformed input — the caller catches
	 * and falls back to no overrides.
	 */
	public static function loadOverrides(jsonContent: String): CheckOverrides {
		final root: Dynamic = Json.parse(jsonContent);
		final overrides: CheckOverrides = {};
		final checksRaw: Dynamic = Reflect.field(root, 'checks');
		if (!(checksRaw is Array)) return overrides;
		final checks: Array<Dynamic> = checksRaw;
		for (check in checks) {
			final type: Dynamic = Reflect.field(check, 'type');
			if (!(type is String)) continue;
			final props: Dynamic = Reflect.field(check, 'props');
			switch (type: String) {
				case 'MagicNumber':
					overrides.magicNumberIgnore = readFloatList(props, 'ignoreNumbers', [-1, 0, 1, 2]);
				case 'UnusedImport':
					overrides.unusedImportIgnoreModules = readStringList(props, 'ignoreModules');
				case 'ModifierOrder':
					overrides.modifierOrder = readModifierOrder(props);
				case 'StringLiteral':
					overrides.preferSingleQuotesEnabled = readSingleQuotesEnabled(props);
				case 'Type':
					overrides.explicitTypeIgnoreEnumAbstract = readBool(props, 'ignoreEnumAbstractValues', true);
				case 'EmptyBlock':
					overrides.emptyBlockEnabled = readEmptyBlockEnabled(props);
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

	/** A numeric-array prop, or `fallback` when the prop is absent or not an array. */
	private static function readFloatList(props: Dynamic, key: String, fallback: Array<Float>): Array<Float> {
		final raw: Dynamic = props != null ? Reflect.field(props, key) : null;
		if (!(raw is Array)) return fallback;
		final arr: Array<Dynamic> = raw;
		return [for (n in arr) if (n is Int || n is Float) (n: Float)];
	}

	/** A string-array prop, or `[]` when absent or not an array. */
	private static function readStringList(props: Dynamic, key: String): Array<String> {
		final raw: Dynamic = props != null ? Reflect.field(props, key) : null;
		if (!(raw is Array)) return [];
		final arr: Array<Dynamic> = raw;
		return [for (s in arr) if (s is String) (s: String)];
	}

	/** A bool prop, or `fallback` when absent or not a bool. */
	private static function readBool(props: Dynamic, key: String, fallback: Bool): Bool {
		final v: Dynamic = props != null ? Reflect.field(props, key) : null;
		return v is Bool ? (v: Bool) : fallback;
	}

	/**
	 * checkstyle `ModifierOrder.modifiers` (UPPER_SNAKE) mapped to our RefShape
	 * modifier kinds; the modifiers our `modifier-order` check does not rank
	 * (MACRO / DYNAMIC / FINAL / EXTERN / …) are dropped. Absent → checkstyle's
	 * own default order.
	 */
	private static function readModifierOrder(props: Dynamic): Array<String> {
		final raw: Dynamic = props != null ? Reflect.field(props, 'modifiers') : null;
		final tokens: Array<Dynamic> = raw is Array ? raw : ['MACRO', 'OVERRIDE', 'PUBLIC_PRIVATE', 'STATIC', 'INLINE', 'DYNAMIC', 'FINAL'];
		final order: Array<String> = [];
		for (t in tokens) if (t is String) switch (t: String) {
			case 'OVERRIDE':
				order.push('Override');
			case 'PUBLIC_PRIVATE':
				order.push('Public');
				order.push('Private');
			case 'STATIC':
				order.push('Static');
			case 'INLINE':
				order.push('Inline');
			case _:
		}
		return order;
	}

	/**
	 * `prefer-single-quotes` is active only when checkstyle `StringLiteral.policy`
	 * enforces single quotes; the default and any double-preferring policy turn it
	 * off. Matched leniently by substring so the exact enum casing does not matter.
	 */
	private static function readSingleQuotesEnabled(props: Dynamic): Bool {
		final v: Dynamic = props != null ? Reflect.field(props, 'policy') : null;
		if (!(v is String)) return false;
		final p: String = (v: String).toLowerCase();
		return p.indexOf('single') >= 0 && p.indexOf('double') < 0;
	}

	/**
	 * `empty-block` is active only when checkstyle `EmptyBlock.option` demands
	 * content (`text` / `stmt`); the default `empty` (allow empty blocks) turns it
	 * off. Lenient substring match.
	 */
	private static function readEmptyBlockEnabled(props: Dynamic): Bool {
		final v: Dynamic = props != null ? Reflect.field(props, 'option') : null;
		if (!(v is String)) return false;
		final o: String = (v: String).toLowerCase();
		return o.indexOf('text') >= 0 || o.indexOf('stmt') >= 0;
	}

}
