package unit.cli;

import anyparse.check.haxe.oracle.CompilerOracle;
import anyparse.query.OracleProvider.OracleOutcome;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.WriteJournal;
import anyparse.query.cli.command.RegistryFollowCommand;
import unit.cli.CliFixture.CliRun;

using StringTools;

#if nodejs
import sys.io.File;
#end

/**
 * Every write op carries the registry fragments of the members it rewrote, from the texts it held, inside the run's write journal.
 */
@:nullSafety(Strict)
class RegistryFollowWriteCliTest extends Test {

	private static final CONFIG: String = '{"move":{"scope":["src"],"registries":[{"file":"arms","keys":["arms.type"],"byPackage":true,'
		+ '"members":{"records":"arms","name":"name","type":"type","member":"method","kind":"kind",'
		+ '"defaultKind":"FnMember","find":"find","replace":"replace","opaque":["force"]}}]}}\n';

	/** `p.D` with a static `h` and an empty `p.E` in its module: what a `move-member h --to E` moves between. */
	private static final D_WITH_E: { name: String, source: String } = {
		name: 'src/p/D.hx',
		source: 'package p;\n\nclass D {\n\tpublic static function h():Int {\n\t\treturn 1;\n\t}\n}\n\nclass E {}\n'
	};

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

	@:pin('control')
	@:killer('M-EDIT-TAIL-FOLLOWS-REGISTRY')
	public function testPatchCarriesAFragmentOfTheTextItReplaced(): Void {
		#if nodejs
		final arms: String = armsAfter(
			'apq_follow_patch', 'var x = 1;\n\t\treturn x + 2;', '"find":"x + 2","replace":"x - 2"',
			[{ name: 'payload.txt', source: 'x + 2\n====\nx + 3\n' }],
			[
				'patch',
				'src/p/C.hx',
				'--select',
				'FnMember:f',
				'--from-file',
				'payload.txt',
				'--write'
			]
		);
		Assert.isTrue(arms.indexOf('"find":"x + 3","replace":"x - 3"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-EDIT-TAIL-FOLLOWS-REGISTRY')
	public function testReplaceNodeCarriesAFragmentOverTheNodeItReplaced(): Void {
		#if nodejs
		final arms: String = armsAfter(
			'apq_follow_replace', 'var x = 1;\n\t\tif (a) x = 4;\n\t\treturn x;', '"find":"if (a) x = 4","replace":"if (!a) x = 4"', [],
			[
				'replace-node',
				'src/p/C.hx',
				'--match',
				'x = 4',
				'--kind',
				'ExprStmt',
				'x = 6;',
				'--write'
			]
		);
		Assert.isTrue(arms.indexOf('"find":"if (a) x = 6","replace":"if (!a) x = 6"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-EDIT-TAIL-FOLLOWS-REGISTRY')
	public function testExtractMethodCarriesAFragmentAcrossTheRunItLifted(): Void {
		#if nodejs
		final arms: String = armsAfter(
			'apq_follow_method', 'var x = 1;\n\t\tx = x + 4;\n\t\treturn x * 2;',
			'"find":"x + 4;\\n\\t\\treturn x * 2","replace":"x + 5;\\n\\t\\treturn x * 2"', [],
			['extract-method', 'src/p/C.hx', '5:3', '6:13', 'g', '--write']
		);
		Assert.isTrue(arms.indexOf('final x = g();') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-RENAME-LOCAL-FOLLOWS-REGISTRY')
	public function testRenameOfALocalCarriesAFragmentReadingIt(): Void {
		#if nodejs
		final arms: String = armsAfter(
			'apq_follow_rename_local', 'var x = 1;\n\t\treturn x + 2;', '"find":"x + 2","replace":"x - 2"', [],
			['rename', 'src/p/C.hx', '--select', 'FnMember:f >> VarStmt:x', 'y', '--write']
		);
		Assert.isTrue(arms.indexOf('"find":"y + 2","replace":"y - 2"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-RENAME-IN-FILE-FOLLOWS-REGISTRY')
	public function testAnInFileRenameOfATypeCarriesAFragmentNamingIt(): Void {
		#if nodejs
		final arms: String = armsAfter(
			'apq_follow_rename_type', 'return Sub.h() + 2;\n\t}\n}\n\nclass Sub {\n\tpublic static function h():Int {\n\t\treturn 1;',
			'"find":"return Sub.h() + 2","replace":"return Sub.h() - 2"', [],
			['rename', 'src/p/C.hx', '--select', 'ClassDecl:Sub', 'Leaf', '--write']
		);
		Assert.isTrue(arms.indexOf('"find":"return Leaf.h() + 2","replace":"return Leaf.h() - 2"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-RENAME-SCOPE-FOLLOWS-REGISTRY')
	public function testARenameOfATypeAcrossAScopeCarriesAFragmentNamingIt(): Void {
		#if nodejs
		final arms: String = armsAfter(
			'apq_follow_rename_scope', 'return D.Sub.h() + 2;', '"find":"return D.Sub.h() + 2","replace":"return D.Sub.h() - 2"',
			[
				{
					name: 'src/p/D.hx',
					source: 'package p;\n\nclass D {}\n\nclass Sub {\n\tpublic static function h():Int {\n\t\treturn 1;\n\t}\n}\n'
				}
			],
			[
				'rename',
				'src/p/D.hx',
				'--select',
				'ClassDecl:Sub',
				'Leaf',
				'--scope',
				'src',
				'--write'
			]
		);
		Assert.isTrue(arms.indexOf('"find":"return D.Leaf.h() + 2","replace":"return D.Leaf.h() - 2"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-FOLLOW-RENAMED-MEMBER-QUIET')
	public function testRenameOfTheArmsOwnMemberRenamesItsRecordAndNamesNothing(): Void {
		#if nodejs
		final root: String = project('apq_follow_rename_own', 'return 1 + 2;', '"find":"1 + 2","replace":"1 - 2"', []);
		var run: Null<CliRun> = null;
		final err: String = CliFixture.captureStderr(() -> run = CliFixture.runIn(root, [
			'rename',
			'src/p/C.hx',
			'--select',
			'FnMember:f',
			'g',
			'--scope',
			'src',
			'--write'
		]));
		final arms: String = File.getContent('$root/arms/p.json');
		CliFixture.removeDir(root);
		Assert.equals(0, run?.code, err);
		Assert.isTrue(arms.indexOf('"method":"g","find":"1 + 2","replace":"1 - 2"') >= 0, arms);
		Assert.isFalse(err.contains('registry-follow'), err);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-EXTRACT-VAR-FOLLOWS-REGISTRY')
	public function testExtractVarCarriesAFragmentOverTheExpressionItNamed(): Void {
		#if nodejs
		final arms: String = armsAfter(
			'apq_follow_var', 'var x = 1;\n\t\treturn x * 2 + 7;', '"find":"return x * 2 + 7","replace":"return x * 2 - 7"', [],
			['extract-var', 'src/p/C.hx', '--match', 'x * 2', 'd', '--write']
		);
		Assert.isTrue(arms.indexOf('"find":"return d + 7","replace":"return d - 7"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-EXTRACT-CONSTANT-FOLLOWS-REGISTRY')
	public function testExtractConstantIntoTheTypeCarriesAFragmentOverTheLiteral(): Void {
		#if nodejs
		final arms: String = armsAfter(
			'apq_follow_constant', 'trace(\'hi\');\n\t\treturn 1;', '"find":"trace(\'hi\')","replace":"trace(\'ho\')"', [],
			[
				'extract-constant',
				'src/p/C.hx',
				'--type',
				'C',
				'--name',
				'HI',
				'--literal',
				'hi',
				'--write'
			]
		);
		Assert.isTrue(arms.indexOf('"find":"trace(HI)"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-EXTRACT-CONSTANT-INTO-FOLLOWS-REGISTRY')
	public function testExtractConstantIntoAModuleCarriesAFragmentOverTheLiteral(): Void {
		#if nodejs
		final arms: String = armsAfter(
			'apq_follow_constant_into', 'trace(\'hi\');\n\t\treturn 1;', '"find":"trace(\'hi\')","replace":"trace(\'ho\')"', [],
			[
				'extract-constant',
				'src',
				'--into',
				'src/p/K.hx',
				'--name',
				'HI',
				'--literal',
				'hi',
				'--write'
			]
		);
		Assert.isTrue(arms.indexOf('"find":"trace(K.HI)"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-EXTRACT-CONSTANT-TO-FOLLOWS-REGISTRY')
	public function testExtractConstantToATypeCarriesAFragmentOverTheAddressedLiteral(): Void {
		#if nodejs
		final arms: String = armsAfter(
			'apq_follow_constant_to', 'trace(\'hi\');\n\t\treturn 1;', '"find":"trace(\'hi\')","replace":"trace(\'ho\')"', [],
			[
				'extract-constant',
				'src/p/C.hx',
				'--match',
				'\'hi\'',
				'--name',
				'HI',
				'--to',
				'C',
				'--write'
			]
		);
		Assert.isTrue(arms.indexOf('"find":"trace(C.HI)"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-MOVE-MEMBER-FOLLOWS-REGISTRY')
	public function testMoveMemberCarriesAFragmentThroughTheReceiverItRepointed(): Void {
		#if nodejs
		final arms: String = armsAfter(
			'apq_follow_move_member', 'return D.h() + 2;', '"find":"return D.h() + 2","replace":"return D.h() - 2"', [D_WITH_E],
			['move-member', 'src/p/D.hx', 'h', '--to', 'E', '--scope', 'src', '--write']
		);
		Assert.isTrue(arms.indexOf('"find":"return E.h() + 2","replace":"return E.h() - 2"') >= 0, arms);
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	/**
	 * The stated rule: a write op carries its fragments inside the run's write journal, so a move whose typecheck refuses
	 * it puts the carried arm back with the files it moved.
	 */
	@:pin('control')
	@:killer('M-FOLLOW-WRITE-JOURNALED')
	public function testAMoveItsTypecheckRefusesPutsTheCarriedFragmentBack(): Void {
		#if nodejs
		final root: String = project('apq_follow_refused', 'return D.h() + 2;', '"find":"return D.h() + 2","replace":"return D.h() - 2"', [
			D_WITH_E,
			// Outside the move's scope, so its call is not repointed and the build goes red.
			{ name: 'other/O.hx', source: 'class O {\n\tstatic function main() {\n\t\ttrace(p.D.h());\n\t}\n}\n' },
			{ name: 'build.hxml', source: '-cp src\n-cp other\n-main O\np.C\n' }
		], true);
		final original: String = File.getContent('$root/arms/p.json');
		if (!CompilerOracle.typecheck('build.hxml', root).match(Confirmed)) {
			CliFixture.removeDir(root);
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		var run: Null<CliRun> = null;
		final err: String = CliFixture.captureStderr(() -> run = CliFixture.runIn(root, [
			'move-member',
			'src/p/D.hx',
			'h',
			'--to',
			'E',
			'--scope',
			'src',
			'--write',
			'--verify'
		]));
		final arms: String = File.getContent('$root/arms/p.json');
		CliFixture.removeDir(root);
		Assert.equals(1, run?.code, err);
		Assert.isTrue(err.indexOf('registry-follow: 2 fragment(s) in 1 file(s)') >= 0, 'the move carried the arm: $err');
		Assert.equals(original, arms, 'the refused move put the carried arm back');
		#else
		Assert.pass('the scratch project needs the nodejs target');
		#end
	}

	#if nodejs
	/** A project whose `p.C.f` holds `body` and whose arm `A` on it cuts `cut`; `oracle` names `build.hxml` as its compiler oracle. */
	private static function project(
		name: String, body: String, cut: String, more: Array<{ name: String, source: String }>, oracle: Bool = false
	): String {
		final config: String = oracle ? '{"compilerOracle":"build.hxml",${CONFIG.substr(1)}' : CONFIG;
		return CliFixture.writeTree(name, [
			{ name: 'apq.json', source: config },
			{ name: 'src/p/C.hx', source: 'package p;\n\nclass C {\n\tfunction f(a:Bool, b:Bool, c:Bool):Int {\n\t\t$body\n\t}\n}\n' },
			{ name: 'arms/p.json', source: '{"arms":[{"name":"A","type":"p.C","method":"f",$cut}]}\n' }
		].concat(more));
	}
	/** The arm document `arms/p.json` after `args` ran in a `project(name, body, cut, more)`, the run's exit asserted 0. */
	private static function armsAfter(
		name: String, body: String, cut: String, more: Array<{ name: String, source: String }>, args: Array<String>
	): String {
		final root: String = project(name, body, cut, more);
		final run: CliRun = CliFixture.runIn(root, args);
		final arms: String = File.getContent('$root/arms/p.json');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		return arms;
	}
	#end

}
