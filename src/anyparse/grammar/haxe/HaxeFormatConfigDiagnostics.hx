package anyparse.grammar.haxe;

import anyparse.format.ArrayMatrixWrap;
import anyparse.grammar.haxe.format.HxFormatConfig;
import anyparse.grammar.haxe.format.HxFormatConfigParser;
import anyparse.grammar.haxe.format.HxFormatWrapCondition;
import anyparse.grammar.haxe.format.HxFormatWrapRule;
import anyparse.grammar.haxe.format.HxFormatWrapRules;
import anyparse.grammar.haxe.format.HxFormatWrappingSection;
import anyparse.runtime.LineIndex;
import anyparse.runtime.Parser;
import anyparse.runtime.Span.Position;
import anyparse.runtime.StringInput;
import anyparse.runtime.UnknownField;
import haxe.Exception;

/**
 * Says which settings in an `hxformat.json` hxq will not act on.
 *
 * `HaxeFormatConfigLoader` is deliberately forward-compatible: a key it
 * has no field for is dropped, and a wrap rule naming a predicate it has
 * no mapping for is dropped whole. Both are the right RUNTIME behaviour —
 * `hxformat.json` is haxe-formatter's file and hxq models a subset of it,
 * so refusing to load would break every real config. What was missing is
 * the other half: the config author got no signal at all, so a knob that
 * does nothing is indistinguishable from a knob that works.
 *
 * Measured 2026-08-25 on three real configs (anyparse's own,
 * `Pony/hxformat.json`, `horse_game/hxformat.json`): 12, 19 and 19
 * unimplemented keys respectively, plus three of the fork's own shipped
 * condition strings (`equalItemLengths`, `allItemLengths <= n`,
 * `anyItemLength <= n`) that drop a whole rule each.
 *
 * Analysis and reporting are split on purpose: `diagnose` is a pure function of the config text and is what tests assert on, while `warn` is the boundary shell that knows the file the text came from and owns the once-per-path stderr line. One older diagnostic of the same kind still lives elsewhere: `HaxeFormatConfigLoader.warnUnknownIndentCharacter` reports an unreadable `indentation.character` from inside the loader, deduplicated by VALUE and without naming the file. Folding it in here needs its recognition predicate to become a shared `…FromString` reader first, so it stays where it is for now — and `indentation` is therefore the one section whose VALUES this class does not survey.
 */
@:access(anyparse.grammar.haxe.HaxeFormatValues)
@:nullSafety(Strict)
final class HaxeFormatConfigDiagnostics {

	/** Set to `1` to silence the config report — for a project that knows its config states more than hxq reads. */
	private static inline final SILENCE_VAR: String = 'APQ_NO_CONFIG_WARN';

	/**
	 * Config paths already reported, so a run that resolves the same
	 * `hxformat.json` for hundreds of files says it once. Process-scoped
	 * like `FormatConfigDiscovery.CACHE`, which is what feeds it, and
	 * carries no parse state — only "this path has been examined".
	 */
	private static final reported: Array<String> = [];

	/**
	 * The settings in `json` hxq will not act on: keys with no schema
	 * field, and `wrapping` strings with no runtime mapping. Both groups
	 * are empty when everything is understood, and equally when the config
	 * does not parse — the load path reports that failure itself, at the
	 * position and with the text only it has.
	 *
	 * Not exhaustive over the whole file by construction: a value slot is
	 * surveyed only where its vocabulary is a plain `String` the parser
	 * cannot police. Every enum-typed slot (`sameLine.ifBody`,
	 * `lineEnds.*Curly`, …) is rejected at PARSE time with its own message,
	 * so it never reaches here.
	 */
	public static function diagnose(json: String): HaxeFormatConfigIssues {
		final ctx: Parser = new Parser(new StringInput(json));
		final cfg: Null<HxFormatConfig> = try HxFormatConfigParser.parseWith(ctx) catch (exception: Exception) null;
		if (cfg == null) return { keys: [], wrapValues: [] };
		final index: LineIndex = new LineIndex(json);
		final wrapValues: Array<String> = [];
		final wrapping: Null<HxFormatWrappingSection> = cfg.wrapping;
		if (wrapping != null) collectWrappingIssues(wrapping, wrapValues);
		return {
			keys: [for (field in ctx.unknownFields) unknownKeyIssue(field, index)],
			wrapValues: wrapValues
		};
	}

	/**
	 * Report `json`'s unusable settings on stderr, once per config path
	 * for the life of the process. Silent when the config is fully
	 * understood, when `APQ_NO_CONFIG_WARN=1`, and on a target with no
	 * stderr.
	 */
	public static function warn(path: String, json: String): Void {
		if (reported.contains(path)) return;
		reported.push(path);
		#if (sys || nodejs)
		if (Sys.getEnv(SILENCE_VAR) == '1') return;
		final line: Null<String> = message(path, diagnose(json));
		if (line != null) Sys.stderr().writeString(line);
		#end
	}

