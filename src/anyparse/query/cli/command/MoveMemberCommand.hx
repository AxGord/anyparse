package anyparse.query.cli.command;

import anyparse.query.ExitCode.*;
import anyparse.query.MoveSymbol;

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

	public function flags(): CliFlags {
		return new CliFlags(['--closure', '--keep-bare', '--scaffold', '--write'], ['--scope', '--to', '--type', '--via']);
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
		var keepBare: Bool = false;
		var write: Bool = false;
		var srcFile: Null<String> = null;
		var memberArg: Null<String> = null;

		for (arg in new MoveMemberCommand().flags().walk(args)) {
			final a: String = arg.token;
			switch arg.flag {
				case '--lang':
					lang = arg.value();
				case '--type':
					srcType = arg.value();
				case '--to':
					destType = arg.value();
				case '--scope':
					scopeDir = arg.value();
				case '--via':
					via = arg.value();
				case '--closure':
					closure = true;
				case '--scaffold':
					scaffold = true;
				case '--keep-bare':
					keepBare = true;
				case '--write':
					write = true;
				case '-h', '--help':
					printMoveMemberUsage();
					return EXIT_OK;
				case null:
					if (srcFile == null) {
						srcFile = a;
					} else if (memberArg == null) {
						memberArg = a;
					} else {
						CliIo.stderr('apq move-member: unexpected argument "$a"\n');
						return EXIT_USAGE;
					}
			}
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
			srcFileNN, srcTypeName, memberNames, destTypeName, via, closure, scaffold, scopeFiles, plugin, plugin.typeRefShape(), keepBare
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
		CliIo.sysPrint('(--via, auto-detected when unique), and so are receiver-qualified callers\n');
		CliIo.sysPrint('whose receiver is provably a Src (g.m() -> g.via.m(); unprovable = refused);\n');
		CliIo.sysPrint('fields only the moved members use move along; calls between moved members\n');
		CliIo.sysPrint('stay bare. Atomic (all files re-parse or none).\n\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --type <Src>   Source type name (default: the file\'s main type)\n');
		CliIo.sysPrint('  --to <Dest>    Destination type name (must exist under --scope)\n');
		CliIo.sysPrint('  --scope <dir>  Rewrite scope (dir/glob; srcFile auto-included)\n');
		CliIo.sysPrint('  --via <field>  Src instance field of type Dest routing remaining callers\n');
		CliIo.sysPrint('  --closure      Auto-expand the set to instance methods it calls (transitive)\n');
		CliIo.sysPrint('  --scaffold     Generate the dest final fields + ctor and the via field wiring\n');
		CliIo.sysPrint('  --keep-bare    Keep bare static callers in the source bare via `import <Dest>.*;`\n');
		CliIo.sysPrint('  --write        Apply in place (default: print per-file summary)\n');
		CliIo.sysPrint('  --lang <name>  Grammar plugin (default haxe)\n');
	}

}
