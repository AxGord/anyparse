package anyparse.query;

/**
 * What one project file contributes to `apq symbols`, read off its parse alone: its top-level declarations. A file that
 * did not parse holds none. Stored per file (`ProjectOutlines`).
 */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef FileSymbols = { var file: String; var parsed: Bool; var symbols: Array<OutlineSymbol>; }
