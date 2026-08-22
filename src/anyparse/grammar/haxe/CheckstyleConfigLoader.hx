package anyparse.grammar.haxe;

import anyparse.grammar.haxe.checkstyle.CheckstyleCheck;
import anyparse.grammar.haxe.checkstyle.CheckstyleCheckProps;
import anyparse.grammar.haxe.checkstyle.CheckstyleConfig;
import anyparse.grammar.haxe.checkstyle.CheckstyleConfigParser;
import anyparse.grammar.haxe.checkstyle.CheckstyleThreshold;
import anyparse.query.GrammarPlugin.CheckOverrides;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.query.NamingPolicy.NamingRule;

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
 * "not a clone" boundary. A mapped check contributes its `props.format` regex as one or
 * more rules, narrowed by whatever of its `props.tokens` this model can
 * express — `rulesOf` carries what that is, and what it is not; a check that is
 * not naming-family, or that carries no `format`, is skipped. A rule also
 * carries the AUTOFIX its check cannot state: checkstyle declares a format and
 * no correction, so `HaxeNamingSupport.normalizerFor` decides, per category,
 * which of the grammar's own built-in corrections a config-derived rule may
 * use (see `ruleFor`). A valid config that configured no naming checks simply
 * yields an empty policy (naming disabled for that project), which the caller
 * distinguishes from a malformed file (a thrown `CheckstyleConfigParser.parse`)
 * that falls back to the built-in default.
 */
@:nullSafety(Strict)
final class CheckstyleConfigLoader {

	/**
	 * The `MemberName` tokens that ask for a FIELD rule. `ENUM` is the one that does not — it selects
	 * enum constructors, a different category — so a config stating only `ENUM` contributes no field
	 * rule at all, exactly as `MemberNameCheck.checkClassType` / `checkAbstractType` /
	 * `checkTypedefType` all return for it.
	 */
	private static final MEMBER_FIELD_TOKENS: Array<String> = ['CLASS', 'ABSTRACT', 'TYPEDEF', 'PUBLIC', 'PRIVATE'];

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
			final format: Null<String> = check.props?.format;
			if (format == null) continue;
			// checkstyle's own default is TRUE: a check that states no `ignoreExtern` still skips a
			// declaration inside an `extern` type, so reading the absent key as `false` would make this
			// adapter STRICTER than every config that never mentions it.
			for (rule in rulesOf(type, format, check.props?.tokens ?? [], check.props?.ignoreExtern ?? true)) policy.push(rule);
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

	/**
	 * checkstyle's visibility pair, read the same way by `MemberNameCheck.checkField` and
	 * `MethodNameCheck.checkField`.
	 *
	 * `PRIVATE` becomes a `forbidMods` entry for `public` rather than a `requireMods` entry for
	 * `private`, and that is not a stylistic choice: a Haxe declaration carrying no visibility
	 * keyword IS private, and the projection writes no modifier for it, so the token has to read as
	 * "not public" or it would select only the members that say so out loud.
	 */
	private static inline function visibilityPair(tokens: Array<String>, requireMods: Array<String>, forbidMods: Array<String>): Void {
		pair(tokens, 'PUBLIC', 'PRIVATE', 'public', requireMods, forbidMods);
	}

