package anyparse.grammar.haxe.checkstyle;

/**
 * Declarative schema for the subset of `checkstyle.json` that
 * `CheckstyleConfigLoader` reads, parsed by the macro-generated
 * `CheckstyleConfigParser` (ByName struct lowering) — the checkstyle
 * counterpart of `HxFormatConfig` / `HxFormatConfigParser`.
 *
 * Only `checks` is modelled; every other top-level key a real config
 * carries (`extendsConfigPath`, `defaultSeverity`, `exclude`, …) is dropped
 * by the `UnknownPolicy.Skip` this root inherits from `JsonFormat`. `checks`
 * itself is `@:optional`, so an empty `{}` config is valid and yields a
 * config with no checks — the loader then produces an empty policy / no
 * overrides.
 */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef CheckstyleConfig = {

	@:optional var checks: Array<CheckstyleCheck>;
};
