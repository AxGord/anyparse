package anyparse.query.cli;

/**
 * Marker: this command parses no grammar, or picks one per file itself — it reads reports, transcripts or snapshots, or
 * routes each file by its extension — so a process run with no `--lang` is not asked which language its arguments are in
 * (`LanguageChoice`).
 */
@:nullSafety(Strict)
interface LanguageFree {}
