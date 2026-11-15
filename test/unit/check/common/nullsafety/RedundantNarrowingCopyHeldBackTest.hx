package unit.check.common.nullsafety;

import anyparse.check.LintConfig.ConfigNote;
import anyparse.check.common.nullsafety.RedundantNarrowingCopy;
import unit.cli.CliFixture;

/**
 * A run whose project declares no `closedWorld` leaves every copy of a field to the rule's thread facts and flags none:
 * the run says so in its notes instead of reporting an unexplained clean result.
 */
class RedundantNarrowingCopyHeldBackTest extends Test {

	#if (sys || nodejs)
	private static final BOX: String = 'class Box { public function new() {} public function m():Void {} }';
	private static final CLASS: String =
		'class C { var box:Null<Box>; public function new() {} function a():Void {\n final l:Null<Box> = box;\n if (l != null) l.m(); } }';

	@:pin('control')
	@:killer('M-RNC-HELD-BACK-SILENT')
	public function testAProjectThatClosesNothingSaysItHeldTheCopyBack(): Void {
		final notes: Array<ConfigNote> = [];
		final found: Int = run('{}', notes, []);
		Assert.equals(0, found);
		Assert.isTrue(
			notes.filter(n -> n.message.indexOf('declares no thread-safety') >= 0).length > 0, 'the run names the missing declaration'
		);
	}

	@:pin('control')
	@:killer('M-RNC-HELD-BACK-PARTIAL')
	public function testARunOverPartOfAClosedProjectSaysSoAndAsksForNoDeclaration(): Void {
		final notes: Array<ConfigNote> = [];
		final found: Int = run('{"rules":{"thread-safety":{"closedWorld":true}}}', notes, [{ name: 'Left.hx', source: 'class Left {}' }]);
		Assert.equals(0, found);
		final said: Array<ConfigNote> = notes.filter(n -> n.message.indexOf('leaves part of the project') >= 0);
		Assert.equals(1, said.length, 'the run names the partial coverage');
		Assert.equals(-1, said[0].message.indexOf('declares no'), 'it does not ask for what the config already declares');
		Assert.equals(0, notes.filter(n -> n.message.indexOf('declares no') >= 0).length);
	}

	@:pin('control')
	@:killer('M-RNC-HELD-BACK-ALWAYS')
	public function testAProjectThatClosesTheWorldHasNothingToSay(): Void {
		final notes: Array<ConfigNote> = [];
		final found: Int = run('{"rules":{"thread-safety":{"closedWorld":true}}}', notes, []);
		Assert.equals(1, found);
		Assert.equals(0, notes.length, 'a run that judged every copy has nothing to say');
	}

	/** The run over the project's modules, with `onDisk` files beside them that the run does not hold. */
	private static function run(config: String, notes: Array<ConfigNote>, onDisk: Array<{ name: String, source: String }>): Int {
		var found: Int = 0;
		final dir: String = CliFixture.writeDir('narrowingheld', [{ name: 'apq.json', source: config }].concat(onDisk));
		final files: Array<{ file: String, source: String }> = QueryTestHelpers.rootModules([BOX, CLASS])
			.map(entry -> { file: '$dir/${entry.file}', source: entry.source });
		CliFixture.always(
			CliFixture.removeDir.bind(dir),
			() -> found = Linter.run(files, new HaxeQueryPlugin(), [new RedundantNarrowingCopy()], null, false, null, notes).length
		);
		return found;
	}
	#else
	public function testNonSysTarget(): Void {
		Assert.pass('non-sys target');
	}
	#end

}