	/**
	 * The rules ONE checkstyle naming check contributes: its neutral category, narrowed by whatever
	 * of its `tokens` this model can express. Empty for a check that is not naming-family — the "not
	 * a clone" boundary — and a LIST because `MemberName` is two questions written as one entry.
	 *
	 * `tokens` used to be dropped, and dropping it does not merely widen a rule, it can KILL one. A
	 * project configuring `MemberName` twice — `['CLASS', 'PUBLIC', 'PRIVATE', 'TYPEDEF']` and
	 * `['ENUM']`, different regexes — got two rules of the same category with the same empty
	 * selector, and `applicableRule` takes the FIRST that matches: the `ENUM` rule could never apply
	 * to anything. The autofix half is worse. `MemberNameCheck.checkField` returns on `f.isStatic(p)`
	 * before it matches anything, so a `public static var CACHE_FILE` is not a member name to that
	 * check at all; reading it as one produced 55 of an 851-file tree's 231 findings, and every one of
	 * them would have been RENAMED the moment a normalizer was attached — `ENVKEY` to `_envkey`,
	 * against a format its project wrote for instance fields.
	 *
	 * What a token can become here, and what it cannot:
	 *
	 * - `PUBLIC` / `PRIVATE`, `STATIC` / `NOTSTATIC`, `INLINE` / `NOTINLINE` are modifier selectors,
	 *   and become `requireMods` / `forbidMods` — see `pair`.
	 * - `ENUM` on `MemberName` selects enum CONSTRUCTORS (`checkEnumFields`), which is this model's
	 *   `EnumValue` and not a field at all. That is the discriminator the two entries lacked.
	 * - `CLASS` / `ABSTRACT` / `TYPEDEF` on `MemberName`, and every `TypeName` token, select the
	 *   enclosing (or declared) TYPE KIND. `NamedDecl` carries no such thing: a declaration knows its
	 *   category, its modifiers and the NAME of its enclosing type, never that type's kind. They are
	 *   read only to decide whether a field rule is contributed at all, and are then IGNORED — a rule
	 *   that over-reports beats one that silently governs nothing. Two rules of one category
	 *   distinguished ONLY by such a token still collapse onto one selector and the later is still
	 *   unreachable; separating them needs a kind on `NamedDecl`, which is a change to the grammar's
	 *   projection, not to this adapter.
	 * - `LocalVariableName` / `ParameterName` declare a `tokens` field they never read, and
	 *   `CatchParameterName` does not even extend `NameCheckBase`. Dropping theirs is what checkstyle
	 *   itself does.
	 *
	 * `props.ignoreExtern` rides the same selector, as one more `forbidMods` entry — see `ruleFor`. It
	 * is `NameCheckBase`'s, so every check here but `CatchParameterName` carries it, and its default is
	 * TRUE. ONE deliberate divergence: checkstyle gates its class / enum / typedef arms on the extern
	 * flag and its ABSTRACT arm on nothing, in all five checks that have one — an `extern abstract`'s
	 * members are reported there and exempt here. `NamedDecl` carries no type KIND (the boundary the
	 * `CLASS` / `ABSTRACT` bullet above states), so the distinction is unrepresentable, and the
	 * direction the gap is closed in is the one that declines to rename an external contract.
	 *
	 * `EnumValueName` is not a checkstyle check at all; it stays as the neutral spelling of this
	 * model's `EnumValue` category, so a config can address that category directly.
	 */
	private static function rulesOf(type: String, format: String, tokens: Array<String>, ignoreExtern: Bool): Array<NamingRule> {
		return switch type {
			case 'TypeName': [ruleFor(NamingCategory.Type, type, format, [], [], ignoreExtern)];
			case 'MemberName': memberRules(type, format, tokens, ignoreExtern);
			case 'MethodName': [methodRule(type, format, tokens, ignoreExtern)];
			case 'ConstantName': [constantRule(type, format, tokens, ignoreExtern)];
			case 'LocalVariableName': [ruleFor(NamingCategory.Local, type, format, [], [], ignoreExtern)];
			case 'ParameterName': [ruleFor(NamingCategory.Param, type, format, [], [], ignoreExtern)];
			case 'EnumValueName':
				[ruleFor(NamingCategory.EnumValue, type, format, [], [], ignoreExtern)];
			// `CatchParameterNameCheck` is the one naming check that does not extend `NameCheckBase`: it
			// declares no `ignoreExtern` at all, so checkstyle never exempts a catch variable for one and
			// neither does this — the flag is dropped here rather than defaulted.
			case 'CatchParameterName': [ruleFor(NamingCategory.CatchVar, type, format, [], [], false)];
			case _: [];
		}
	}

	/**
	 * One `NamingRule` from a config-stated `format`, with the autofix half the config cannot state:
	 * `HaxeNamingSupport.normalizerFor` decides, per category, which of the built-in corrections a
	 * config-derived rule may use, and answers null for a category the built-in itself leaves
	 * report-only.
	 *
	 * The normalizer gets a SECOND `EReg` over the same pattern. `EReg.match` writes the instance's
	 * match state, and the normalizer runs inside `Naming.correctedName` between that caller's own
	 * match and its read of the result — one shared instance would make a rule's format depend on
	 * whether its own autofix had just consulted it.
	 */
	private static function ruleFor(
		category: NamingCategory, label: String, format: String, requireMods: Array<String>, forbidMods: Array<String>, ignoreExtern: Bool
	): NamingRule {
		// checkstyle's `ignoreExtern` asks about the DECLARING TYPE's `extern` flag and about nothing
		// else — not the member, not an `@:native` — and `HaxeNamingSupport` projects exactly that as an
		// inherited modifier on every declaration inside such a type. So the flag needs no field of its
		// own on `NamingRule`: it is one more entry in the selector every rule already carries, and a
		// config stating `ignoreExtern: false` simply contributes none.
		if (ignoreExtern) forbidMods.push(HaxeNamingSupport.EXTERN_MOD);
		return {
			category: category,
			requireMods: requireMods,
			forbidMods: forbidMods,
			format: new EReg(format, ''),
			label: label,
			normalize: HaxeNamingSupport.normalizerFor(category, new EReg(format, ''))
		};
	}

