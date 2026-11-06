package anyparse.query.cli;

/**
 * A command that is `LanguageFree` only for some argv — `apq get --where` routes each document it searches by its own extension,
 * while a plain `apq get` parses the one file it names — so a process run with no `--lang` asks the command (`LanguageChoice`)
 * whether this call needs the language named at all.
 */
@:nullSafety(Strict)
interface LanguageFreeWhen {

	/** Whether the call `args` reads no grammar of its own choosing: each file it reaches is routed by its extension. */
	public function languageFreeFor(args: Array<String>): Bool;

}
