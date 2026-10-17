package anyparse.query.cli.command;

import anyparse.query.ReplaceNode.ReplaceTarget;
import anyparse.query.cli.CliContext;
import anyparse.query.cli.PostWriteFix;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq remove-element` — remove a sibling element by cursor (inverse of add-element).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class RemoveElementCommand implements CliCommand implements PostWriteFix {

	/** The op's name, as the registry lists it and every address / edit helper is told it. */
	private static inline final OP: String = 'remove-element';

	public function new() {}

	public function name(): String {
		return OP;
	}

	public function summary(): String {
		return 'Remove a sibling element by cursor (inverse of add-element)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runRemoveElement(args, ctx.postWriteFix);
	}

	public function usage(): Void {
		printRemoveElementUsage();
	}

	/**
	 * `apq remove-element <file> <line>:<col> [--reformat] [--write]` — remove
	 * the sibling element whose first token is at `line:col` (a statement /
	 * case / array / object / call-arg element / member), with its modifier /
	 * meta group, writer-formatted + re-parse-validated. The structural
	 * inverse of `add-element`; same column convention `apq refs` prints. A leading
	 * doc comment goes with the element unless `--keep-doc` says otherwise.
	 */
	private static function runRemoveElement(args: Array<String>, fix: Bool): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var withDoc: Bool = true;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var selectExpr: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;
		var kind: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--select':
					selectExpr = CliArgs.expectValue(args, ++i, '--select');
				case '--match':
					matchExpr = CliArgs.expectValue(args, ++i, '--match');
				case '--nth':
					nth = Std.parseInt(CliArgs.expectValue(args, ++i, '--nth'));
				case '--kind':
					kind = CliArgs.expectValue(args, ++i, '--kind');
				case '--write':
					write = true;
				case '--reformat':
					reformat = true;
				case '--with-doc':
					// Accepted and inert: taking the doc is the default now. Kept so an
					// existing script that spells the old opt-in keeps working.
					withDoc = true;
				case '--keep-doc':
					withDoc = false;
				case '-h', '--help':
					printRemoveElementUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq remove-element: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null)
						posSpec = a;
					else {
						CliIo.stderr('apq remove-element: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || (posSpec == null && selectExpr == null && matchExpr == null)) {
			CliIo.stderr("apq remove-element: expected <file> (<line>[:<col>] | --select '<sel>' | --match '<pattern>')\n");
			printRemoveElementUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq remove-element: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		// A selector naming a bare modifier keyword is NOT an element address. It resolves to the
		// same offset a position on that keyword does, and the cursor convention then reads it as
		// the declaration's first token — so `--select 'Private'` deleted the whole declaration at
		// rc 0. `replace-node` and `remove-member` already refuse their own version of this; this
		// was the one member of the family with no guard.
		final modifier: Null<String> = CliEdit.namedModifierKeyword(source, plugin, selectExpr, matchExpr, nth);
		if (modifier != null) {
			CliIo.stderr(
				'apq remove-element: the address names the "$modifier" MODIFIER, and a modifier is not an element — removing it '
				+ 'would delete the whole declaration it precedes. Drop the keyword with `apq set-modifier <file> --select '
				+ '\'<decl>\' -$modifier`, or address the declaration itself to remove that\n'
			);
			return EXIT_RUNTIME;
		}
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		// `--kind` names the node to cut rather than its first token, so it goes through the
		// address layer `replace-node` / `patch` share — a position narrows to the innermost node
		// of the kind at the cursor, a selector or pattern lifts to its innermost enclosing one —
		// and the op removes exactly that node.
		final liftKind: Null<String> = kind;
		if (liftKind != null) {
			final target: Null<ReplaceTarget> = CliEdit.resolveEditTarget(
				OP, source, filePath, plugin, selectExpr, matchExpr, posSpec, nth, liftKind
			);
			return target == null
				? EXIT_RUNTIME
				: CliEdit.finishEdit(
					OP, filePath, write, RemoveElement.removeTarget(source, target, reformat, plugin, withDoc, optsJson), fix,
					RemoveElement.describeTarget(source, target, plugin, withDoc)
				);
		}
		final pos: Null<Position> = CliEdit.resolveAddressPos(OP, source, plugin, posSpec, selectExpr, matchExpr, nth);
		if (pos == null) return EXIT_RUNTIME;
		// The address is unambiguous — `FnMember:f` and `MetaCall:@:pin` each remove exactly
		// what they name — and the op still reported both as `wrote <file>`. That line is what
		// made an address resolving one declaration outward indistinguishable from the edit
		// that was meant: a twenty-line test with a doc and two annotations left the file and
		// nothing in the transcript said so. Naming the cut costs no behaviour and no ceremony.
		final removed: Null<String> = RemoveElement.describeRemoval(source, pos.line, pos.col, plugin, withDoc);
		return CliEdit.finishEdit(
			OP, filePath, write, RemoveElement.removeElement(source, pos.line, pos.col, reformat, plugin, withDoc, optsJson), fix, removed
		);
	}

	private static function printRemoveElementUsage(): Void {
		CliIo.sysPrint("Usage: apq remove-element <file> (<line>[:<col>] | --select '<sel>' | --match '<pattern>') [options]\n");
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Remove the sibling element at the address — a statement in a block, a case in\n');
		CliIo.sysPrint('a switch, an array / object / call-argument element, or a class member (with\n');
		CliIo.sysPrint('its modifier / meta group). The structural inverse of add-element; one\n');
		CliIo.sysPrint('separating comma is removed for comma lists. The result is writer-formatted +\n');
		CliIo.sysPrint('re-parse-validated.\n');
		CliUsage.printAddressingHelp();
		CliIo.sysPrint('                      (descendant); must resolve to exactly one node\n');
		CliIo.sysPrint("  --match '<pattern>' apq-search structural pattern ($x metavars); exactly one\n");
		CliIo.sysPrint('  --nth <k>           Pick the k-th (1-based) of several --select/--match matches\n');
		CliIo.sysPrint('  --kind <Kind>       Remove the node of that kind the address names: with --select /\n');
		CliIo.sysPrint('                      --match the innermost enclosing <Kind> (`--match \'trace($$x)\'\n');
		CliIo.sysPrint('                      --kind ExprStmt`), with a position the innermost <Kind> at it\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --keep-doc      Leave the element\'s leading doc comment behind\n');
		CliUsage.printEditOptionsTail();
		CliUsage.printPostWriteFixTail();
	}

}
