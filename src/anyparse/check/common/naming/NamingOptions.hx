package anyparse.check.common.naming;

import anyparse.query.NamingPolicy.FrameworkContract;
import anyparse.query.NamingPolicy.HoistedConstant;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.NamingPolicy.PropertyClause;
import anyparse.query.SymbolIndex;

/**
 * A grammar's `NamingSupport` with the project's `naming` options laid over its policy: each option is a rule placed
 * AHEAD of the policy the grammar resolves for a file (a `checkstyle.json`, else the built-in default), so it governs
 * the declarations it selects and leaves every other one to that policy. Every other question is the grammar's.
 *
 * `catchVarName` names every catch variable that one name (an `_`-prefixed discard keeps its marker), and
 * `handlerSuffix` turns a listener method spelled `onX` into `xHandler`. The options are resolved per file from the
 * `apqlint.json` chain, so the rename paths and the report read one policy.
 */
@:nullSafety(Strict)
final class NamingOptions implements NamingSupport {

	/** The rule id whose options this reads. */
	private static inline final RULE_ID: String = 'naming';

	/** The option naming every catch variable. */
	private static inline final CATCH_VAR_OPTION: String = 'catchVarName';

	/** The option spelling a listener method `<event><suffix>` rather than `on<Event>`. */
	private static inline final HANDLER_OPTION: String = 'handlerSuffix';

	/** The length of the listener prefix `on` the handler option drops. */
	private static inline final LISTENER_PREFIX_LENGTH: Int = 2;

	/** The listener spelling the handler option rewrites away: `on` before an upper-case letter. */
	private static final LISTENER_NAME: EReg = ~/^on[A-Z]/;

	/** Neutral modifiers a handler rule leaves to the general one: an override's name is its supertype's. */
	private static final HANDLER_EXEMPT_MODS: Array<String> = ['override', 'extern'];

	private final _base: NamingSupport;
	private final _resolve: Null<(String) -> LintConfig>;

	private function new(base: NamingSupport, resolve: Null<(String) -> LintConfig>) {
		_base = base;
		_resolve = resolve;
	}

	public function project(tree: QueryNode, ?properties: () -> Map<Int, PropertyClause>): Array<NamedDecl> {
		return _base.project(tree, properties);
	}

	public function policyFor(path: String): NamingPolicy {
		final config: LintConfig = LintConfig.resolveWith(_resolve, path);
		final rules: NamingPolicy = [];
		final catchName: Null<String> = catchVarName(config);
		if (catchName != null) rules.push(catchVarRule(catchName));
		final suffix: Null<String> = config.stringOption(RULE_ID, HANDLER_OPTION);
		if (suffix != null && suffix != '') rules.push(handlerRule(suffix));
		final base: NamingPolicy = _base.policyFor(path);
		return rules.length == 0 ? base : rules.concat(base);
	}

	public function frameworkReachable(decl: NamedDecl, index: () -> Null<SymbolIndex>, contracts: Array<FrameworkContract>): Bool {
		return _base.frameworkReachable(decl, index, contracts);
	}

	public function frameworkOwnsName(decl: NamedDecl, index: () -> Null<SymbolIndex>, contracts: Array<FrameworkContract>): Bool {
		return _base.frameworkOwnsName(decl, index, contracts);
	}

	public function reflectionMemberNames(tree: QueryNode, source: String): Array<String> {
		return _base.reflectionMemberNames(tree, source);
	}

	public function hoistedConstant(declarationText: String, scalar: Bool): Null<HoistedConstant> {
		return _base.hoistedConstant(declarationText, scalar);
	}

	/** `base` with the project's `naming` options laid over it, or null when the grammar has no naming support. */
	public static function over(base: Null<NamingSupport>, resolve: Null<(String) -> LintConfig>): Null<NamingSupport> {
		return base == null ? null : new NamingOptions(base, resolve);
	}

	/**
	 * The one name `config`'s `naming.catchVarName` gives every catch variable, or null when the project sets none - the
	 * name the naming policy enforces and the name a rule renaming a catch variable writes.
	 */
	public static function catchVarName(config: LintConfig): Null<String> {
		final name: Null<String> = config.stringOption(RULE_ID, CATCH_VAR_OPTION);
		return name == '' ? null : name;
	}

	/** Every catch variable is `name`, or an `_`-prefixed discard, which marks a deliberately swallowed exception. */
	private static function catchVarRule(name: String): NamingRule {
		return {
			category: NamingCategory.CatchVar,
			requireMods: [],
			forbidMods: [],
			format: new EReg('^(?:${EReg.escape(name)}|_[A-Za-z0-9_]*)$', ''),
			label: 'catch variable named $name',
			normalize: current -> current.charAt(0) == '_' ? null : name
		};
	}

	/** A method named `on<Event>` is a listener spelled the other way: `<event><suffix>`. */
	private static function handlerRule(suffix: String): NamingRule {
		return {
			category: NamingCategory.Method,
			requireMods: [],
			forbidMods: HANDLER_EXEMPT_MODS.copy(),
			format: ~/^(?!on[A-Z])/,
			label: 'listener method named <event>$suffix, not on<Event>',
			appliesTo: LISTENER_NAME,
			normalize: current -> current.charAt(LISTENER_PREFIX_LENGTH).toLowerCase() + current.substr(LISTENER_PREFIX_LENGTH + 1) + suffix
		};
	}

}
