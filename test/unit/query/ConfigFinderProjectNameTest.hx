package unit.query;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.check.LintConfig;
import anyparse.query.ConfigFinder;
import unit.cli.CliFixture;

/**
 * The project config is `apq.json`; `apqlint.json` is the recognised legacy name, same format and
 * same inheritance chain, and a directory holding both is an error rather than a silent choice.
 */
@:nullSafety(Strict)
class ConfigFinderProjectNameTest extends Test {

	@:pin('guard')
	public function testTheLegacyNameIsStillRead(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeDir('cfgname_legacy', [
			{ name: ConfigFinder.LEGACY_PROJECT_CONFIG, source: '{"resolutionLibs": ["old"]}' }
		]);
		File.saveContent('$root/Probe.hx', 'class Probe {}\n');
		Assert.same(['old'], LintConfig.discover('$root/Probe.hx').resolutionLibs());
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('guard')
	public function testTheLegacyNameInheritsThroughTheNewOne(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeDir('cfgname_chain', [
			{ name: ConfigFinder.LEGACY_PROJECT_CONFIG, source: '{"resolutionLibs": ["old"]}' }
		]);
		FileSystem.createDirectory('$root/nested');
		File.saveContent('$root/nested/${ConfigFinder.PROJECT_CONFIG}', '{"languageVersion": "4.3"}');
		File.saveContent('$root/nested/Probe.hx', 'class Probe {}\n');
		final config: LintConfig = LintConfig.discover('$root/nested/Probe.hx');
		Assert.same(['old'], config.resolutionLibs());
		Assert.equals('4.3', config.languageVersion());
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('guard')
	public function testBothNamesInOneDirectoryIsAnError(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeDir('cfgname_both', [
			{ name: ConfigFinder.PROJECT_CONFIG, source: '{}' },
			{ name: ConfigFinder.LEGACY_PROJECT_CONFIG, source: '{}' }
		]);
		File.saveContent('$root/Probe.hx', 'class Probe {}\n');
		var message: String = '';
		try
			LintConfig.discover('$root/Probe.hx')
		catch (exception: haxe.Exception)
			message = exception.message;
		Assert.stringContains('holds both', message);
		Assert.stringContains(ConfigFinder.PROJECT_CONFIG, message);
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
