package anyparse.query.cli.command;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.cli.CliContext;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq introduce-parameter-object` — fold contiguous params into one object param.
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class IntroduceParameterObjectCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'introduce-parameter-object';
	}

	public function summary(): String {
		return 'Fold contiguous params into one object param';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runIntroduceParameterObject(args);
	}

	public function usage(): Void {
		printIntroduceParameterObjectUsage();
	}

	private static function runIntroduceParameterObject(args: Array<String>): Int {
		final op: String = 'introduce-parameter-object';
		var lang: String = 'haxe';
		var params: Null<String> = null;
		var typeName: Null<String> = null;
		var objName: Null<String> = null;
		var write: Bool = false;
		var file: Null<String> = null;
		var posSpec: Null<String> = null;
		var selectExpr: Null<String> = null;
		var matchExpr: Null<String> = null;
		var nth: Null<Int> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--params':
					params = CliArgs.expectValue(args, ++i, '--params');
				case '--as':
					typeName = CliArgs.expectValue(args, ++i, '--as');
				case '--name':
					objName = CliArgs.expectValue(args, ++i, '--name');
				case '--select':
					selectExpr = CliArgs.expectValue(args, ++i, '--select');
				case '--match':
					matchExpr = CliArgs.expectValue(args, ++i, '--match');
				case '--nth':
					nth = Std.parseInt(CliArgs.expectValue(args, ++i, '--nth'));
				case '--write':
					write = true;
				case '-h', '--help':
					printIntroduceParameterObjectUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq introduce-parameter-object: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (posSpec == null && selectExpr == null && matchExpr == null && CliArgs.isPosSpec(a))
						posSpec = a;
					else {
						CliIo.stderr('apq introduce-parameter-object: unexpected argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || params == null || typeName == null || (posSpec == null && selectExpr == null && matchExpr == null)) {
			CliIo.stderr('apq introduce-parameter-object: need <file> (<l>:<c> | --select | --match) --params a,b --as <TypeName>\n');
			printIntroduceParameterObjectUsage();
			return EXIT_USAGE;
		}
		final filePath: String = file;
		final paramsNN: String = params;
		final typeNameNN: String = typeName;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq introduce-parameter-object: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));
		final pos: Null<Position> = CliEdit.resolveAddressPos(op, source, plugin, posSpec, selectExpr, matchExpr, nth, true);
		if (pos == null) return EXIT_RUNTIME;
		final paramNames: Array<String> = paramsNN.split(',').map(StringTools.trim).filter(n -> n != '');

		// The `hxformat.json` governing THIS file: omitting it makes the source read as
		// drifted under compiled defaults, and the edit then quietly falls back to the
		// plain splice — switching the canonical-out half of `editKeepingCanonical` off
		// without saying so.
		final result: EditResult = IntroduceParameterObject.introduce(
			source, pos.line, pos.col, paramNames, typeNameNN, objName, plugin, plugin.refShape(), CliArgs.discoverFormatConfig(filePath)
		);
		switch result {
			case Ok(text):
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr(
						'apq introduce-parameter-object: folded ${paramNames.length} parameter(s) into "$typeNameNN" in $filePath\n'
					);
				} else
					CliEdit.previewEdit(op, filePath, text);
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq introduce-parameter-object: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printIntroduceParameterObjectUsage(): Void {
		CliIo.sysPrint(
			'Usage: apq introduce-parameter-object <file> (<l>:<c> | --select | --match) --params a,b --as <TypeName> [options]\n\n'
		);
		CliIo.sysPrint('Replace a contiguous run of a function\'s parameters with one object\n');
		CliIo.sysPrint('parameter of a generated typedef. The signature, the body\'s references,\n');
		CliIo.sysPrint('and every resolvable in-file call site are rewritten together.\n\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --params a,b   The contiguous parameters to fold (required)\n');
		CliIo.sysPrint('  --as <Type>    Name of the generated typedef (required)\n');
		CliIo.sysPrint('  --name <obj>   Object parameter name (default: lower-camel of the type)\n');
		CliIo.sysPrint('  --write        Apply in place (default: print the rewritten file)\n');
		CliIo.sysPrint('  --lang <name>  Grammar plugin (default haxe)\n');
	}

}
