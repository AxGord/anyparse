package unit.query;

import anyparse.query.CrossRename.CrossRenameResult;
import anyparse.query.CrossRename.FileChange;
import anyparse.query.CrossRenameMember;

using Lambda;
using StringTools;

/**
 * `CrossRenameMember.crossRenameMember` on an enum constructor whose `case` arm sits inside a `#if` / `#else` region of
 * its switch: the arm is a pattern head of that switch whether or not the region wraps it.
 */
class EnumCtorRegionArmRenameTest extends Test {

	private static final ENUM: String = 'package pkg;\n\nenum Col {\n\tRed;\n\tBlue(x: Int);\n\tGreen;\n}\n';

	/** An arm inside a region of a switch over a subject declared the enum renames with the declaration. */
	@:pin('control')
	@:killer('M-CTOR-REGION-ARM-SKIPPED')
	public function testAnArmInsideARegionOfTheSwitchRenames(): Void {
		final source: String = user('Col');
		final changes: Array<FileChange> = ok(run(source));
		Assert.equals(ENUM.replace('Green', 'Verde'), sourceOf(changes, 'pkg/Col.hx'));
		Assert.equals(source.replace('case Green', 'case Verde'), sourceOf(changes, 'pkg/U.hx'));
	}

	/** An arm in a region under a subject whose type nothing proves is still not proven a constructor: the rename refuses. */
	@:pin('guard')
	public function testAnArmInsideARegionUnderAnUnprovenSubjectRefuses(): Void {
		switch run(user('Dynamic')) {
			case Ok(changes, _):
				Assert.fail('expected a refusal, got Ok over ${[for (c in changes) c.file].join(', ')}');
			case Err(message):
				Assert.isTrue(message.contains('is not proven to be the constructor'), message);
		}
	}

	/** An arm in a region whose body holds a switch of its own: that switch is judged under its own subject, never the outer one. */
	@:pin('guard')
	public function testASwitchInTheBodyOfARegionArmIsJudgedByItsOwnSubject(): Void {
		final source: String = 'package pkg;\n\nclass U {\n\tstatic function h(c: Col, d: Dynamic): Int {\n\t\treturn switch c {\n'
			+ '\t\t\t#if foo\n\t\t\tcase Blue(x): switch d {\n\t\t\t\tcase Green: 1;\n\t\t\t\tcase _: 2;\n\t\t\t};\n'
			+ '\t\t\t#end\n\t\t\tcase _: 1;\n\t\t}\n\t}\n}\n';
		switch run(source) {
			case Ok(changes, _):
				Assert.fail('expected a refusal, got Ok over ${[for (c in changes) c.file].join(', ')}');
			case Err(message):
				Assert.isTrue(message.contains('is not proven to be the constructor'), message);
		}
	}

	/** Arms in a region inside a region, through `#elseif` and `#else`, and in a statement switch, rename with the declaration. */
	@:pin('control')
	@:killer('M-CTOR-REGION-ARM-SKIPPED')
	public function testArmsInNestedRegionsAndInAStatementSwitchRename(): Void {
		final source: String = 'package pkg;\n\nclass U {\n\tstatic function f(c: Col): Int {\n\t\treturn switch c {\n\t\t\t#if foo\n'
			+ '\t\t\t#if bar\n\t\t\tcase Green: 1;\n\t\t\t#end\n\t\t\t#elseif baz\n\t\t\tcase Green: 2;\n\t\t\t#else\n'
			+ '\t\t\tcase Red: 3;\n\t\t\t#end\n\t\t\tcase _: 0;\n\t\t}\n\t}\n\n\tstatic function g(c: Col): Void {\n'
			+ '\t\tswitch c {\n\t\t\t#if js\n\t\t\tcase Green: trace(1);\n\t\t\t#end\n\t\t\tcase _:\n\t\t}\n\t}\n}\n';
		final changes: Array<FileChange> = ok(run(source));
		Assert.equals(source.replace('case Green', 'case Verde'), sourceOf(changes, 'pkg/U.hx'));
	}

	private static function user(subject: String): String {
		return
			'package pkg;\n\nclass U {\n\tstatic function f(c: $subject): Int {\n\t\treturn switch c {\n\t\t\tcase Red: 0;\n\t\t\t#if foo\n'
				+ '\t\t\tcase Blue(x): x;\n\t\t\t#else\n\t\t\tcase Green: 2;\n\t\t\t#end\n\t\t\tcase _: 1;\n\t\t}\n\t}\n}\n';
	}

	private static function run(userSource: String): CrossRenameResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final files: Array<{ file: String, source: String }> = [{
			file: 'pkg/Col.hx',
			source: ENUM
		}, { file: 'pkg/U.hx', source: userSource }];
		return CrossRenameMember.crossRenameMember('pkg/Col.hx', ENUM, 6, 2, 'Verde', files, plugin, plugin.refShape());
	}

	private static function ok(result: CrossRenameResult): Array<FileChange> {
		return switch result {
			case Ok(changes, _): changes;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				[];
		};
	}

	private static function sourceOf(changes: Array<FileChange>, file: String): String {
		return changes.find(c -> c.file == file)?.newSource ?? 'NO CHANGE FOR $file';
	}

}
