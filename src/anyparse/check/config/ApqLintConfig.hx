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
 * scope). Keys this schema does not model are dropped by the `UnknownPolicy.Skip`
 * inherited from `JsonFormat`.
 *
 * `inherit` is the one key about the DOCUMENT rather than about the lint: false
 * makes this document the end of the chain `LintConfig.discover` folds, so it
 * stands alone instead of extending the `apqlint.json` files above it. Absent
 * means true — a nested document extends its ancestors, which is what every
 * nested document written before the chain existed already meant.
 *
 * `languageVersion` is the version of the LANGUAGE the project targets, as a
 * dotted string (`"4.0"`). A rule whose fix emits syntax newer than that is
 * dropped — see `Check.VersionGated`. Absent means no constraint, which is the
 * behaviour every existing config already has.
 *
 * `rules` is the one section with ARBITRARY keys — one entry per rule id —
 * so it is declared `Map<String, JValue>`: the id set is open (any
 * grammar's `Check.id()`) and a rule's option bag is rule-specific, so the
 * value stays the raw JSON tree. `LintConfig.parse` walks each entry,
 * lifting `enabled` / `severity` out and keeping every other key verbatim
 * for the owning check to read through the typed option accessors.
 *
 * `frameworks` declares which frameworks drive this project's types — each entry a root type plus
 * the member names that framework reaches by name with no call written in source. Entries stay raw
 * `JValue` for the same reason `rules` does: `LintConfig` maps them onto the neutral
 * `FrameworkContract` the naming layer speaks, and a per-entry typo must degrade that one entry
 * rather than the document.
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef ApqLintConfig = {

	@:optional var inherit: Bool;

	@:optional var rules: Map<String, JValue>;

	@:optional var compilerOracle: String;

	@:optional var compilerOracleServer: Bool;

	@:optional var resolutionRoots: Array<String>;

	@:optional var resolutionLibs: Array<String>;

	@:optional var resolutionStd: Bool;

	@:optional var languageVersion: String;

	@:optional var frameworks: Array<JValue>;
};
