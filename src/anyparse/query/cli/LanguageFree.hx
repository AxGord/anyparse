package anyparse.query.cli;

/**
 * Marker: this command parses no grammar — it reads reports, transcripts or snapshots — so a process run
 * with no `--lang` is not asked which language its arguments are in (`LanguageChoice`).
 */
@:nullSafety(Strict)
interface LanguageFree {}
