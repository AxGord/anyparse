package anyparse.query.cli.command;

import anyparse.query.ExitCode.*;
import anyparse.query.ExtractVar;
import anyparse.runtime.Span;

/**
 * `apq extract-var` — hoist an expression into a new local final.
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class ExtractVarCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'extract-var';
	}

	public function summary(): String {
		return 'Hoist an expression into a new local final';
	}

	public function flags(): CliFlags {
		return new CliFlags(['--write', '--single'], ['--match', '--nth']);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runExtractVar(args);
	}

	public function usage(): Void {
		printExtractVarUsage();
	}

	/**
	 * `apq extract-var <file> <line>:<col> <name> [--single] [--write]` — hoist the
	 * expression starting at `<line>:<col>` into a fresh local
	 * `final <name> = <expr>;` inserted on its own line immediately before
	 * the nearest enclosing block-level statement (at that statement's
	 * indentation), replacing with `<name>` every equal occurrence that reads
	 * the same value, or only the addressed one with `--single`. The
	 * inverse of `inline`. The enclosing statement must be a direct child
	 * of a `{ }` block — an expression buried in a braceless branch is
	 * refused. `<line>:<col>` uses the same column convention `apq refs`
	 * prints. Without `--write` the rewritten source is emitted to stdout;
	 * with `--write` it overwrites the file in place. A cursor not on an
	 * expression start, an enclosing statement outside a block, or an
	 * unparseable result exits non-zero with the file untouched.
	 */
	private static function runExtractVar(args: Array<String>): Int {
		// noqa: complexity
		final op: String = 'extract-var';
		var lang: String = 'haxe';
		var write: Bool = false;
		var single: Bool = false;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;
		var name: Null<String> = null;

		for (arg in new ExtractVarCommand().flags().walk(args)) {
			final a: String = arg.token;
			switch arg.flag {
				case '--lang':
					lang = arg.value();
				case '--match':
					matchExpr = arg.value();
				case '--nth':
					nth = arg.intValue();
				case '--write':
					write = true;
				case '--single':
					single = true;
				case '-h', '--help':
					printExtractVarUsage();
					return EXIT_OK;
				case null:
					if (file == null) {
						file = a;
					} else if (posSpec == null && matchExpr == null && name == null && CliArgs.isPosSpec(a)) {
						posSpec = a;
					} else if (name == null) {
						name = a;
					} else {
						CliIo.stderr('apq extract-var: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
		}
		if (file == null || (posSpec == null && matchExpr == null) || name == null) {
			CliIo.stderr("apq extract-var: expected <file> (<line>:<col> | --match '<expr-pattern>') <name>\n");
			printExtractVarUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final nameStr: String = name;
		final source: String = try {
			CliIo.readFile(filePath);
		} catch (exception: Exception) {
			CliIo.stderr('apq extract-var: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};

		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		// A --match address knows the expression's EXACT span — both ends are
		// passed through so a co-starting wider operator chain (`a * 2 + 1` over
		// a matched `a * 2`) cannot swallow the extraction.
		var exactTo: Null<Int> = null;
		var pos: Null<Position> = null;
		if (matchExpr != null) {
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
			if (tree == null) {
				CliIo.stderr('apq extract-var: $filePath does not parse\n');
				return EXIT_RUNTIME;
			}
			switch Address.resolve(tree, source, plugin, { match: matchExpr, nth: nth }) {
				case Ok(offset, node):
					pos = new Span(offset, offset).lineCol(source);
					exactTo = node?.span?.to;
				case Err(message):
					CliIo.stderr('apq extract-var: $message\n');
					return EXIT_RUNTIME;
			}
		} else {
			pos = CliEdit.resolveAddressPos(op, source, plugin, posSpec, null, null, null);
		}
		if (pos == null) return EXIT_RUNTIME;
		final loc: Position = pos;
		final result: ExtractResult = ExtractVar.extractVar(source, loc.line, loc.col, nameStr, plugin, exactTo, single, filePath);
		switch result {
			case Ok(text, replaced, equal, guarded):
				// A left occurrence is said, never silent: the repeated-expression finding then still stands.
				if (equal > 1) {
					final left: String = leftNote(replaced < equal, single, guarded);
					CliIo.stderr('apq extract-var: replaced $replaced of $equal equal occurrence(s) in the function$left\n');
				}
				if (write) {
					RegistryFollowCommand.writeFollowed(op, [{ path: filePath, content: text }], plugin);
					CliIo.stderr('apq extract-var: wrote $filePath\n');
				} else {
					CliEdit.previewEdit(op, filePath, text);
				}
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq extract-var: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printExtractVarUsage(): Void {
		CliIo.sysPrint("Usage: apq extract-var <file> (<line>:<col> | --match '<expr-pattern>') <name> [--single] [--write]\n");
		CliUsage.printOptionsWriteLangHelp();
		CliIo.sysPrint('  --single   replace only the addressed occurrence\n');
		CliIo.sysPrint('Scope-correct, format-preserving extract-variable — the inverse of\n');
		CliIo.sysPrint('inline. The expression starting at <line>:<col> is hoisted into a fresh\n');
		CliIo.sysPrint('local `final <name> = <expr>;` inserted on its own line immediately\n');
		CliIo.sysPrint('before the nearest enclosing block-level statement (at that statement\'s\n');
		CliIo.sysPrint('indentation). Every occurrence in the function equal to it up to layout\n');
		CliIo.sysPrint('that reads the same value (pure, no write or loop back edge between\n');
		CliIo.sysPrint('them) is replaced with <name>, unless a guard, a branch or a write\n');
		CliIo.sysPrint('before the earliest one keeps a single local from standing for it;\n');
		CliIo.sysPrint('stderr says how many of the equal ones\n');
		CliIo.sysPrint('were replaced. The local carries the type the structural ladder of\n');
		CliIo.sysPrint('explicit-local-type names without a compiler, untyped when it names none.\n');
		CliIo.sysPrint('The cursor must point at the FIRST token of an expression; the\n');
		CliIo.sysPrint('outermost expression starting there is selected. The enclosing\n');
		CliIo.sysPrint('statement must be a direct child of a { } block — an expression buried\n');
		CliIo.sysPrint('in a braceless branch is refused. <line>:<col> uses the same column\n');
		CliIo.sysPrint('convention `apq refs` prints. The rewrite is verified to re-parse; a\n');
		CliIo.sysPrint('cursor not on an expression start, an enclosing statement outside a\n');
		CliIo.sysPrint('block, or an unparseable result exits non-zero with the file untouched.\n');
	}

	/**
	 * Why equal occurrences were left: the caller's `--single`, a branch, a short-circuit or a write the earliest sits
	 * behind (`guarded`), or no proof they read the value the hoisted one does.
	 */
	private static function leftNote(left: Bool, single: Bool, guarded: Bool): String {
		return if (!left)
			''
		else if (single)
			' (--single)'
		else if (guarded)
			' — no statement before them reaches the rest unconditionally: a branch, a short-circuit or a write comes first'
		else
			' — the rest is not proved to read the same value: an impure read, or a write, a loop or another body between them';
	}

}
