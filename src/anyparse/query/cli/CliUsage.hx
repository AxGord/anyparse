package anyparse.query.cli;

/**
 * The `--help` fragments more than one command prints.
 *
 * A usage page is assembled from shared blocks — the `--write` / `--lang` tail,
 * the v2 addressing section, the `--flat` / `--limit` pair — and those blocks
 * were private statics of `Cli` that every `printXUsage` reached for. They are
 * the only part of the usage layer the command seam does NOT give a command of
 * its own, because they belong to no single command.
 */
@:nullSafety(Strict)
final class CliUsage {

	public static function printWriteLangHelp(): Void {
		CliIo.sysPrint('  --write             Overwrite <file> in place (default: emit to stdout)\n');
		CliIo.sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('\n');
	}

	public static function printOptionsWriteLangHelp(): Void {
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		printWriteLangHelp();
	}

	public static function printEditOptionsTail(): Void {
		CliIo.sysPrint('  --write         Overwrite the file in place (default: print to stdout)\n');
		CliIo.sysPrint('  --reformat      Canonicalise the whole file if it is not already canonical\n');
		CliIo.sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  -h, --help      Show this help\n');
	}

	public static function printOptionsEditTail(): Void {
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		printEditOptionsTail();
	}

	public static function printAddressingHelp(): Void {
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Addressing:\n');
		CliIo.sysPrint("  <line>[:<col>]      1-based position; column omitted = the line's first\n");
		CliIo.sysPrint('                      non-whitespace character\n');
		CliIo.sysPrint("  --select '<sel>'    Selector: Kind / Kind:name / A > B (child) / A >> B\n");
	}

	public static function printSelectorAddressingOptions(): Void {
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --select <sel>      Address the node by selector: Kind / Kind:name / A > B\n');
		CliIo.sysPrint('                      (direct child) / A >> B (any-depth descendant); must\n');
		CliIo.sysPrint('                      resolve to exactly one node (or pick one with --nth)\n');
		CliIo.sysPrint("  --match '<pattern>' Address by apq-search structural pattern ($x metavars);\n");
		CliIo.sysPrint('                      same exactly-one / --nth discipline\n');
		CliIo.sysPrint('  --nth <k>           Pick the k-th (1-based, document order) match\n');
		CliIo.sysPrint('  --at <line>[:<col>] Address the innermost node at the cursor; column omitted\n');
		CliIo.sysPrint("                      = the line's first non-whitespace character\n");
	}

	public static function printSelectorAddressingSection(): Void {
		printAddressingHelp();
		CliIo.sysPrint("                      (descendant), e.g. --select 'FnMember:walk'; exactly one\n");
		CliIo.sysPrint("  --match '<pattern>' apq-search structural pattern; exactly one\n");
		CliIo.sysPrint('  --nth <k>           Pick the k-th (1-based) of several matches\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
	}

	public static function printFlatLimitLangHelp(): Void {
		CliIo.sysPrint('  --flat              Legacy flat `file:line:col:` format (default: grouped-by-file)\n');
		CliIo.sysPrint('  --limit <n>         Stop after n hits total (default: no limit)\n');
		CliIo.sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('\n');
	}

	public static function printDocSourceFlatLimitLangHelp(): Void {
		CliIo.sysPrint('  --doc               Also emit each hit\'s leading doc-comment\n');
		CliIo.sysPrint('  --source            Also emit each hit\'s verbatim source slice — the HIT\'s own\n');
		CliIo.sysPrint('                      span, NOT a declaration group, so a decl hit prints without\n');
		CliIo.sysPrint('                      its modifiers. This is a listing snippet; copy from\n');
		CliIo.sysPrint('                      apq source --select (or apq ast --select --source) when the\n');
		CliIo.sysPrint('                      text is going back into an op.\n');
		printFlatLimitLangHelp();
	}

	public static function printShortReformatWriteLangHelp(): Void {
		CliIo.sysPrint('  --reformat     Canonicalise the file if it has drifted\n');
		CliIo.sysPrint('  --write        Apply in place (default: print the rewritten file)\n');
		CliIo.sysPrint('  --lang <name>  Grammar plugin (default haxe)\n');
	}

}
