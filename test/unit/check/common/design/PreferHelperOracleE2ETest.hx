package unit.check.common.design;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.haxe.oracle.CompilerOracle;
import anyparse.proc.ProcessSpawn;
import anyparse.query.Cli;
import anyparse.query.OracleProvider.OracleOutcome;
import unit.cli.CliFixture;

/**
 * `prefer-helper` over a function-parameter helper end to end through `apq lint --fix` against the real compiler: a
 * findMap descent becomes a return of the helper call with its projection as a lambda, and the program prints what it
 * printed. A projection reading a field the copy's guard narrowed loses that narrowing inside the lambda, so the compiler
 * rejects that one call, the verifier reverts it alone, and a report run still names it.
 */
@:nullSafety(Strict)
final class PreferHelperOracleE2ETest extends Test {

	#if (sys || nodejs)
	private static final ARRAYS: String = 'package util;\n\nclass Arrays {\n\t@:preferHelper\n'
		+ '\tpublic static function findMap<T, R>(xs:Iterable<T>, f:T->Null<R>):Null<R> {\n'
		+ '\t\tfor (x in xs) {\n\t\t\tfinal y:Null<R> = f(x);\n\t\t\tif (y != null) return y;\n\t\t}\n\t\treturn null;\n\t}\n}\n';
	private static final MAIN: String = [
		'import util.Arrays;',
		'',
		'@:nullSafety(Loose)',
		'class Main {',
		'\tvar o:Null<String> = \'x\';',
		'',
		'\tfunction new() {}',
		'',
		'\tstatic function name(c:Int):Null<String> {',
		'\t\treturn c > 1 ? \'n$$c\' : null;',
		'\t}',
		'',
		'\tfunction first(xs:Array<Int>):Null<String> {',
		'\t\tfor (c in xs) {',
		'\t\t\tfinal found = name(c);',
		'\t\t\tif (found != null) return found;',
		'\t\t}',
		'\t\treturn null;',
		'\t}',
		'',
		'\tfunction upper(xs:Array<Int>):Null<String> {',
		'\t\tif (o == null) return null;',
		'\t\tfor (c in xs) {',
		'\t\t\tfinal f = c > 1 ? o.toUpperCase() : null;',
		'\t\t\tif (f != null) return f;',
		'\t\t}',
		'\t\treturn null;',
		'\t}',
		'',
		'\tstatic function main():Void {',
		'\t\tfinal m:Main = new Main();',
		'\t\tSys.println(m.first([1, 2, 3]));',
		'\t\tSys.println(m.upper([1, 2]));',
		'\t}',
		'}'
	].join('\n')
		+ '\n';
	private static final CONFIG: String =
		'{"compilerOracle":"check.hxml","resolutionRoots":["."],"rules":{"prefer-helper":{"marker":"@:preferHelper"}}}';
	private static final HXML: String = '-cp .\n-main Main\n--interp\n';
	private static inline final BUFFER: Int = 1 << 20;
	#end

	@:pin('seam')
	public function testTheOracleKeepsTheDescentAndRevertsTheNarrowedProjection(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = tree([
			{ name: 'Main.hx', source: MAIN },
			{ name: 'util/Arrays.hx', source: ARRAYS },
			{ name: 'apq.json', source: CONFIG }
		]);
		if (dir == null) return;
		final before: String = run(dir);
		final fixLog: String = CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'prefer-helper', '$dir/Main.hx']));
		final after: String = File.getContent('$dir/Main.hx');
		Assert.isTrue(after.indexOf('\t\treturn Arrays.findMap(xs, c -> name(c));\n') >= 0, after);
		Assert.isTrue(
			after.indexOf('\t\t\tfinal f = c > 1 ? o.toUpperCase() : null;\n') >= 0, 'the narrowed projection is reverted: $after'
		);
		Assert.isTrue(fixLog.indexOf('1 edit(s) kept, 1 reverted') >= 0, fixLog);
		final report: String = CliFixture.captureStdout(() ->
			Cli.run(['lint', '--all', '--no-oracle', '--rule', 'prefer-helper', '$dir/Main.hx'])
		);
		Assert.isTrue(report.indexOf('repeats the body of util.Arrays.findMap(xs, f)') >= 0, report);
		Assert.equals('n2\nX\n', before);
		Assert.equals(before, run(dir), 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** The fixture tree with `check.hxml`, or null — with the scenario passed — when no compiler typechecks it. */
	private static function tree(files: Array<{ name: String, source: String }>): Null<String> {
		final dir: String = CliFixture.writeTree('preferhelper', files.concat([{ name: 'check.hxml', source: HXML }]));
		if (CompilerOracle.typecheck('check.hxml', dir).match(Confirmed)) return dir;
		CliFixture.removeDir(dir);
		Assert.pass('haxe unavailable — skipped');
		return null;
	}

	private static function run(dir: String): String {
		return ProcessSpawn.run(['check.hxml'], dir, BUFFER).out;
	}
	#end

}
