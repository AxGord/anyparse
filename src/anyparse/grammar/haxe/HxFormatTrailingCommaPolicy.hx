package anyparse.grammar.haxe;

/**
 * Closed set of values the haxe-formatter `trailingCommas` fields
 * accept. `Yes` → `true`; `No` / `Keep` / `Ignore` all map to
 * `false` in the loader (true `Keep` would require remembering the
 * trailing comma per node, which the parser does not yet do).
 */
enum abstract HxFormatTrailingCommaPolicy(String) to String {

	final Yes = 'yes';

	final No = 'no';

	final Keep = 'keep';

	final Ignore = 'ignore';
}
