package anyparse.query.cli.command;

import anyparse.query.MoveSymbol;
import anyparse.query.cli.CliContext;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq move-member` — move members to another type (any package if all static), rewriting call sites.
 *
 * A `--scope` EDIT: the answer depends on files other than the one it rewrites, so the
 * scope is collected first and the result leaves through `CliEdit`'s write / preview tail.
 */
@:nullSafety(Strict)
final class MoveMemberCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'move-member';
	}

	public function summary(): String {
		return 'Move members to another type (any package if all static), rewriting call sites';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runMoveMember(args);
	}

	public function usage(): Void {
		printMoveMemberUsage();
	}

	private static function runMoveMember(args: Array<String>): Int {
		var lang: String = 'haxe';
		var srcType: Null<String> = null;
		var destType: Null<String> = null;
		var scopeDir: Null<String> = null;
		var via: Null<String> = null;
		var closure: Bool = false;
		var scaffold: Bool = false;
		var write: Bool = false;
		var srcFile: Null<String> = null;
		var memberArg: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--type':
					srcType = CliArgs.expectValue(args, ++i, '--type');
				case '--to':
					destType = CliArgs.expectValue(args, ++i, '--to');
				case '--scope':
					scopeDir = CliArgs.expectValue(args, ++i, '--scope');
				case '--via':
					via = CliArgs.expectValue(args, ++i, '--via');
				case '--closure':
					closure = true;
				case '--scaffold':
					scaffold = true;
				case '--write':
					write = true;
				case '-h', '--help':
					printMoveMemberUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq move-member: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (srcFile == null)
						srcFile = a;
					else if (memberArg == null)
						memberArg = a;
					else {
						CliIo.stderr('apq move-member: unexpected argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (srcFile == null || memberArg == null || destType == null || scopeDir == null) {
			CliIo.stderr('apq move-member: missing required arguments\n');
			printMoveMemberUsage();
			return EXIT_USAGE;
		}
		final memberNames: Array<String> = memberArg.split(',').map(StringTools.trim).filter(n -> n != '');
		final srcFileNN: String = srcFile;
		final srcTypeName: String = srcType ?? RefactorSupport.baseNameOf(srcFileNN);
		final destTypeName: String = destType;
		final plugin: GrammarPlugin = new CachingGrammarPlugin(CliArgs.pickPlugin(lang));

		final scopeFiles: Null<Array<{ file: String, source: String }>> = CliArgs.collectScopeFiles('move-member', scopeDir, [srcFileNN]);
		if (scopeFiles == null) return EXIT_RUNTIME;

		final result: MoveResult = MoveMember.move(
			srcFileNN, srcTypeName, memberNames, destTypeName, via, closure, scaffold, scopeFiles, plugin, plugin.typeRefShape()
		);
		return MoveCommand.emitMoveResult('move-member', result, srcFileNN, srcFileNN, write, plugin);
	}

	private static function printMoveMemberUsage(): Void {
		CliIo.sysPrint('Usage: apq move-member <srcFile> <member[,member...]> --to <DestType> --scope <dir> [options]\n\n');
		CliIo.sysPrint('Move one or more members (method / var / final) to another type — the\n');
		CliIo.sysPrint('SAME package, or any package when every moved member is static. Static:\n');
		CliIo.sysPrint('Src.member -> Dest.member across the scope, bare references qualified,\n');
		CliIo.sysPrint('imports carried. Instance (sibling-fields contract):\n');
		CliIo.sysPrint('moved bodies may read final fields the destination declares under the same\n');
		CliIo.sysPrint('names; remaining bare callers are rewired through a Src field of type Dest\n');
		CliIo.sysPrint('(--via, auto-detected when unique); calls between moved members stay bare;\n');
		CliIo.sysPrint('receiver-qualified external calls (x.member()) are NOT rewritten. Atomic\n');
		CliIo.sysPrint('(all files re-parse or none).\n\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --type <Src>   Source type name (default: the file\'s main type)\n');
		CliIo.sysPrint('  --to <Dest>    Destination type name (must exist under --scope)\n');
		CliIo.sysPrint('  --scope <dir>  Rewrite scope (dir/glob; srcFile auto-included)\n');
		CliIo.sysPrint('  --via <field>  Src instance field of type Dest routing remaining callers\n');
		CliIo.sysPrint('  --closure      Auto-expand the set to instance methods it calls (transitive)\n');
		CliIo.sysPrint('  --scaffold     Generate the dest final fields + ctor and the via field wiring\n');
		CliIo.sysPrint('  --write        Apply in place (default: print per-file summary)\n');
		CliIo.sysPrint('  --lang <name>  Grammar plugin (default haxe)\n');
	}

}
