package anyparse.query.format.json;

/**
 * Declarative schema for the single `haxelib.json` key
 * `HaxelibResolver.sourceDirFrom` reads: `classPath`, the library's source
 * subdirectory relative to its `haxelib libpath` root (`"src"` for openfl,
 * absent/empty for a root-sourced lib). Parsed by the macro-generated
 * `HaxelibJsonParser` (ByName struct lowering).
 *
 * A real `haxelib.json` carries many more keys (`name`, `url`, `license`,
 * `tags`, `description`, `version`, `dependencies`, `contributors`, …) —
 * all dropped by the `UnknownPolicy.Skip` inherited from `JsonFormat`,
 * since `sourceDirFrom` needs only the source directory.
 */
@:peg @:schema(anyparse.format.text.JsonFormat) @:ws
typedef HaxelibJson = {

	@:optional var classPath: String;
};
