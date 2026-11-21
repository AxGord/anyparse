package anyparse.query.cli;

/**
 * Marker: this command's file argument is a `<file>:<line>[:<col>]` address, so `LanguageChoice` reads the grammar from the
 * file part — the position suffix hides the extension that names it (`CliArgs.addressOf`).
 */
@:nullSafety(Strict)
interface PositionAddressed {}
