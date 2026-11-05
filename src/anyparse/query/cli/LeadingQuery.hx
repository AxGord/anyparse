package anyparse.query.cli;

/**
 * Marker: the first positional of this command (every one before a bare `--`) is the text it searches for, not a file —
 * `lit '.last-sweep.json' src` — so `LanguageChoice` does not read its extension as a file naming a grammar. The one
 * answer to "which positionals of this command are files" is `CliArgs.routePositional`.
 */
@:nullSafety(Strict)
interface LeadingQuery {}
