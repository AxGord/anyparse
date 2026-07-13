package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ExtractInterface;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;

/**
 * `ExtractInterface.extract` — generate an interface from a class's
 * public instance methods and make the class implement it. Each test
 * drives the PURE op with an in-memory source, asserts the generated
 * interface + the `implements` header edit, and re-parses both. Refusal
 * cases assert `Err`.
 */
class ExtractInterfaceSliceTest extends Test {

	/**
	 * Only public instance methods are extracted: a private method, a
	 * static method and the constructor are all excluded; the class gains
	 * `implements`.
	 */
	public function testBasicExtract(): Void {
		final src: String = 'package pkg;\n\nclass Service {\n' + '\tvar count:Int = 0;\n' + '\tpublic function new() {}\n'
			+ '\tpublic function fetch(id:Int):String return \'x\';\n' + '\tpublic function reset():Void {}\n'
			+ '\tfunction helper():Int return count;\n' + '\tpublic static function make():Service return null;\n' + '}';
		final changes: Array<MoveChange> = okChanges('pkg/Service.hx', 'Service', 'IService', 'pkg/IService.hx', null, src);
		Assert.equals(2, changes.length);
		final iface: String = changeFor(changes, 'pkg/IService.hx').newSource;
		Assert.isTrue(StringTools.contains(iface, 'interface IService'), 'declares the interface');
		Assert.isTrue(StringTools.contains(iface, 'function fetch(id:Int):String;'), 'carries fetch signature');
		Assert.isTrue(StringTools.contains(iface, 'function reset():Void;'), 'carries reset signature');
		Assert.isFalse(StringTools.contains(iface, 'helper'), 'excludes the private method');
		Assert.isFalse(StringTools.contains(iface, 'make'), 'excludes the static method');
		Assert.isFalse(StringTools.contains(iface, 'function new'), 'excludes the constructor');
		final newSrc: String = changeFor(changes, 'pkg/Service.hx').newSource;
		Assert.isTrue(StringTools.contains(newSrc, 'class Service implements IService {'), 'class implements the interface');
	}

	/** Only the imports the signatures reference are carried into the interface. */
	public function testImportCarry(): Void {
		final src: String = 'package pkg;\n\nimport haxe.ds.Option;\nimport haxe.ds.StringMap;\n\nclass S {\n'
			+ '\tpublic function new() {}\n' + '\tpublic function f():Option<Int> return null;\n' + '\tpublic function g(x:Int):Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', null, src);
		final iface: String = changeFor(changes, 'pkg/IS.hx').newSource;
		Assert.isTrue(StringTools.contains(iface, 'import haxe.ds.Option;'), 'carries the referenced import');
		Assert.isFalse(StringTools.contains(iface, 'StringMap'), 'drops the unreferenced import');
	}

	/** `--members` selects a subset; the others are not in the interface. */
	public function testMembersSubset(): Void {
		final src: String = 'package pkg;\n\nclass S {\n' + '\tpublic function new() {}\n' + '\tpublic function a():Void {}\n'
			+ '\tpublic function b():Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', ['a'], src);
		final iface: String = changeFor(changes, 'pkg/IS.hx').newSource;
		Assert.isTrue(StringTools.contains(iface, 'function a():Void;'), 'includes the selected method');
		Assert.isFalse(StringTools.contains(iface, 'function b'), 'excludes the unselected method');
	}

	/** An existing `extends` clause is preserved; `implements` is appended. */
	public function testExtendsPreserved(): Void {
		final src: String = 'package pkg;\n\nclass S extends Base {\n' + '\tpublic function new() { super(); }\n'
			+ '\tpublic function a():Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', null, src);
		final newSrc: String = changeFor(changes, 'pkg/S.hx').newSource;
		Assert.isTrue(StringTools.contains(newSrc, 'class S extends Base implements IS {'), 'extends preserved, implements added');
	}

	/** A `final class` gets the `implements` clause too. */
	public function testFinalClass(): Void {
		final src: String = 'package pkg;\n\nfinal class S {\n' + '\tpublic function new() {}\n' + '\tpublic function a():Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', null, src);
		final newSrc: String = changeFor(changes, 'pkg/S.hx').newSource;
		Assert.isTrue(StringTools.contains(newSrc, 'final class S implements IS {'), 'final class implements the interface');
	}

	/** A class with no public instance method is refused. */
	public function testNoPublicMethodsRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n' + '\tpublic function new() {}\n' + '\tfunction hidden():Void {}\n'
			+ '\tpublic static function s():Void {}\n}';
		assertErr(ExtractInterface.extract('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', null, src, plugin()));
	}

	/** A `--members` entry that is not an extractable method is refused. */
	public function testUnknownMemberRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n' + '\tpublic function new() {}\n' + '\tpublic function a():Void {}\n}';
		assertErr(ExtractInterface.extract('pkg/S.hx', 'S', 'IS', 'pkg/IS.hx', ['nope'], src, plugin()));
	}

	/** The interface name must differ from the source type. */
	public function testNameEqualsTypeRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		assertErr(ExtractInterface.extract('pkg/S.hx', 'S', 'S', 'pkg/S2.hx', null, src, plugin()));
	}

	/** An invalid interface name is refused. */
	public function testInvalidNameRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		assertErr(ExtractInterface.extract('pkg/S.hx', 'S', '1bad', 'pkg/X.hx', null, src, plugin()));
	}

	/** A source type that is not a class in the file is refused. */
	public function testNoSuchClassRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		assertErr(ExtractInterface.extract('pkg/S.hx', 'Other', 'IS', 'pkg/IS.hx', null, src, plugin()));
	}

	private function okChanges(
		srcFile: String, srcType: String, ifaceName: String, ifaceFile: String, memberNames: Null<Array<String>>, srcSource: String
	): Array<MoveChange> {
		switch ExtractInterface.extract(srcFile, srcType, ifaceName, ifaceFile, memberNames, srcSource, plugin()) {
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

}