	/**
	 * The stderr line for `issues`, or `null` when there is nothing to
	 * say. Split out of `warn` so the wording is pinned by a test rather
	 * than by someone reading a terminal.
	 */
	public static function message(path: String, issues: HaxeFormatConfigIssues): Null<String> {
		final clauses: Array<String> = [];
		if (issues.keys.length > 0)
			clauses.push('${issues.keys.length} key(s) hxq does not implement, so they have no effect: ${issues.keys.join(', ')}');
		if (issues.wrapValues.length > 0)
			clauses.push('${issues.wrapValues.length} wrap setting(s) hxq does not implement: ${issues.wrapValues.join(', ')}');
		return clauses.length == 0 ? null : 'apq: $path: ${clauses.join('; ')} [silence with $SILENCE_VAR=1]\n';
	}

	private static inline function add(into: Array<String>, issue: String): Void {
		if (!into.contains(issue)) into.push(issue);
	}

	private static function unknownKeyIssue(field: UnknownField, index: LineIndex): String {
		final at: Position = index.lineColAt(field.pos);
		final guess: Null<String> = field.suggestion();
		return guess == null ? '${field.key} (l.${at.line})' : '${field.key} (l.${at.line}; did you mean "$guess"?)';
	}

	/**
	 * `wrapping` strings with no runtime mapping. Unlike an unknown key
	 * these are typed `String` in the schema, so the parser accepts
	 * anything and only the loader's own `…FromString` readers know the
	 * vocabulary — which is why they are checked here rather than on the
	 * context. Reported once per distinct string, keyed by the schema
	 * slot it sat in (`cond "…"`) rather than by position: the same
	 * predicate usually appears in several cascades, and the string
	 * itself is what an author greps for.
	 *
	 * Each phrase carries its OWN consequence, because they differ: a
	 * cascade default falls back to the built-in one, while an unreadable
	 * `type` or `cond` makes `wrapRuleFromConfig` return null and the
	 * WHOLE rule disappear from the cascade.
	 */
	private static function collectWrappingIssues(section: HxFormatWrappingSection, into: Array<String>): Void {
		final matrix: Null<String> = section.arrayMatrixWrap;
		if (matrix != null && ArrayMatrixWrap.resolve(matrix) == null) add(into, 'arrayMatrixWrap "$matrix" (the format default is kept)');
		for (cascade in cascades(section)) {
			final defaultWrap: Null<String> = cascade.defaultWrap;
			if (defaultWrap != null && HaxeFormatValues.wrapModeFromString(defaultWrap) == null)
				add(into, 'defaultWrap "$defaultWrap" (the cascade keeps its built-in default)');
			final defaultLocation: Null<String> = cascade.defaultLocation;
			if (defaultLocation != null && HaxeFormatValues.wrappingLocationFromString(defaultLocation) == null)
				add(into, 'defaultLocation "$defaultLocation" (ignored)');
			final rules: Null<Array<HxFormatWrapRule>> = cascade.rules;
			if (rules != null) for (rule in rules) collectRuleIssues(rule, into);
		}
	}

	/**
	 * One rule's unusable strings. Mirrors every `return null` in
	 * `HaxeFormatConfigLoader.wrapRuleFromConfig` — including its two
	 * SHAPE bails, a rule with no `type` and a condition with no `cond`,
	 * which drop the rule just as silently as an unreadable string does
	 * and are just as invisible to the author.
	 */
	private static function collectRuleIssues(rule: HxFormatWrapRule, into: Array<String>): Void {
		final type: Null<String> = rule.type;
		if (type == null)
			add(into, 'a rule with no "type" (the rule is dropped)');
		else if (HaxeFormatValues.wrapModeFromString(type) == null)
			add(into, 'type "$type" (the rule is dropped)');
		final location: Null<String> = rule.location;
		if (location != null && HaxeFormatValues.wrappingLocationFromString(location) == null) add(into, 'location "$location" (ignored)');
		final conditions: Null<Array<HxFormatWrapCondition>> = rule.conditions;
		if (conditions == null) return;
		for (condition in conditions) {
			final cond: Null<String> = condition.cond;
			if (cond == null)
				add(into, 'a condition with no "cond" (the rule is dropped)');
			else if (HaxeFormatValues.wrapCondFromString(cond) == null)
				add(into, 'cond "$cond" (the rule is dropped)');
		}
	}

	/**
	 * The `WrapRules` cascades present in `section` — a HAND-MAINTAINED
	 * mirror of the list `HaxeFormatConfigLoader.applyWrappingRulesA` and
	 * `…RulesB` walk, since each of those pairs a cascade with its target
	 * option and this one does not. Nothing makes an 18th cascade a
	 * compile error here; `HaxeFormatConfigDiagnosticsTest`'s table over
	 * every name is what fails when the three lists drift.
	 */
	private static function cascades(section: HxFormatWrappingSection): Array<HxFormatWrapRules> {
		final all: Array<Null<HxFormatWrapRules>> = [
			section.arrayWrap,
			section.multiVar,
			section.casePattern,
			section.anonType,
			section.methodChain,
			section.opBoolChain,
			section.opAddSubChain,
			section.callParameter,
			section.objectLiteral,
			section.conditionWrapping,
			section.ternaryExpression,
			section.functionSignature,
			section.anonFunctionSignature,
			section.metadataCallParameter,
			section.typeParameter,
			section.expressionWrapping,
			section.implementsExtends
		];
		return [for (cascade in all) if (cascade != null) cascade];
	}

}
