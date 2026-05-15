package anyparse.query.format.line;

/**
 * Integer terminal for the line-diagnostic grammar — emitted as a
 * plain decimal by the macro-generated writer. Mirrors
 * `anyparse.grammar.json.JIntLit`; `LineDiagFormat.intType` points
 * here so `Int` schema fields lower through it. The `@:re` pattern
 * exists only to satisfy ShapeBuilder (these grammars are
 * writer-only).
 */
@:re('-?(?:0|[1-9][0-9]*)')
abstract LineIntLit(Int) from Int to Int {}
