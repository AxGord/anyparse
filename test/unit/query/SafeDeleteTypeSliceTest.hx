package unit.query;

import anyparse.query.CachingGrammarPlugin;
import anyparse.query.SafeDeleteType;
import unit.cli.CliFixture;

using Lambda;
using StringTools;

/**
 * `SafeDeleteType.safeDeleteType` — remove a whole type only when nothing under the scope reaches it. Each test drives the
 * PURE op with an in-memory scope: a dead type is removed (the file when it is alone in its module, its declaration when
 * it is not), anything that still reaches it refuses and is listed.
 */
class SafeDeleteTypeSliceTest extends Test {

	private static final DEAD: String = 'package pkg;\n\nclass Dead {\n\tpublic function new() {}\n}\n';
	private static final USER: String = 'package pkg;\n\nclass User {\n\tpublic function new() {}\n}\n';
	private static final HOST: String =
		'package pkg;\n\nclass Host {\n\tpublic function new() {}\n}\n\nclass Sub {\n\tpublic function new() {}\n}\n';

	/** A dead type alone in its module takes the module file with it. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-SOLE-FILE')
	public function testDeadSoleTypeRemovesFile(): Void {
		switch run('pkg/Dead.hx', 'Dead', [file('pkg/Dead.hx', DEAD), file('pkg/User.hx', USER)]) {
			case RemoveFile(path, _):
				Assert.equals('pkg/Dead.hx', path);
			case other:
				Assert.fail('expected RemoveFile, got $other');
		}
	}

	/** A dead type beside others is cut out of its file alone, the file staying. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-SUB-DECLARATION')
	public function testDeadSubTypeRemovesDeclarationNotFile(): Void {
		switch run('pkg/Host.hx', 'Sub', [file('pkg/Host.hx', HOST), file('pkg/User.hx', USER)]) {
			case RemoveDeclaration(path, _, _):
				Assert.equals('pkg/Host.hx', path);
			case other:
				Assert.fail('expected RemoveDeclaration, got $other');
		}
	}

	/** What the cut leaves is the rest of the module and nothing of the removed type. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-CUT-TEXT')
	public function testSubTypeCutLeavesTheOtherTypes(): Void {
		switch run('pkg/Host.hx', 'Sub', [file('pkg/Host.hx', HOST)]) {
			case RemoveDeclaration(_, text, _):
				Assert.isFalse(text.contains('class Sub'), text);
				Assert.isTrue(text.contains('class Host'), text);
				Assert.isTrue(text.contains('package pkg;'), text);
			case other:
				Assert.fail('expected RemoveDeclaration, got $other');
		}
	}

	/** A type naming itself inside its own declaration is still dead. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-SELF-REFERENCE')
	public function testSelfReferenceDoesNotBlock(): Void {
		final own: String = 'package pkg;\n\nclass Dead {\n\tpublic function new() {}\n\n\tpublic static function make(): Dead {\n'
			+ '\t\treturn new Dead();\n\t}\n}\n';
		switch run('pkg/Dead.hx', 'Dead', [file('pkg/Dead.hx', own)]) {
			case RemoveFile(_, _):
				Assert.pass();
			case other:
				Assert.fail('expected RemoveFile, got $other');
		}
	}

	/** `new Dead()` in another file refuses and names the file and position. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-REFERENCES')
	public function testNewExpressionRefuses(): Void {
		final user: String = 'package pkg;\n\nclass User {\n\tpublic function new() {\n\t\tnew Dead();\n\t}\n}\n';
		assertRefused('pkg/User.hx:5:7', run('pkg/Dead.hx', 'Dead', [file('pkg/Dead.hx', DEAD), file('pkg/User.hx', user)]));
	}

	/** A type position (`var d: Dead`) refuses. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-REFERENCES')
	public function testTypePositionRefuses(): Void {
		final user: String = 'package pkg;\n\nclass User {\n\tpublic var d: Dead;\n\n\tpublic function new() {}\n}\n';
		assertRefused('pkg/User.hx', run('pkg/Dead.hx', 'Dead', [file('pkg/Dead.hx', DEAD), file('pkg/User.hx', user)]));
	}

	/** Static access through the type's name refuses. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-REFERENCES')
	public function testStaticAccessRefuses(): Void {
		final dead: String = 'package pkg;\n\nclass Dead {\n\tpublic static function make(): Int {\n\t\treturn 1;\n\t}\n}\n';
		final user: String = 'package pkg;\n\nclass User {\n\tpublic static function go(): Int {\n\t\treturn Dead.make();\n\t}\n}\n';
		assertRefused('pkg/User.hx', run('pkg/Dead.hx', 'Dead', [file('pkg/Dead.hx', dead), file('pkg/User.hx', user)]));
	}

	/** An import of the type refuses, used or not: the import alone stops compiling without it. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-REFERENCES')
	public function testImportRefuses(): Void {
		final user: String = 'package other;\n\nimport pkg.Dead;\n\nclass User {}\n';
		assertRefused('other/User.hx:3', run('pkg/Dead.hx', 'Dead', [file('pkg/Dead.hx', DEAD), file('other/User.hx', user)]));
	}

	/** A reference inside a parsed `#if` branch refuses. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-REFERENCES')
	public function testReferenceUnderConditionalRefuses(): Void {
		final user: String = 'package pkg;\n\nclass User {\n\t#if sys\n\tpublic var d: Dead;\n\t#end\n\n\tpublic function new() {}\n}\n';
		assertRefused('pkg/User.hx', run('pkg/Dead.hx', 'Dead', [file('pkg/Dead.hx', DEAD), file('pkg/User.hx', user)]));
	}

	/** Every reference is listed, from every file, not the first. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-REFERENCES')
	public function testEveryReferenceIsListed(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic var d: Dead;\n}\n';
		final b: String = 'package pkg;\n\nclass B {\n\tpublic var d: Dead;\n\tpublic var e: Dead;\n}\n';
		switch run('pkg/Dead.hx', 'Dead', [file('pkg/Dead.hx', DEAD), file('pkg/A.hx', a), file('pkg/B.hx', b)]) {
			case Refused(reasons):
				Assert.equals(3, reasons.length, reasons.join('\n'));
				Assert.isTrue(reasons.exists(r -> r.contains('pkg/A.hx')) && reasons.count(r -> r.contains('pkg/B.hx')) == 2);
			case other:
				Assert.fail('expected Refused, got $other');
		}
	}

	/** A sibling type of the same module naming the sub-type keeps it. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-REFERENCES')
	public function testSiblingInTheSameModuleBlocksSubType(): Void {
		final host: String = 'package pkg;\n\nclass Host {\n\tpublic var s: Sub;\n}\n\nclass Sub {}\n';
		assertRefused('pkg/Host.hx:4', run('pkg/Host.hx', 'Sub', [file('pkg/Host.hx', host)]));
	}

	/** A string naming the type's path for `Type.resolveClass` refuses. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-REFLECTIVE')
	public function testReflectiveStringRefuses(): Void {
		final user: String =
			'package pkg;\n\nclass User {\n\tpublic static function go(): Dynamic {\n\t\treturn Type.resolveClass("pkg.Dead");\n\t}\n}\n';
		assertRefused('at run time', run('pkg/Dead.hx', 'Dead', [file('pkg/Dead.hx', DEAD), file('pkg/User.hx', user)]));
	}

	/** `@:keep` on the type refuses: its readers are outside the scope. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-ANNOTATED')
	public function testKeepRefuses(): Void {
		final dead: String = 'package pkg;\n\n@:keep\nclass Dead {}\n';
		assertRefused('carries', run('pkg/Dead.hx', 'Dead', [file('pkg/Dead.hx', dead)]));
	}

	/** `@:expose` on the type refuses the same way. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-ANNOTATED')
	public function testExposeRefuses(): Void {
		final dead: String = 'package pkg;\n\n@:expose\nclass Dead {}\n';
		assertRefused('carries', run('pkg/Dead.hx', 'Dead', [file('pkg/Dead.hx', dead)]));
	}

	/** A same-named type of another package makes every simple-name match ambiguous: refused. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-UNIQUE')
	public function testSameNamedTypeElsewhereRefuses(): Void {
		final other: String = 'package other;\n\nclass Dead {}\n';
		assertRefused('ambiguous', run('pkg/Dead.hx', 'Dead', [file('pkg/Dead.hx', DEAD), file('other/Dead.hx', other)]));
	}

	/** A comment still naming the removed type does not block, and is reported. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-COMMENT-NOTE')
	public function testCommentMentionIsReported(): Void {
		final user: String = 'package pkg;\n\n// Dead is gone\nclass User {}\n';
		assertNote('comment mention', run('pkg/Dead.hx', 'Dead', [file('pkg/Dead.hx', DEAD), file('pkg/User.hx', user)]));
	}

	/** A directive still spelling the removed type does not block, and is reported. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-DIRECTIVE-NOTE')
	public function testDirectiveMentionIsReported(): Void {
		final user: String = 'package pkg;\n\nclass User {\n\t#if Dead\n\tpublic var x: Int;\n\t#end\n}\n';
		assertNote('directive', run('pkg/Dead.hx', 'Dead', [file('pkg/Dead.hx', DEAD), file('pkg/User.hx', user)]));
	}

	/** A declared test companion of the removed module is named, never removed. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-COMPANION-NOTE')
	public function testTestCompanionIsNamed(): Void {
		final result: SafeDeleteTypeResult = SafeDeleteType.safeDeleteType(
			'pkg/Dead.hx', 'Dead', true, [file('pkg/Dead.hx', DEAD)], plugin(), 'src', ['test/pkg/DeadTest.hx']
		);
		assertNote('test/pkg/DeadTest.hx', result);
	}

	/** A module's ambient import source that spells the type is named, never edited. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-AMBIENT-NOTE')
	public function testAmbientImportSourceIsNamed(): Void {
		final root: String = CliFixture.writeTree('safedeletetype', [
			{ name: 'pkg/Dead.hx', source: DEAD },
			{ name: 'pkg/import.hx', source: 'import haxe.io.Bytes;\n// Dead\n' }
		]);
		final path: String = '$root/pkg/Dead.hx';
		final result: SafeDeleteTypeResult = run(path, 'Dead', [file(path, DEAD)]);
		CliFixture.removeDir(root);
		assertNote('ambient import source', result);
	}

	/** An enum whose constructors are spelled bare, in its own module and through an import of it, is still reached. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-BARE-CONSTRUCTOR')
	public function testBareConstructorRefuses(): Void {
		final module: String =
			'package pkg;\n\nclass M {\n\tpublic static function f() {\n\t\treturn Red;\n\t}\n}\n\nenum Color {\n\tRed;\n\tGreen;\n}\n';
		final user: String = 'package pkg;\n\nimport pkg.M;\n\nclass User {\n\tstatic function main() {\n\t\tvar x = Green;\n\t}\n}\n';
		final result: SafeDeleteTypeResult = run('pkg/M.hx', 'Color', [file('pkg/M.hx', module), file('pkg/User.hx', user)]);
		assertRefused('named bare at pkg/M.hx:5:10', result);
		assertRefused('named bare at pkg/User.hx:7:11', result);
	}

	/** A `using` of the module brings its static-extension sub-type in without naming it, so the sub-type is reached. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-TYPE-MODULE-USING')
	public function testModuleUsingRefusesStaticExtensionType(): Void {
		final module: String = 'package pkg;\n\nclass M {\n\tpublic static function f() {\n\t\treturn 1;\n\t}\n}\n\nclass MTools {\n'
			+ '\tpublic static function twice(i: Int): Int {\n\t\treturn i * 2;\n\t}\n}\n';
		final user: String = 'package pkg;\n\nusing pkg.M;\n\nclass User {\n\tstatic function main() {\n\t\ttrace(3.twice());\n\t}\n}\n';
		assertRefused(
			'pkg/User.hx brings "MTools" in as a static extension',
			run('pkg/M.hx', 'MTools', [file('pkg/M.hx', module), file('pkg/User.hx', user)])
		);
	}

	/** `result` is a refusal one of whose reasons contains `reason`. */
	private function assertRefused(reason: String, result: SafeDeleteTypeResult): Void {
		switch result {
			case Refused(reasons):
				Assert.isTrue(reasons.exists(r -> r.contains(reason)), reasons.join('\n'));
			case other:
				Assert.fail('expected a refusal naming "$reason", got $other');
		}
	}

	/** `result` removes the type and one of its notes contains `note`. */
	private function assertNote(note: String, result: SafeDeleteTypeResult): Void {
		final notes: Array<String> = switch result {
			case RemoveFile(_, found): found;
			case RemoveDeclaration(_, _, found): found;
			case Refused(reasons):
				Assert.fail('expected a removal, got Refused: ${reasons.join('\n')}');
				[];
		};
		Assert.isTrue(notes.exists(n -> n.contains(note)), notes.join('\n'));
	}

	private static function run(srcFile: String, typeName: String, files: Array<{ file: String, source: String }>): SafeDeleteTypeResult {
		return SafeDeleteType.safeDeleteType(srcFile, typeName, true, files, plugin(), 'src', []);
	}

	private static function file(path: String, source: String): { file: String, source: String } {
		return { file: path, source: source };
	}

	private static function plugin(): CachingGrammarPlugin {
		return new CachingGrammarPlugin(new HaxeQueryPlugin());
	}

}
