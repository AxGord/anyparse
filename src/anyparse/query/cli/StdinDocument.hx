package anyparse.query.cli;

/**
 * Marker: this command can take the document it parses from standard input (`-` or `--stdin`) and reads it
 * through `CliContext.readStdin`, so with no `--lang` the dispatcher may read stdin first and tell the grammar
 * by its content (`LanguageChoice`).
 */
@:nullSafety(Strict)
interface StdinDocument {}
