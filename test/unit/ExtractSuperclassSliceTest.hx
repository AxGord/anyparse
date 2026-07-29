package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ExtractSuperclass;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;

/**
 * `ExtractSuperclass.extract` — generate a superclass, pull a chosen set
 * of instance members up into it, and make the class extend it. Each test
 * drives the PURE op with an in-memory source, asserts the generated
 * superclass + the removed members + the `extends` edit, and re-parses.
 * Refusal cases assert `Err`.
 */
class ExtractSuperclassSliceTest extends Test {

	/** The chosen members land on the new superclass and leave the source; the source extends it. */
	public function testExtractBasic(): Void {
		final src: String =
			'package pkg;\n\nclass Widget {\n\tpublic var id:Int = 0;\n\tpublic function new() {}\n\tpublic function bump():Void { id = id + 1; }\n\tpublic function render():String return \'w\';\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Widget.hx', 'Widget', 'Base', 'pkg/Base.hx', ['id', 'bump'], src);
		Assert.equals(2, changes.length);
		final base: String = changeFor(changes, 'pkg/Base.hx').newSource;
		Assert.isTrue(StringTools.contains(base, 'class Base'), 'declares the superclass');
		Assert.isTrue(StringTools.contains(base, 'var id'), 'field lands on Base');
		Assert.isTrue(StringTools.contains(base, 'function bump'), 'method lands on Base');
		final newSrc: String = changeFor(changes, 'pkg/Widget.hx').newSource;
		Assert.isTrue(StringTools.contains(newSrc, 'class Widget extends Base {'), 'class extends Base');
		Assert.isFalse(StringTools.contains(newSrc, 'function bump'), 'bump left the source');
		Assert.isTrue(StringTools.contains(newSrc, 'function render'), 'render stays in the source');
	}

	/** Imports the moved bodies reference are carried into the superclass. */
	public function testImportCarry(): Void {
		final src: String =
			'package pkg;\n\nimport haxe.ds.Option;\n\nclass S {\n\tpublic function new() {}\n\tpublic function pick():Option<Int> return None;\n\tpublic function keep():Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['pick'], src);
		Assert.isTrue(StringTools.contains(changeFor(changes, 'pkg/B.hx').newSource, 'import haxe.ds.Option;'), 'carries the import');
	}

	/** A moved member referencing a staying member is refused (stranding). */
	public function testStrandedRefused(): Void {
		final src: String =
			'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function helper():Int return 1;\n\tpublic function calc():Int return helper();\n}';
		assertErr(ExtractSuperclass.extract('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['calc'], src, plugin()));
	}

	/** `extends` is inserted before an existing `implements` clause. */
	public function testExtendsBeforeImplements(): Void {
		final src: String =
			'package pkg;\n\nclass S implements IThing {\n\tpublic function new() {}\n\tpublic function a():Void {}\n\tpublic function thing():Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['a'], src);
		Assert.isTrue(
			StringTools.contains(changeFor(changes, 'pkg/S.hx').newSource, 'class S extends B implements IThing {'),
			'extends inserted before implements'
		);
	}

	/**
	 * A `{` inside a header comment is NOT the class body brace — the op must
	 * anchor past the comment instead of splicing `extends` into it.
	 */
	public function testCommentBraceInHeader(): Void {
		final src: String =
			'package pkg;\n\nclass Holder /* body { starts */ {\n\tpublic function new() {}\n\n\tpublic function ping():Void {}\n}\n';
		final changes: Array<MoveChange> = okChanges('pkg/Holder.hx', 'Holder', 'BaseHolder', 'pkg/BaseHolder.hx', ['ping'], src);
		final newSrc: String = changeFor(changes, 'pkg/Holder.hx').newSource;
		Assert.isTrue(
			StringTools.contains(newSrc, 'class Holder extends BaseHolder /* body { starts */ {'), 'extends lands outside the comment'
		);
		Assert.isFalse(StringTools.contains(newSrc, 'body extends'), 'nothing spliced inside the comment');
		Assert.isFalse(StringTools.contains(newSrc, 'function ping'), 'the pulled member left the source');
		Assert.isTrue(
			StringTools.contains(changeFor(changes, 'pkg/BaseHolder.hx').newSource, 'function ping'), 'and landed on the superclass'
		);
	}

	/** A `{` inside a header LINE comment is not the body brace either. */
	public function testLineCommentBraceInHeader(): Void {
		final src: String =
			'package pkg;\n\nclass Holder // note {\n{\n\tpublic function new() {}\n\n\tpublic function ping():Void {}\n}\n';
		final changes: Array<MoveChange> = okChanges('pkg/Holder.hx', 'Holder', 'BaseHolder', 'pkg/BaseHolder.hx', ['ping'], src);
		final newSrc: String = changeFor(changes, 'pkg/Holder.hx').newSource;
		Assert.isTrue(StringTools.contains(newSrc, 'class Holder extends BaseHolder // note {'), 'extends lands before the line comment');
	}

	/** A structural type-parameter constraint brace is not the body brace. */
	public function testTypeParamConstraintBrace(): Void {
		final src: String =
			'package pkg;\n\nclass Holder<T:{ x:Int }> {\n\tpublic function new() {}\n\n\tpublic function ping():Void {}\n}\n';
		final changes: Array<MoveChange> = okChanges('pkg/Holder.hx', 'Holder', 'BaseHolder', 'pkg/BaseHolder.hx', ['ping'], src);
		final newSrc: String = changeFor(changes, 'pkg/Holder.hx').newSource;
		Assert.isTrue(
			StringTools.contains(newSrc, 'class Holder<T:{ x:Int }> extends BaseHolder {'), 'extends lands after the type params'
		);
	}

	/** A class that already extends a class is refused (single inheritance). */
	public function testAlreadyExtendsRefused(): Void {
		final src: String =
			'package pkg;\n\nclass S extends Other {\n\tpublic function new() { super(); }\n\tpublic function a():Void {}\n}';
		assertErr(ExtractSuperclass.extract('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['a'], src, plugin()));
	}

	/** A static member is refused. */
	public function testStaticRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic static function s():Void {}\n}';
		assertErr(ExtractSuperclass.extract('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['s'], src, plugin()));
	}

	/** An override member is refused. */
	public function testOverrideRefused(): Void {
		final src: String =
			'package pkg;\n\nclass S {\n\tpublic function new() {}\n\toverride public function toString():String return \'s\';\n}';
		assertErr(ExtractSuperclass.extract('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['toString'], src, plugin()));
	}

	/** A constructor is refused. */
	public function testConstructorRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		assertErr(ExtractSuperclass.extract('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['new'], src, plugin()));
	}

	/** An unknown member is refused. */
	public function testUnknownMemberRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		assertErr(ExtractSuperclass.extract('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['nope'], src, plugin()));
	}

	/** An empty member set is refused. */
	public function testEmptyMembersRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		assertErr(ExtractSuperclass.extract('pkg/S.hx', 'S', 'B', 'pkg/B.hx', [], src, plugin()));
	}

	private function okChanges(
		srcFile: String, srcType: String, superName: String, superFile: String, memberNames: Array<String>, srcSource: String
	): Array<MoveChange> {
		switch ExtractSuperclass.extract(srcFile, srcType, superName, superFile, memberNames, srcSource, plugin()) {
			case Ok(changes, advisory):
				Assert.notNull(advisory);
				for (c in changes) {
					var parsed: Bool = true;
					try
						plugin().parseFile(c.newSource)
					catch (_: haxe.Exception)
						parsed = false;
					Assert.isTrue(parsed, 'rewritten ${c.file} should re-parse');
				}
				return changes;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return [];
		}
	}

	private function assertErr(result: MoveResult): Void {
		switch result {
			case Ok(changes, _):
				Assert.fail('expected Err, got Ok with ${changes.length} change(s)');
			case Err(_):
				Assert.pass();
		}
	}

	private function changeFor(changes: Array<MoveChange>, file: String): MoveChange {
		for (c in changes) if (c.file == file) return c;
		Assert.fail('no change for file $file');
		return { file: file, newSource: '' };
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}


	/**
	 * A leading header comment repeating the type name must not win the race for
	 * the name token: the `extends` clause has to land on real code. It did land
	 * inside the comment before the anchor moved to
	 * `RefactorSupport.activeCodeIdentTokenOffset` - and because the result
	 * still PARSED, nothing downstream caught it while the members had already
	 * left the source.
	 */
	public function testExtendsSkipsNameRepeatingHeaderComment(): Void {
		final src: String = 'package pkg;\n\nclass /* Holder { */ Holder {\n\tpublic function new() {}\n\tpublic function m():Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Holder.hx', 'Holder', 'Base', 'pkg/Base.hx', ['m'], src);
		final newSrc: String = changeFor(changes, 'pkg/Holder.hx').newSource;
		Assert.isTrue(StringTools.contains(newSrc, 'Holder extends Base {'), 'extends lands after the real name: <$newSrc>');
		Assert.isTrue(StringTools.contains(newSrc, '/* Holder { */'), 'the comment is left verbatim: <$newSrc>');
	}

}
