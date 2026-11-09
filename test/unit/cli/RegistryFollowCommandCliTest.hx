package unit.cli;

import unit.cli.CliFixture.CliRun;
#if nodejs
import sys.io.File;
#end

/** `apq registry-follow` through its own argv over a scratch git repository. */
@:nullSafety(Strict)
class RegistryFollowCommandCliTest extends Test {

	private static final CONFIG: String = '{"move":{"registries":[{"file":"arms","keys":["arms.type"],"byPackage":true,"members":'
		+ '{"records":"arms","name":"name","type":"type","member":"method","kind":"kind","defaultKind":"FnMember","find":"find",'
		+ '"replace":"replace","opaque":["force"]}}]}}\n';
	private static final BEFORE: String =
		'package p;\n\nclass C {\n\tfunction f(a: Bool, b: Bool, c: Bool): Bool {\n\t\treturn a && b || c;\n\t}\n}\n';
	private static final AFTER: String =
		'package p;\n\nclass C {\n\tfunction f(a: Bool, b: Bool, c: Bool): Bool {\n\t\treturn (a && b) || c;\n\t}\n}\n';

	public function testWriteCarriesAFragmentAndExitsZero(): Void {
		#if nodejs
		final root: String = repo('apq_registry_follow_write', '"find":"b || c","replace":"b && c"');
		final run: CliRun = CliFixture.runIn(root, ['registry-follow', 'HEAD', '--write']);
		final arms: String = File.getContent('$root/arms/p.json');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(arms.indexOf('"find":"b) || c"') >= 0, arms);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	public function testAFragmentThatCannotBeCarriedExitsOneAndStays(): Void {
		#if nodejs
		final root: String = repo('apq_registry_follow_named', '"find":"nothing here","replace":"x"');
		final run: CliRun = CliFixture.runIn(root, ['registry-follow', 'HEAD', '--write']);
		final arms: String = File.getContent('$root/arms/p.json');
		CliFixture.removeDir(root);
		Assert.equals(1, run.code);
		Assert.isTrue(arms.indexOf('"find":"nothing here"') >= 0, arms);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	public function testAStagedRenameIsFollowedUnderTheModulesNewPath(): Void {
		#if nodejs
		final root: String = repo('apq_registry_follow_moved', '"find":"b || c","replace":"b && c"');
		CliFixture.git(root, ['mv', 'src/p/C.hx', 'src/p/D.hx']);
		File.saveContent('$root/arms/p.json', '{"arms":[{"name":"A","type":"p.D","method":"f","find":"b || c","replace":"b && c"}]}\n');
		final run: CliRun = CliFixture.runIn(root, ['registry-follow', 'HEAD', '--write']);
		final arms: String = File.getContent('$root/arms/p.json');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(arms.indexOf('"find":"b) || c"') >= 0, arms);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	#if nodejs
	private static function repo(name: String, cut: String): String {
		final root: String = CliFixture.writeTree(name, [
			{ name: 'apq.json', source: CONFIG },
			{ name: 'src/p/C.hx', source: BEFORE },
			{ name: 'arms/p.json', source: '{"arms":[{"name":"A","type":"p.C","method":"f",$cut}]}\n' }
		]);
		CliFixture.git(root, ['init', '-q']);
		CliFixture.git(root, ['add', '-A']);
		CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
		File.saveContent('$root/src/p/C.hx', AFTER);
		return root;
	}
	#end

}
