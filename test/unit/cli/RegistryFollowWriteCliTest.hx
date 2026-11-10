package unit.cli;

import anyparse.query.cli.CliArgs;
import anyparse.query.cli.WriteJournal;
import anyparse.query.cli.command.RegistryFollowCommand;
import unit.cli.CliFixture.CliRun;

using StringTools;

#if nodejs
import sys.io.File;
#end

/** `fmt --write`, `lint --fix` and `move` carry the registry fragments of the members they rewrote, from the texts they held. */
@:nullSafety(Strict)
class RegistryFollowWriteCliTest extends Test {

	private static final CONFIG: String = '{"move":{"scope":["src"],"registries":[{"file":"arms","keys":["arms.type"],"byPackage":true,'
		+ '"members":{"records":"arms","name":"name","type":"type","member":"method","kind":"kind",'
		+ '"defaultKind":"FnMember","find":"find","replace":"replace","opaque":["force"]}}]}}\n';

	@:pin('control')
	@:killer('M-FMT-WRITE-FOLLOWS-REGISTRY')
	public function testFmtWriteCarriesAFragmentOfTheMemberItReformatted(): Void {
		#if nodejs
		final root: String = project('apq_follow_fmt', 'return a&&b||c;', '"find":"a&&b||c","replace":"a||b||c"', []);
		final run: CliRun = CliFixture.runIn(root, ['fmt', 'src', '--write']);
		final arms: String = File.getContent('$root/arms/p.json');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(arms.indexOf('"find":"a && b || c"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-LINT-FIX-FOLLOWS-REGISTRY')
	public function testLintFixCarriesAFragmentThroughTheRenameItMade(): Void {
		#if nodejs
		final root: String = project(
			'apq_follow_lint', 'var BadName = 1;\n\t\treturn BadName + 2;', '"find":"BadName + 2","replace":"BadName - 2"', []
		);
		final run: CliRun = CliFixture.runIn(root, ['lint', 'src', '--fix', '--rule', 'naming', '--no-oracle']);
		final arms: String = File.getContent('$root/arms/p.json');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(arms.indexOf('"find":"badName + 2","replace":"badName - 2"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-MOVE-FOLLOWS-REGISTRY')
	public function testAMoveCarriesAFragmentThroughAPathItQualified(): Void {
		#if nodejs
		final root: String = project(
			'apq_follow_move', 'return D.Sub.h() + 2;', '"find":"return D.Sub.h() + 2","replace":"return D.Sub.h() - 2"',
			[
				{
					name: 'src/p/D.hx',
					source: 'package p;\n\nclass D {}\n\nclass Sub {\n\tpublic static function h():Int {\n\t\treturn 1;\n\t}\n}\n'
				}
			]
		);
		final run: CliRun = CliFixture.runIn(root, ['move', 'src/p/C.hx', '--to', 'src/q', '--write']);
		final arms: String = File.getContent('$root/arms/q.json');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(arms.indexOf('"find":"return p.D.Sub.h() + 2","replace":"return p.D.Sub.h() - 2"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-FOLLOW-WRITE-NAMES-UNCARRIED')
	public function testAFragmentTheWriteCannotCarryIsNamedAndTheWriteStands(): Void {
		#if nodejs
		final root: String = project('apq_follow_named', 'return a&&b||c;', '"find":"nothing here","replace":"x"', []);
		var run: Null<CliRun> = null;
		final err: String = CliFixture.captureStderr(() -> run = CliFixture.runIn(root, ['fmt', 'src', '--write']));
		final arms: String = File.getContent('$root/arms/p.json');
		CliFixture.removeDir(root);
		Assert.equals(0, run?.code);
		Assert.isTrue(err.indexOf('apq fmt: registry-follow: arm A:') >= 0, err);
		Assert.isTrue(arms.indexOf('"find":"nothing here"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-FOLLOW-WRITE-JOURNALED')
	public function testTheRegistryRewriteIsPutBackWithTheWriteJournal(): Void {
		#if nodejs
		final root: String = project('apq_follow_journal', 'return a&&b||c;', '"find":"a&&b||c","replace":"a||b||c"', []);
		final module: String = '$root/src/p/C.hx';
		final before: String = File.getContent(module);
		final original: String = File.getContent('$root/arms/p.json');
		final journal: WriteJournal = new WriteJournal();
		WriteJournal.during(journal, () -> {
			RegistryFollowCommand.followWrite('fmt', [
				{ path: module, before: before, after: before.replace('a&&b||c', 'a && b || c') }
			], CliArgs.pickPluginFor('haxe', module));
			return 0;
		});
		final carried: String = File.getContent('$root/arms/p.json');
		journal.rollback();
		final restored: String = File.getContent('$root/arms/p.json');
		CliFixture.removeDir(root);
		Assert.notEquals(original, carried, 'the follow re-spelled the arm');
		Assert.equals(original, restored, 'a rollback of the run puts the re-spelled document back');
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	#if nodejs
	private static function project(name: String, body: String, cut: String, more: Array<{ name: String, source: String }>): String {
		return CliFixture.writeTree(name, [
			{ name: 'apq.json', source: CONFIG },
			{ name: 'src/p/C.hx', source: 'package p;\n\nclass C {\n\tfunction f(a:Bool, b:Bool, c:Bool):Int {\n\t\t$body\n\t}\n}\n' },
			{ name: 'arms/p.json', source: '{"arms":[{"name":"A","type":"p.C","method":"f",$cut}]}\n' }
		].concat(more));
	}
	#end

}
