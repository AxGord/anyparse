package unit.cli;

import anyparse.query.Cli;
import anyparse.query.ConfigFinder;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * A directory holding both `apq.json` and its legacy name is the project's own mistake: every op says so in an error
 * naming the directory, exits 1, and leaves nothing written: a `--write` op leaves the file it was given
 * byte-identical, a creating one leaves no file or directory behind.
 */
@:nullSafety(Strict)
final class ConfigConflictCliTest extends Test {

	private static final SOURCE: String = 'package;\n\nclass A {\n\tstatic function main() {}\n}\n';

	public function testBothNamesAreOneLineAndExitOne(): Void {
		#if (sys || nodejs)
		final dir: String = conflicted();
		var code: Int = 0;
		final err: String = CliFixture.captureStderr(() -> code = Cli.run(['lint', '$dir/A.hx']));
		Assert.equals(1, code);
		Assert.equals(1, err.split('\n').filter(l -> l != '').length, err);
		Assert.stringContains('holds both', err);
		Assert.stringContains(ConfigFinder.PROJECT_CONFIG, err);
		Assert.stringContains(ConfigFinder.LEGACY_PROJECT_CONFIG, err);
		Assert.isFalse(err.indexOf('Called from') >= 0, 'no stack: $err');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAWriteOpLeavesTheFileUntouched(): Void {
		#if (sys || nodejs)
		final dir: String = conflicted();
		var code: Int = 0;
		final err: String = CliFixture.captureStderr(() -> code = Cli.run(['add-import', '$dir/A.hx', 'haxe.io.Path', '--write']));
		Assert.equals(1, code);
		Assert.stringContains('holds both', err);
		Assert.equals(SOURCE, File.getContent('$dir/A.hx'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	public function testACreatingWriteLeavesNoFileBehind(): Void {
		final dir: String = conflicted();
		var code: Int = 0;
		final err: String = CliFixture.captureStderr(() -> code = Cli.run(['new', '$dir/C.hx', '--kind', 'class', '--write']));
		Assert.equals(1, code);
		Assert.equals(1, err.split('\n').filter(l -> l.indexOf('holds both') >= 0).length, err);
		Assert.stringContains('every file put back', err);
		Assert.isFalse(FileSystem.exists('$dir/C.hx'));
		code = 0;
		final nested: String = CliFixture.captureStderr(() -> code = Cli.run(['new', '$dir/p/q/D.hx', '--kind', 'class', '--write']));
		Assert.equals(1, code);
		Assert.stringContains('every file put back', nested);
		Assert.isFalse(FileSystem.exists('$dir/p/q/D.hx'));
		Assert.isFalse(FileSystem.exists('$dir/p'), 'the created directories are gone too');
		CliFixture.removeDir(dir);
	}

	private static function conflicted(): String {
		return CliFixture.writeDir('cfgconflict', [
			{ name: 'A.hx', source: SOURCE },
			{ name: ConfigFinder.PROJECT_CONFIG, source: '{}' },
			{ name: ConfigFinder.LEGACY_PROJECT_CONFIG, source: '{}' }
		]);
	}
	#end

}
