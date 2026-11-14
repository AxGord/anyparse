package unit.cli;

import unit.cli.CliFixture.CliRun;
#if nodejs
import sys.io.File;
#end

/**
 * `apq move` end to end: an arm whose find edits the last segment of a qualified path the move re-packages still cuts a
 * type that exists afterwards.
 */
@:nullSafety(Strict)
class MoveQualifiedSegmentFollowCliTest extends Test {

	private static final CONFIG: String = '{"move":{"scope":["src"],"registries":[{"file":"arms","keys":["arms.type"],"byPackage":true,'
		+ '"members":{"records":"arms","name":"name","type":"type","member":"method","kind":"kind",'
		+ '"defaultKind":"FnMember","find":"find","replace":"replace","opaque":["force"]}}]}}\n';

	@:pin('control')
	@:killer('M-MOVE-FOLLOW-KNOWS-MODULES')
	public function testAMoveCarriesAFindOnTheLastSegmentOfThePathItRePackaged(): Void {
		assertCarriesToOldPackage('apq_follow_segment');
	}

	@:pin('control')
	@:killer('M-MOVE-FOLLOW-EXACT-MODULE')
	public function testAModuleOfAnotherPackageWhosePathEndsTheSameDoesNotStandForTheMovedOne(): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_follow_suffix', [
			{ name: 'apq.json', source: CONFIG },
			{ name: 'src/p/C.hx', source: 'package p;\n\nclass C {\n\tfunction f():Int {\n\t\treturn p.X.h();\n\t}\n}\n' },
			{ name: 'src/p/X.hx', source: 'package p;\n\nclass X {\n\tpublic static function h():Int {\n\t\treturn 1;\n\t}\n}\n' },
			{ name: 'src/r/q/Y.hx', source: 'package r.q;\n\nclass Y {}\n' },
			{ name: 'arms/p.json', source: '{"arms":[{"name":"A","type":"p.C","method":"f","find":"X","replace":"Y"}]}\n' }
		]);
		var run: Null<CliRun> = null;
		final err: String = CliFixture.captureStderr(() ->
			run = CliFixture.runIn(root, ['move', 'src/p/X.hx', '--to', 'src/q', '--write'])
		);
		final arms: String = File.getContent('$root/arms/p.json');
		CliFixture.removeDir(root);
		Assert.equals(0, run?.code);
		Assert.isTrue(err.indexOf('registry-follow: arm A:') >= 0, err);
		Assert.isTrue(arms.indexOf('"find":"X","replace":"Y"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	private static function assertCarriesToOldPackage(name: String): Void {
		#if nodejs
		final root: String = CliFixture.writeTree(name, [
			{ name: 'apq.json', source: CONFIG },
			{ name: 'src/p/C.hx', source: 'package p;\n\nclass C {\n\tfunction f():Int {\n\t\treturn p.X.h();\n\t}\n}\n' },
			{ name: 'src/p/X.hx', source: 'package p;\n\nclass X {\n\tpublic static function h():Int {\n\t\treturn 1;\n\t}\n}\n' },
			{ name: 'src/p/Y.hx', source: 'package p;\n\nclass Y {\n\tpublic static function h():Int {\n\t\treturn 2;\n\t}\n}\n' },
			{ name: 'arms/p.json', source: '{"arms":[{"name":"A","type":"p.C","method":"f","find":"X","replace":"Y"}]}\n' }
		]);
		final run: CliRun = CliFixture.runIn(root, ['move', 'src/p/X.hx', '--to', 'src/q', '--write']);
		final moved: String = File.getContent('$root/src/p/C.hx');
		final arms: String = File.getContent('$root/arms/p.json');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(moved.indexOf('return q.X.h();') >= 0, moved);
		Assert.isTrue(arms.indexOf('"find":"q.X","replace":"p.Y"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

}
