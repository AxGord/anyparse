package anyparse.grammar.haxe;

import anyparse.format.ArrayMatrixWrap;
import anyparse.grammar.haxe.format.HxFormatConfig;
import anyparse.grammar.haxe.format.HxFormatConfigParser;
import anyparse.grammar.haxe.format.HxFormatIndentationSection;
import anyparse.grammar.haxe.format.HxFormatSameLineSection;
import anyparse.grammar.haxe.format.HxFormatWhitespacePolicy;
import anyparse.grammar.haxe.format.HxFormatWhitespaceSection;
import anyparse.grammar.haxe.format.HxFormatWrapCondition;
import anyparse.grammar.haxe.format.HxFormatWrapRule;
import anyparse.grammar.haxe.format.HxFormatWrapRules;
import anyparse.grammar.haxe.format.HxFormatWrappingSection;
import anyparse.runtime.LineIndex;
import anyparse.runtime.Parser;
import anyparse.runtime.Span.Position;
import anyparse.runtime.StringInput;
import anyparse.runtime.UnknownField;
import anyparse.util.Compare;
import haxe.Exception;

using Lambda;

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
 * Real configs each carry a dozen or so unimplemented keys — mostly
 * whitespace / brace policies.
 *
 * This class only says WHAT: `diagnose` is a pure function of the config text and `message` its one line of text. Saying
 * it is the caller's — `FormatConfigDiscovery` holds the file the text came from and prints the line once per run, so the
 * grammar layer writes nothing to stderr and keeps no run state.
 */
@:access(anyparse.grammar.haxe.HaxeFormatValues)
@:nullSafety(Strict)
final class HaxeFormatConfigDiagnostics {

	/** Set to `1` to silence the config report — for a project that knows its config states more than hxq reads. */
	public static final SILENCE_VAR: String = 'APQ_NO_CONFIG_WARN';

	/**
	 * The settings in `json` hxq will not act on: keys with no schema
	 * field, `wrapping` strings with no runtime mapping, and every `keep`
	 * value (`unsupported`). All groups
	 * are empty when everything is understood, and equally when the config
	 * does not parse — the load path reports that failure itself, at the
	 * position and with the text only it has.
	 *
	 * Not exhaustive over the whole file by construction: a value slot is
	 * surveyed only where its vocabulary is a plain `String` the parser
	 * cannot police. Every enum-typed slot (`sameLine.ifBody`,
	 * `lineEnds.*Curly`, …) is rejected at PARSE time with its own message,
	 * so it never reaches here — except the fork's `keep`, which the schema
	 * accepts so that this report can name it.
	 */
	public static function diagnose(json: String): HaxeFormatConfigIssues {
		final ctx: Parser = new Parser(new StringInput(json));
		final cfg: Null<HxFormatConfig> = try HxFormatConfigParser.parseWith(ctx) catch (exception: Exception) null;
		if (cfg == null) return {
			keys: [],
			wrapValues: [],
			unsupported: [],
			values: []
		};
		final index: LineIndex = new LineIndex(json);
		final wrapValues: Array<String> = [];
		final unsupported: Array<String> = [];
		final wrapping: Null<HxFormatWrappingSection> = cfg.wrapping;
		if (wrapping != null) collectWrappingIssues(wrapping, wrapValues, unsupported);
		final sameLine: Null<HxFormatSameLineSection> = cfg.sameLine;
		if (sameLine != null) collectSameLineKeep(sameLine, unsupported);
		final keys: Array<String> = ctx.unknownFields.map(unknownKeyIssue.bind(_, index));
		final whitespace: Null<HxFormatWhitespaceSection> = cfg.whitespace;
		if (whitespace != null) collectColonIssue(whitespace, keys);
		final values: Array<String> = [];
		final indentation: Null<HxFormatIndentationSection> = cfg.indentation;
		if (indentation != null) collectIndentationIssue(indentation, values);
		return {
			keys: keys,
			wrapValues: wrapValues,
			unsupported: unsupported,
			values: values
		};
	}

	/**
	 * The stderr line for `issues` about the config at `path`, or `null` when there is nothing to
	 * say — data, so the wording is pinned by a test rather than by someone reading a terminal.
	 */
	public static function message(path: String, issues: HaxeFormatConfigIssues): Null<String> {
		final clauses: Array<String> = [];
		if (issues.keys.length > 0)
			clauses.push('${issues.keys.length} key(s) hxq does not implement, so they have no effect: ${issues.keys.join(', ')}');
		if (issues.wrapValues.length > 0)
			clauses.push('${issues.wrapValues.length} wrap setting(s) hxq does not implement: ${issues.wrapValues.join(', ')}');
		if (issues.unsupported.length > 0)
			clauses.push(
				'${issues.unsupported.length} "keep" setting(s) hxq does not support, so the default applies: '
				+ issues.unsupported.join(', ')
				+ ' (hxq lays code out from the syntax tree, not the source line breaks: use same, next or fitLine for sameLine, a wrap '
				+ 'mode such as noWrap, onePerLine or fillLine for wrapping)'
			);
		if (issues.values.length > 0)
			clauses.push('${issues.values.length} value(s) hxq cannot read, so the default is kept: ${issues.values.join(', ')}');
		return clauses.length == 0 ? null : 'apq: $path: ${clauses.join('; ')} [silence with $SILENCE_VAR=1]\n';
	}

