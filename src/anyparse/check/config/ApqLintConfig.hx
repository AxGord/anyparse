package anyparse.check.config;

import anyparse.grammar.json.JValue;

/**
 * Declarative schema for `apqlint.json`, parsed by the macro-generated
 * `ApqLintConfigParser` (ByName struct lowering) — the apq-native
 * counterpart of `HxFormatConfig` and `CheckstyleConfig`.
 *
 * Every key is `@:optional`, so an empty `{}` config is valid and yields a
 * config with nothing declared; `LintConfig` then applies its own defaults
 * (every rule enabled, no severity override, the std in the resolution
 * scope). Keys this schema does not model are dropped by the
 * `UnknownPolicy.Skip` inherited from `JsonFormat`.
 *
 * `rules` is the one section with ARBITRARY keys — one entry per rule id —
 * so it is declared `Map<String, JValue>`: the id set is open (any
 * grammar's `Check.id()`) and a rule's option bag is rule-specific, so the
 * value stays the raw JSON tree. `LintConfig.parse` walks each entry,
 * lifting `enabled` / `severity` out and keeping every other key verbatim
 * for the owning check to read through the typed option accessors.
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef ApqLintConfig = {

	@:optional var rules: Map<String, JValue>;

	@:optional var compilerOracle: String;

	@:optional var resolutionRoots: Array<String>;

	@:optional var resolutionLibs: Array<String>;

	@:optional var resolutionStd: Bool;
};
