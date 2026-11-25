package unit.cli;

import anyparse.check.haxe.oracle.CompilerOracle;
import unit.cli.CliFixture.CliRun;
#if nodejs
import sys.io.File;
#end

/**
 * `apq lint --fix --changed-since <rev>` with a `compilerOracle` configured: the risky-fix phase is verified by the compiler
 * and is still narrowed to the lines the working tree changed, so a standing finding on an untouched line is not deleted
 * behind a slice's edits.
 */
@:nullSafety(Strict)
class LintChangedSinceOracleCliTest extends Test {

	@:pin('control')
	@:killer('M-RISKY-PHASE-WINDOW-DROPPED')
	public function testAStandingRedundantImportOnAnUntouchedLineIsLeftAlone(): Void {
		#if nodejs
		final root: String = repo();
		if (skipWithoutHaxe(root)) return;
		final run: CliRun = fixRun(root);
		final after: String = File.getContent('$root/Main.hx');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(after.indexOf('import Mod.Sub;') >= 0, 'the standing import above the edit is untouched: $after');
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-RISKY-PHASE-WINDOW-DROPS-ALL')
	public function testARedundantImportOnAChangedLineIsStillRemoved(): Void {
		#if nodejs
		final root: String = repo();
		if (skipWithoutHaxe(root)) return;
		final run: CliRun = fixRun(root);
		final after: String = File.getContent('$root/Main.hx');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(after.indexOf('import Mod.Sub2;') < 0, 'the import added on a changed line was removed: $after');
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** The oracle-assisted phase takes the same window: only the changed line's local gets its annotation. */
	@:pin('control')
	@:killer('M-ASSISTED-PHASE-WINDOW-DROPPED')
	public function testTheOracleAssistedPhaseAnnotatesOnlyTheChangedLine(): Void {
		#if nodejs
		final root: String = assistedRepo();
		if (skipWithoutHaxe(root)) return;
		final run: CliRun = CliFixture.runIn(root, [
			'lint',
			'Main.hx',
			'--rule',
			'explicit-local-type',
			'--fix',
			'--changed-since',
			'HEAD'
		]);
		final after: String = File.getContent('$root/Main.hx');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(after.indexOf('final a = Std.parseInt("1");') >= 0, 'the standing local keeps its inferred type: $after');
		Assert.isTrue(after.indexOf('final b:Null<Int> = Std.parseInt("3");') >= 0, 'the changed local is annotated: $after');
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	#if nodejs
	private static function main(extraImport: String): String {
		return
			'package;\n\nimport Mod;\nimport Mod.Sub;\n$extraImport\nclass Main {\n\n\tstatic function main() {\n\t\ttrace(1);\n\t}\n\n}\n';
	}

	/**
	 * A repository holding Main.hx (a module import and a sub-module import
	 * of it) and Mod.hx, Main.hx then gaining a second sub-module import.
	 */
	private static function repo(): String {
		final root: String = CliFixture.writeTree('lint_changed_since_oracle', [
			{ name: 'Main.hx', source: main('') },
			{ name: 'Mod.hx', source: 'package;\n\nclass Mod {}\n\nclass Sub {}\n\nclass Sub2 {}\n' },
			{ name: 'build.hxml', source: '-cp .\n-main Main\n' },
			{ name: 'apq.json', source: '{"compilerOracle":[{"hxml":"build.hxml","dir":"."}]}' }
		]);
		CliFixture.git(root, ['init', '-q']);
		CliFixture.git(root, ['add', '-A']);
		CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
		File.saveContent('$root/Main.hx', main('import Mod.Sub2;\n'));
		return root;
	}

	private static function skipWithoutHaxe(root: String): Bool {
		if (CompilerOracle.typecheck('build.hxml', root).match(Confirmed)) return false;
		CliFixture.removeDir(root);
		Assert.pass('haxe unavailable — skipped');
		return true;
	}

	/** Main.hx holds two un-annotated locals; the working tree then edits only the second one's initializer. */
	private static function assistedRepo(): String {
		final source: (String) -> String = second ->
			'package;\n\nclass Main {\n\n\tstatic function main() {\n\t\tfinal a = Std.parseInt("1");\n\t\ttrace(a);\n'
				+ '\t\tfinal b = Std.parseInt("$second");\n\t\ttrace(b);\n\t}\n\n}\n';
		final root: String = CliFixture.writeTree('lint_changed_since_assisted', [
			{ name: 'Main.hx', source: source('2') },
			{ name: 'build.hxml', source: '-cp .\n-main Main\n' },
			{ name: 'apq.json', source: '{"compilerOracle":[{"hxml":"build.hxml","dir":"."}]}' }
		]);
		CliFixture.git(root, ['init', '-q']);
		CliFixture.git(root, ['add', '-A']);
		CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
		File.saveContent('$root/Main.hx', source('3'));
		return root;
	}

	private static function fixRun(root: String): CliRun {
		return CliFixture.runIn(root, [
			'lint',
			'Main.hx',
			'Mod.hx',
			'--rule',
			'redundant-import',
			'--fix',
			'--changed-since',
			'HEAD'
		]);
	}
	#end

}