	/**
	 * `MemberName`'s rules: a FIELD rule for its class / abstract / typedef arms, and an ENUM-VALUE
	 * rule for its enum arm, each contributed only when `tokens` reaches that arm. An empty `tokens`
	 * reaches both, which is `hasToken`'s reading and checkstyle's.
	 */
	private static function memberRules(label: String, format: String, tokens: Array<String>, ignoreExtern: Bool): Array<NamingRule> {
		final out: Array<NamingRule> = [];
		if (tokens.length == 0 || tokens.exists(token -> MEMBER_FIELD_TOKENS.contains(token))) {
			final requireMods: Array<String> = [];
			// `checkField` returns on a static field before it consults a single token: to checkstyle
			// a static is a CONSTANT candidate, never a member name.
			final forbidMods: Array<String> = ['static'];
			visibilityPair(tokens, requireMods, forbidMods);
			out.push(ruleFor(NamingCategory.Field, label, format, requireMods, forbidMods, ignoreExtern));
		}
		if (hasToken(tokens, 'ENUM')) out.push(ruleFor(NamingCategory.EnumValue, label, format, [], [], ignoreExtern));
		return out;
	}

	/** `MethodName`'s rule, narrowed by its three token pairs in checkstyle's own order. */
	private static function methodRule(label: String, format: String, tokens: Array<String>, ignoreExtern: Bool): NamingRule {
		final requireMods: Array<String> = [];
		final forbidMods: Array<String> = [];
		visibilityPair(tokens, requireMods, forbidMods);
		negatablePair(tokens, 'static', requireMods, forbidMods);
		negatablePair(tokens, 'inline', requireMods, forbidMods);
		return ruleFor(NamingCategory.Method, label, format, requireMods, forbidMods, ignoreExtern);
	}

	/**
	 * `ConstantName`'s rule, narrowed by its one token pair: `INLINE` is `static inline var`,
	 * `NOTINLINE` is `static var` and `static final` (neither carries the `inline` keyword).
	 */
	private static function constantRule(label: String, format: String, tokens: Array<String>, ignoreExtern: Bool): NamingRule {
		final requireMods: Array<String> = [];
		final forbidMods: Array<String> = [];
		negatablePair(tokens, 'inline', requireMods, forbidMods);
		return ruleFor(NamingCategory.Constant, label, format, requireMods, forbidMods, ignoreExtern);
	}

	/**
	 * The pair checkstyle spells as a modifier's own UPPER_SNAKE name and that name prefixed with
	 * `NOT` — `STATIC` / `NOTSTATIC`, `INLINE` / `NOTINLINE`. Derived from `mod` rather than written
	 * out, so neither spelling can drift from the modifier it selects.
	 */
	private static function negatablePair(tokens: Array<String>, mod: String, requireMods: Array<String>, forbidMods: Array<String>): Void {
		final token: String = mod.toUpperCase();
		pair(tokens, token, 'NOT$token', mod, requireMods, forbidMods);
	}

	/**
	 * Apply one token PAIR to a rule's selector. checkstyle narrows on `hasToken(positive) &&
	 * !hasToken(negative)`, so a pair narrows only when EXACTLY ONE of its two tokens appears in a
	 * NON-EMPTY list: stating both, stating neither, and stating no tokens at all are the same
	 * answer — no narrowing.
	 */
	private static function pair(
		tokens: Array<String>, positive: String, negative: String, mod: String, requireMods: Array<String>, forbidMods: Array<String>
	): Void {
		if (tokens.length == 0) return;
		final wants: Bool = tokens.contains(positive);
		final wantsNot: Bool = tokens.contains(negative);
		if (wants == wantsNot) return;
		if (wants)
			requireMods.push(mod)
		else
			forbidMods.push(mod);
	}

	/** checkstyle `NameCheckBase.hasToken`: an EMPTY `tokens` list means every token, never none. */
	private static function hasToken(tokens: Array<String>, token: String): Bool {
		return tokens.length == 0 || tokens.contains(token);
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
