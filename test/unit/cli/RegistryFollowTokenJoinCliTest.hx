package unit.cli;

import unit.cli.CliFixture.CliRun;
#if nodejs
import sys.io.File;
#end

/** The arm document and the stderr of a write that carried it. */
private typedef Followed = { final arms: String; final err: String; }

/**
 * A registry fragment re-spelled over a write keeps its token boundaries: a replace is never rebuilt by joining two
 * pieces whose edges are both word characters.
 */
class RegistryFollowTokenJoinCliTest extends Test {

	private static final CONFIG: String = '{"move":{"scope":["src"],"registries":[{"file":"arms","keys":["arms.type"],"byPackage":true,'
		+ '"members":{"records":"arms","name":"name","type":"type","member":"method","kind":"kind",'
		+ '"defaultKind":"FnMember","find":"find","replace":"replace","opaque":["force"]}}]}}\n';

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-REPLACE-HEAD-GLUES')
	public function testADroppedArgumentRefusesAReplaceThatWouldGlueToItsNeighbour(): Void {
		#if nodejs
		final cut: String = '"find":"g(1, 2, null, c)","replace":"g(1, 2, null, true)"';
		final after: Followed = followOf('var x = g(1, 2, null, c);\n\t\treturn x;', cut, 'g(1, 2, null, c)\n====\ng(1, 2)\n');
		assertRefused(after, cut);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('guard')
	public function testAShortenedCallRefusesAReplaceItWouldGlueToItsFlag(): Void {
		#if nodejs
		final cut: String = '"find":"k(a, true)","replace":"k(a, false)"';
		assertRefused(followOf('var x = k(a, true);', cut, 'k(a, true)\n====\nk(a)\n'), cut);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-REPLACE-REST-GLUES')
	public function testARewrittenNameKeepsTheTokenTheReplaceSharesWithIt(): Void {
		#if nodejs
		final arms: String = followOf('var x = k(1, x);', '"find":"k(1, x)","replace":"k(1, y x)"', 'k(1, x)\n====\nk(1, xx)\n').arms;
		Assert.isTrue(arms.indexOf('"find":"k(1, xx)","replace":"k(1, y xx)"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-REPLACE-HEAD-GLUES')
	public function testADoubledNameKeepsTheTokenTheReplaceSharesWithItsFind(): Void {
		#if nodejs
		final arms: String = followOf('var x = k(x, 1);', '"find":"k(x, 1)","replace":"k(x y, 1)"', 'k(x, 1)\n====\nk(xx, 1)\n').arms;
		Assert.isTrue(arms.indexOf('"find":"k(xx, 1)","replace":"k(xx y, 1)"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-REPLACE-REST-GLUES')
	public function testADroppedLeadingArgumentRefusesAReplaceThatWouldGlueToTheRest(): Void {
		#if nodejs
		final cut: String = '"find":"k(true, a)","replace":"k(false, a)"';
		assertRefused(followOf('var x = k(true, a);', cut, 'k(true, a)\n====\nk(a)\n'), cut);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	private static function assertRefused(after: Followed, cut: String): Void {
		Assert.isTrue(after.err.indexOf('arm A: no re-spelling of its cut applies') >= 0, after.err);
		Assert.equals(armRecord(cut), after.arms);
	}

	private static function armRecord(cut: String): String {
		return '{"arms":[{"name":"A","type":"p.C","method":"f",$cut}]}\n';
	}

	#if nodejs
	/** The arm document after a `patch` of `body` by `payload` in a project whose arm `A` cuts `cut`, the run's exit asserted 0. */
	private static function followOf(body: String, cut: String, payload: String): Followed {
		final root: String = CliFixture.writeTree('apq_follow_token_join', [
			{ name: 'apq.json', source: CONFIG },
			{ name: 'src/p/C.hx', source: 'package p;\n\nclass C {\n\tfunction f(a:Bool, b:Bool, c:Bool):Int {\n\t\t$body\n\t}\n}\n' },
			{ name: 'arms/p.json', source: armRecord(cut) },
			{ name: 'payload.txt', source: payload }
		]);
		var run: Null<CliRun> = null;
		final err: String = CliFixture.captureStderr(() -> run = CliFixture.runIn(root, [
			'patch',
			'src/p/C.hx',
			'--select',
			'FnMember:f',
			'--from-file',
			'payload.txt',
			'--write'
		]));
		final arms: String = File.getContent('$root/arms/p.json');
		CliFixture.removeDir(root);
		Assert.equals(0, run?.code);
		return { arms: arms, err: err };
	}
	#end

}
