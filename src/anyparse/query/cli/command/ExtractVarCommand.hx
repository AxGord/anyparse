package anyparse.query.cli.command;

import anyparse.query.ExtractVar;
import anyparse.query.cli.CliContext;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

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

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runExtractVar(args);
	}

	public function usage(): Void {
		printExtractVarUsage();
	}

	/**
	 * `apq extract-var <file> <line>:<col> <name> [--write]` — hoist the
	 * expression starting at `<line>:<col>` into a fresh local
	 * `final <name> = <expr>;` inserted on its own line immediately before
	 * the nearest enclosing block-level statement (at that statement's
	 * indentation), replacing the expression occurrence with `<name>`. The
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
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;
		var name: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--match':
					matchExpr = CliArgs.expectValue(args, ++i, '--match');
				case '--nth':
					nth = Std.parseInt(CliArgs.expectValue(args, ++i, '--nth'));
				case '--write':
					write = true;
				case '-h', '--help':
					printExtractVarUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq extract-var: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null && matchExpr == null && name == null && CliArgs.isPosSpec(a))
						posSpec = a;
					else if (name == null)
						name = a;
					else {
						CliIo.stderr('apq extract-var: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || (posSpec == null && matchExpr == null) || name == null) {
			CliIo.stderr("apq extract-var: expected <file> (<line>:<col> | --match '<expr-pattern>') <name>\n");
			printExtractVarUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final nameStr: String = name;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
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
			final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
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
		final result: ExtractResult = ExtractVar.extractVar(source, loc.line, loc.col, nameStr, plugin, exactTo);
		switch result {
			case Ok(text):
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr('apq extract-var: wrote $filePath\n');
				} else
					CliEdit.previewEdit(op, filePath, text);
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq extract-var: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printExtractVarUsage(): Void {
		CliIo.sysPrint("Usage: apq extract-var <file> (<line>:<col> | --match '<expr-pattern>') <name> [--write]\n");
		CliUsage.printOptionsWriteLangHelp();
		CliIo.sysPrint('Scope-correct, format-preserving extract-variable — the inverse of\n');
		CliIo.sysPrint('inline. The expression starting at <line>:<col> is hoisted into a fresh\n');
		CliIo.sysPrint('local `final <name> = <expr>;` inserted on its own line immediately\n');
		CliIo.sysPrint('before the nearest enclosing block-level statement (at that statement\'s\n');
		CliIo.sysPrint('indentation), and the expression occurrence is replaced with <name>.\n');
		CliIo.sysPrint('The cursor must point at the FIRST token of an expression; the\n');
		CliIo.sysPrint('outermost expression starting there is selected. The enclosing\n');
		CliIo.sysPrint('statement must be a direct child of a { } block — an expression buried\n');
		CliIo.sysPrint('in a braceless branch is refused. <line>:<col> uses the same column\n');
		CliIo.sysPrint('convention `apq refs` prints. The rewrite is verified to re-parse; a\n');
		CliIo.sysPrint('cursor not on an expression start, an enclosing statement outside a\n');
		CliIo.sysPrint('block, or an unparseable result exits non-zero with the file untouched.\n');
	}

}
