package unit.dev;

import dev.ArmRegistry.ArmRegistryError;
import dev.GateTree;
import dev.MutationArm;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `dev mutation-arm`'s reading of the registry and the generated pins: each arm's cut as a `hxq patch` payload (a
 * multi-pair cut is ONE payload; a forced value is spliced after the body brace the member's own braces locate), the
 * expectations its pins make, and how the render rows are dealt into batches.
 */
@:nullSafety(Strict)
final class MutationArmTest extends Test {

	private static inline final REGISTRY: String = '{"arms": ['
		+ '{"name": "M-ONE", "type": "a.B", "method": "f", "find": "x", "replace": "y"},'
		+ '{"name": "M-PAIRS", "type": "a.B", "method": "g", "kind": "FinalMember", "find": ["p", "q"], "replace": ["P", "Q"]},'
		+ '{"name": "M-CUT", "type": "a.B", "method": "h", "find": "gone"},'
		+ '{"name": "M-ODD", "type": "a.B", "method": "h", "find": ["p", "q"], "replace": ["P"]},'
		+ '{"name": "M-FORCE", "type": "a.C", "method": "k", "force": "true"}'
		+ ']}';

	/** A tool's own code rides the composed build: the suite build compiles `tools/src` beside `src`. */
	@:pin('control')
	@:killer('M-ARM-COMPOSABLE-TOOLS-REFUSED')
	public function testAToolFileMayRideTheComposedBuild(): Void {
		Assert.isTrue(MutationArm.composable('src/a/B.hx', []));
		Assert.isTrue(MutationArm.composable('tools/src/dev/Gate.hx', []));
		Assert.isFalse(MutationArm.composable('test/unit/dev/GateTest.hx', []), 'the suite registers what it finds in test/');
	}

	@:pin('control')
	@:killer('M-ARM-COMPOSABLE-MACRO-ALLOWED')
	public function testCompileTimeCodeIsBuiltPerArm(): Void {
		Assert.isFalse(MutationArm.composable('src/anyparse/macro/Build.hx', []));
	}

	@:pin('control')
	@:killer('M-ARM-COMPOSABLE-BUILT-FILE-ALLOWED')
	public function testAFileABuildMacroReadsIsBuiltPerArm(): Void {
		Assert.isFalse(MutationArm.composable('tools/src/dev/GateRecordParser.hx', ['tools/src/dev/GateRecordParser.hx']));
		Assert.isTrue(MutationArm.composable('tools/src/dev/Gate.hx', ['tools/src/dev/GateRecordParser.hx']));
	}

	public function testEveryArmIsReadInRegistryOrder(): Void {
		Assert.same(['M-ONE', 'M-PAIRS', 'M-CUT', 'M-ODD', 'M-FORCE'], MutationArm.armNames(REGISTRY));
	}

	public function testACutIsOnePayloadWhoseSectionsAlternate(): Void {
		final cuts: Map<String, ArmCut> = MutationArm.cuts(REGISTRY, ['M-ONE', 'M-PAIRS', 'M-CUT', 'M-FORCE'], 'arms.json');
		Assert.same(Find('a.B', 'f', 'FnMember', 'x\n====\ny\n'), cuts['M-ONE'], 'a method unless the record names a kind');
		Assert.same(Find('a.B', 'g', 'FinalMember', 'p\n====\nP\n====\nq\n====\nQ\n'), cuts['M-PAIRS']);
		Assert.same(Find('a.B', 'h', 'FnMember', 'gone\n====\n\n'), cuts['M-CUT'], 'no replace deletes the fragment');
		Assert.same(Force('a.C', 'k', 'FnMember', 'true'), cuts['M-FORCE']);
	}

	public function testAnArmThatCannotBeRenderedSaysWhy(): Void {
		final cuts: Map<String, ArmCut> = MutationArm.cuts(REGISTRY, ['M-ODD', 'M-NONE'], 'arms.json');
		Assert.same(
			Unrenderable('"M-ODD" declares 2 find fragment(s) against 1 replace(s) - a multi-pair cut pairs them up'), cuts['M-ODD']
		);
		Assert.same(Unrenderable('no arm named "M-NONE" in arms.json'), cuts['M-NONE']);
	}

	public function testAForcedReturnGoesAfterTheBodyBrace(): Void {
		final member: String = 'public function f(a: Int): Bool {\n\treturn a > 0;\n}\n';
		final header: Null<String> = MutationArm.forceHeader(member);
		Assert.equals('public function f(a: Int): Bool {\n', header);
		Assert.equals('h {\n====\nh {\n\treturn false;\n', MutationArm.forcePayload('h {\n', 'false'));
	}

	@:pin('control')
	@:killer('M-FORCE-HEADER-NONCODE-BRACES')
	public function testTheBodyBraceIsTheLastOneOpeningAtDepthZero(): Void {
		Assert.equals(
			'function f(): Null<{ a: Int }> {\n', MutationArm.forceHeader('function f(): Null<{ a: Int }> {\n\treturn null;\n}'),
			'a brace of the return type is not the body'
		);
		Assert.equals(
			'function f(): Void {\n',
			MutationArm.forceHeader('function f(): Void {\n\t// a } in a comment\n\tvar s = "}" + \'{\' + ~/[}]/.source; /* } */\n}\n'),
			'braces in a comment, a string, a char and a regex are not code'
		);
	}

	public function testAMemberWhoseBodyCannotBeFoundIsRefused(): Void {
		Assert.isNull(MutationArm.forceHeader('function f(): Int { return 1; }'), 'the body opens mid-line');
		Assert.isNull(MutationArm.forceHeader('function f(): Int {\n\treturn 1;\n'), 'unbalanced');
		Assert.isNull(MutationArm.forceHeader('final x: Int = 1;'), 'no body at all');
	}

	public function testThePinsOfAnArmAreItsTestsAndItsClasses(): Void {
		final pins: PinTables = MutationArm.pinTables([
			'unit.b.BTest#testTwo :: control :: M-X,M-Y',
			'unit.a.ATest#testOne :: control :: M-X',
			'unit.a.ATest#testOne :: control :: M-X',
			'unit.c.CTest#testGuard :: guard :: ',
			'not a pin line'
		].join('\n'));
		Assert.equals('unit.a.ATest.testOne,unit.b.BTest.testTwo', pins.tests['M-X'], 'sorted, each once');
		Assert.equals('unit.a.ATest,unit.b.BTest', pins.classes['M-X']);
		Assert.equals('unit.b.BTest.testTwo', pins.tests['M-Y']);
		Assert.isFalse(pins.tests.exists(''), 'a pin naming no killer names no arm');
	}

	public function testTheBiggestFileIsDealtFirstInChunks(): Void {
		final rows: Array<String> = ['a\t1', 'b\t1', 'b\t2', 'b\t3', 'c\t1'];
		Assert.same([['b\t1', 'b\t2'], ['b\t3', 'c\t1'], ['a\t1']], MutationArm.deal(rows, 3, 2));
		Assert.same([rows.slice(1, 4).concat(['a\t1', 'c\t1'])], MutationArm.deal(rows, 1, 16), 'one batch takes everything');
		Assert.same([], MutationArm.deal([], 4, 16));
	}

	public function testTheApplyTallyCountsEveryArmOnce(): Void {
		Assert.equals('3 arms: 2 apply, 1 did not apply', MutationArm.applyTally(2, 1));
		Assert.equals('0 arms: 0 apply, 0 did not apply', MutationArm.applyTally(0, 0));
	}

	public function testApplyOnlyAnswersWhetherEveryCutStillApplies(): Void {
		TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory(Path.join([repo, 'src/a']));
			FileSystem.createDirectory(Path.join([repo, 'test/testkit/arms']));
			File.saveContent(
				Path.join([repo, 'src/a/B.hx']), 'package a;\n\nclass B {\n\n\tpublic static function f():Int {\n\t\treturn 1;\n\t}\n\n}\n'
			);
			final ok: String = '{"name": "M-OK", "type": "a.B", "method": "f", "find": "return 1;", "replace": "return 2;"}';
			final rotted: String = '{"name": "M-ROT", "type": "a.B", "method": "f", "find": "return 7;", "replace": "return 2;"}';
			File.saveContent(Path.join([repo, 'test/testkit/arms/a.json']), '{"arms": [$ok, $rotted]}');
			final applies: Int = ArmApply.applyOnly(repo, ['M-OK']);
			final rots: Int = ArmApply.applyOnly(repo, ['M-OK', 'M-ROT']);
			Assert.equals(0, applies, 'a cut that applies is a pass, and nothing is built');
			Assert.equals(1, rots, 'a find the code no longer holds fails the run');
		});
	}

	public function testAMisplacedArmIsRefusedAndTheEngineVariableIsRestored(): Void {
		TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory(Path.join([repo, 'src/a']));
			FileSystem.createDirectory(Path.join([repo, 'test/testkit/arms']));
			File.saveContent(
				Path.join([repo, 'src/a/B.hx']), 'package a;\n\nclass B {\n\n\tpublic static function f():Int {\n\t\treturn 1;\n\t}\n\n}\n'
			);
			File.saveContent(
				Path.join([repo, 'test/testkit/arms/b.json']),
				'{"arms": [{"name": "M-X", "type": "a.B", "method": "f", "find": "return 1;", "replace": "return 2;"}]}'
			);
			final before: Null<String> = Sys.getEnv('HXQ_BIN');
			Sys.putEnv('HXQ_BIN', null);
			Assert.raises(() -> ArmApply.applyOnly(repo, ['M-X']), ArmRegistryError);
			final afterUnset: Null<String> = Sys.getEnv('HXQ_BIN');
			Sys.putEnv('HXQ_BIN', '/fixture/engine.js');
			Assert.raises(() -> ArmApply.applyOnly(repo, ['M-X']), ArmRegistryError);
			final afterSet: Null<String> = Sys.getEnv('HXQ_BIN');
			Sys.putEnv('HXQ_BIN', before);
			Assert.isNull(afterUnset, 'a variable that was unset is unset again when the run throws, not left empty');
			Assert.equals('/fixture/engine.js', afterSet, 'a variable that was set keeps its own value when the run throws');
		});
	}

	public function testApplyOnlyAndCheckApplyAreAlternatives(): Void {
		Assert.equals(2, MutationArm.main(['M-X', '--apply-only', '--check-apply', '--repo', '.']));
	}

	public function testAnArmThatDoesNotRenderIsARowAndTheOthersAreRendered(): Void {
		final cuts: Map<String, ArmCut> = MutationArm.cuts(REGISTRY, ['M-ONE', 'M-ODD', 'M-NONE'], 'arms.json');
		final targets: Map<String, ArmTarget> = [
			'M-ONE' => {
				type: 'a.B',
				method: 'f',
				file: 'src/a/B.hx',
				selector: 'FnMember:f',
				failure: null
			},
			'M-ROT' => {
				type: 'a.B',
				method: 'g',
				file: 'src/a/B.hx',
				selector: 'FnMember:g',
				failure: 'M-ROT: the cut did not apply'
			}
		];
		final split: RenderSplit = MutationArm.splitRendered(['M-ONE', 'M-ODD', 'M-NONE', 'M-ROT'], cuts, targets);
		Assert.same(['M-ONE'], split.rendered);
		Assert.equals(3, split.failed.length);
		Assert.stringContains('M-ODD', split.failed[0]);
		Assert.stringContains('no arm named "M-NONE"', split.failed[1]);
		Assert.stringContains('M-ROT: the cut did not apply', split.failed[2]);
		for (row in split.failed) Assert.isTrue(row.startsWith('APPLY-FAIL  '));
	}

	public function testALongMemberWithBracesInStringsIsForcedWhole(): Void {
		TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory(Path.join([repo, 'src/a']));
			FileSystem.createDirectory(Path.join([repo, 'bin']));
			FileSystem.createDirectory(Path.join([repo, 'test/testkit/arms']));
			// the `hxq` a run starts out of the repo it cuts: the engine the run pins
			File.saveContent(Path.join([repo, 'bin/hxq']), 'cmd=$$1; shift; exec node "$$HXQ_BIN" "$$cmd" --lang-default haxe "$$@"\n');
			final body: String = [for (i in 0...200) '\t\tfinal s$i:String = "{";'].join('\n');
			File.saveContent(
				Path.join([repo, 'src/a/B.hx']),
				'package a;\n\nclass B {\n\n\tpublic static function f():Int {\n$body\n\t\treturn 1;\n\t}\n\n}\n'
			);
			final long: String = '{"name": "M-LONG", "type": "a.B", "method": "f", "force": "7"}';
			final gone: String = '{"name": "M-GONE", "type": "a.Gone", "method": "f", "force": "7"}';
			File.saveContent(Path.join([repo, 'test/testkit/arms/a.json']), '{"arms": [$long, $gone]}');
			Assert.equals(0, ArmApply.applyOnly(repo, ['M-LONG']), 'a member past the show budget is cut');
		});
	}

	@:pin('control')
	@:killer('M-ARM-RENDER-FAILURE-REFUSES')
	public function testAFullRunOverAnArmThatDoesNotRenderAnswersARowNotARefusal(): Void {
		TempDir.with(dir -> {
			final repo: String = unrenderedArmRepo(dir);
			Assert.equals(1, ArmApply.run(repo, ['M-GONE']), 'a row and exit 1; a refusal answered 2');
		});
	}

	/**
	 * A full run leaves the caller's corpus fork as it found it: the run is in the caller's process, and every suite process after
	 * it in the same runner would otherwise find no corpus, run none of its cases and write no sweep snapshot.
	 */
	@:pin('control')
	@:killer('M-ARM-DELETES-CALLER-FORK')
	public function testAFullRunLeavesTheCallersCorpusFork(): Void {
		TempDir.with(dir -> {
			final repo: String = unrenderedArmRepo(dir);
			final fork: String = GateTree.FORK_VAR;
			final before: String = Sys.getEnv(fork) ?? '';
			CliFixture.always(() -> Sys.putEnv(fork, before), () -> {
				Sys.putEnv(fork, '/a/fork');
				Assert.equals(1, ArmApply.run(repo, ['M-GONE']));
				Assert.equals('/a/fork', Sys.getEnv(fork));
			});
		});
	}

	/** A scratch repo whose one arm names a type that does not exist, so the run answers a row for it and starts no track. */
	private static function unrenderedArmRepo(dir: TempDir): String {
		final repo: String = dir.file('repo');
		FileSystem.createDirectory(Path.join([repo, 'src/a']));
		FileSystem.createDirectory(Path.join([repo, 'test/testkit/arms']));
		File.saveContent(Path.join([repo, 'src/a/B.hx']), 'package a;\n\nclass B {\n\n}\n');
		File.saveContent(
			Path.join([repo, 'test/testkit/arms/a.json']), '{"arms": [{"name": "M-GONE", "type": "a.Gone", "method": "f", "force": "7"}]}'
		);
		return repo;
	}

}