	private static inline function add(into: Array<String>, issue: String): Void {
		if (!into.contains(issue)) into.push(issue);
	}

	/** Both spellings of the fork's source-layout mode, as `HaxeFormatValues.wrapModeFromString` reads every mode. */
	private static inline function isKeep(s: String): Bool {
		return s == 'keep' || s == 'Keep';
	}

	/**
	 * `whitespace.colonPolicy` loads but no knob reads it: hxq spaces every type-hint colon by `typeHintColonPolicy`
	 * (default `none`). A stated `colonPolicy` that differs from that is a setting the fork acts on and hxq does not.
	 */
	private static function collectColonIssue(section: HxFormatWhitespaceSection, into: Array<String>): Void {
		final stated: Null<HxFormatWhitespacePolicy> = section.colonPolicy;
		if (stated == null) return;
		final used: HxFormatWhitespacePolicy = section.typeHintColonPolicy ?? HxFormatWhitespacePolicy.None;
		if (stated != used) add(into, 'whitespace.colonPolicy "$stated" (hxq spaces it by typeHintColonPolicy "$used")');
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
	private static function collectWrappingIssues(section: HxFormatWrappingSection, into: Array<String>, keeps: Array<String>): Void {
		final matrix: Null<String> = section.arrayMatrixWrap;
		if (matrix != null && ArrayMatrixWrap.resolve(matrix) == null) add(into, 'arrayMatrixWrap "$matrix" (the format default is kept)');
		for (cascade in cascades(section)) {
			final defaultWrap: Null<String> = cascade.defaultWrap;
			if (defaultWrap != null && isKeep(defaultWrap))
				add(keeps, 'wrapping defaultWrap "$defaultWrap"');
			else if (defaultWrap != null && HaxeFormatValues.wrapModeFromString(defaultWrap) == null)
				add(into, 'defaultWrap "$defaultWrap" (the cascade keeps its built-in default)');
			final defaultLocation: Null<String> = cascade.defaultLocation;
			if (defaultLocation != null && HaxeFormatValues.wrappingLocationFromString(defaultLocation) == null)
				add(into, 'defaultLocation "$defaultLocation" (ignored)');
			final rules: Null<Array<HxFormatWrapRule>> = cascade.rules;
			if (rules != null) for (rule in rules) collectRuleIssues(rule, into, keeps);
		}
		for (chain in [section.methodChain, section.opBoolChain, section.opAddSubChain]) if (chain != null && chainStatesIndent(chain))
			add(
				into,
				'additionalIndent on a methodChain / opBoolChain / opAddSubChain cascade (ignored: a chain wrap takes no extra indent)'
			);
	}

	/**
	 * One rule's unusable strings. Mirrors every `return null` in
	 * `HaxeFormatConfigLoader.wrapRuleFromConfig` — including its two
	 * SHAPE bails, a rule with no `type` and a condition with no `cond`,
	 * which drop the rule just as silently as an unreadable string does
	 * and are just as invisible to the author.
	 */
	private static function collectRuleIssues(rule: HxFormatWrapRule, into: Array<String>, keeps: Array<String>): Void {
		final type: Null<String> = rule.type;
		if (type == null)
			add(into, 'a rule with no "type" (the rule is dropped)');
		else if (isKeep(type))
			add(keeps, 'wrapping rule type "$type" (the rule is dropped)');
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
			section.mapWrap,
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

	/**
	 * Does a chain cascade state an indent the chain emitters never read? The chain sections share
	 * the list schema, so the parser accepts `additionalIndent` / `defaultAdditionalIndent` there and
	 * only this check says they have no effect.
	 */
	private static function chainStatesIndent(chain: HxFormatWrapRules): Bool {
		if (chain.defaultAdditionalIndent != null) return true;
		final rules: Null<Array<HxFormatWrapRule>> = chain.rules;
		return rules != null && rules.exists(rule -> rule.additionalIndent != null);
	}

	/**
	 * Every `sameLine` key stating `keep`. Its value is typed, so the parser accepts the fork's spelling, and the loader
	 * then leaves that knob at its default (`HaxeFormatValues.bodyPolicyToRuntime` and its siblings).
	 */
	private static function collectSameLineKeep(section: HxFormatSameLineSection, into: Array<String>): Void {
		// Only the placement-policy fields of the section are strings (the rest are Bool / Int, or a sibling policy with
		// no `keep`), so reading every field by reflection reports a new policy key with no list to extend.
		final keys: Array<String> = Reflect.fields(section);
		keys.sort(Compare.compareString);
		for (key in keys) {
			final value: String = Std.string(Reflect.field(section, key));
			if (isKeep(value)) add(into, 'sameLine.$key "$value"');
		}
	}

	/** An `indentation.character` spelling `HaxeFormatValues.indentCharFromString` does not read, which leaves the default indent. */
	private static function collectIndentationIssue(section: HxFormatIndentationSection, into: Array<String>): Void {
		final character: Null<String> = section.character;
		if (character != null && HaxeFormatValues.indentCharFromString(character) == null)
			add(into, 'indentation.character "$character" (use "tab" or a literal run of spaces such as "    ")');
	}

}
