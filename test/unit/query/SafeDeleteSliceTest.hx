package unit.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SafeDelete;
import anyparse.runtime.Span;

using StringTools;

/**
 * `SafeDelete.safeDelete` — remove a member only when no reference to it
 * survives across the scope. Each test drives the PURE op with an
 * in-memory scope: an unreferenced member is removed (`Ok`), a referenced
 * one is refused (`Err`).
 */
class SafeDeleteSliceTest extends Test {

	/** An unreferenced method is removed. */
	public function testDeadMethodRemoved(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic function new() {}\n\tpublic function used():Int return 1;\n'
			+ '\tpublic function dead():Int return 2;\n}';
		final text: String = okRemove('pkg/Svc.hx', 'Svc', 'dead', [{ file: 'pkg/Svc.hx', source: svc }]);
		Assert.isFalse(text.contains('function dead'), 'dead is gone');
		Assert.isTrue(text.contains('function used'), 'used stays');
	}

	/** An unreferenced field is removed. */
	public function testDeadFieldRemoved(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic var live:Int = 0;\n\tpublic var junk:Int = 0;\n'
			+ '\tpublic function new() {}\n\tpublic function f():Int return live;\n}';
		final text: String = okRemove('pkg/Svc.hx', 'Svc', 'junk', [{ file: 'pkg/Svc.hx', source: svc }]);
		Assert.isFalse(text.contains('junk'), 'junk is gone');
	}

	/** A member referenced from another file is refused. */
	public function testCrossFileReferenceBlocks(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic function new() {}\n\tpublic function used():Int return 1;\n}';
		final client: String =
			'package pkg;\n\nclass Client {\n\tpublic function new() {}\n\tpublic function go(s:Svc):Int return s.used();\n}';
		assertReferencedFrom('pkg/Client.hx', SafeDelete.safeDelete('pkg/Svc.hx', 'Svc', 'used', false, [
			{ file: 'pkg/Svc.hx', source: svc },
			{ file: 'pkg/Client.hx', source: client }
		], plugin(), refShape()));
	}

	/**
	 * Another file calling a same-named static through ANOTHER type's name does not reach this member: the receiver resolves
	 * to that type, which declares its own, so the delete goes on.
	 */
	@:pin('control')
	@:killer('M-SAFE-DELETE-OTHER-RECEIVER')
	public function testSameNamedStaticOfAnotherTypeDoesNotBlock(): Void {
		final text: String = okRemove('pkg/Svc.hx', 'Svc', 'path', [
			{ file: 'pkg/Svc.hx', source: 'package pkg;\n\nclass Svc {\n\tpublic static function path(p:String):String return p;\n}' },
			{ file: 'pkg/Other.hx', source: 'package pkg;\n\nclass Other {\n\tpublic static function path(p:String):String return p;\n}' },
			{ file: 'pkg/Client.hx', source: 'package pkg;\n\nclass Client {\n\tstatic function go():String return Other.path("x");\n}' }
		]);
		Assert.isFalse(text.contains('function path'), text);
	}

	/** A call through the declaring type's own name from another file still blocks the delete. */
	public function testDeclaringTypeQualifiedCallBlocks(): Void {
		assertReferencedFrom('pkg/Client.hx', SafeDelete.safeDelete('pkg/Svc.hx', 'Svc', 'path', false, [
			{ file: 'pkg/Svc.hx', source: 'package pkg;\n\nclass Svc {\n\tpublic static function path(p:String):String return p;\n}' },
			{ file: 'pkg/Other.hx', source: 'package pkg;\n\nclass Other {\n\tpublic static function path(p:String):String return p;\n}' },
			{ file: 'pkg/Client.hx', source: 'package pkg;\n\nclass Client {\n\tstatic function go():String return Svc.path("x");\n}' }
		], plugin(), refShape()));
	}

	/** Another file importing the member as a static field (`import pkg.Svc.path;`) and calling it bare blocks the delete. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-STATIC-IMPORT')
	public function testStaticFieldImportBlocks(): Void {
		assertReferencedFrom('other/U.hx', SafeDelete.safeDelete('pkg/Svc.hx', 'Svc', 'path', true, [
			{ file: 'pkg/Svc.hx', source: 'package pkg;\n\nclass Svc {\n\tpublic static function path(p:String):String return p;\n}' },
			{
				file: 'other/U.hx',
				source: 'package other;\n\nimport pkg.Svc.path;\n\nclass U {\n\tstatic function go():String return path("y");\n}'
			}
		], plugin(), refShape()));
	}

	/** A static field import naming the member blocks the delete with no use: the import alone stops compiling without it. */
	public function testUnusedStaticFieldImportBlocks(): Void {
		assertReferencedFrom('other/U.hx', SafeDelete.safeDelete('pkg/Svc.hx', 'Svc', 'path', true, [
			{ file: 'pkg/Svc.hx', source: 'package pkg;\n\nclass Svc {\n\tpublic static function path(p:String):String return p;\n}' },
			{ file: 'other/U.hx', source: 'package other;\n\nimport pkg.Svc.path;\n\nclass U {}' }
		], plugin(), refShape()));
	}

	/** An alias of the member (`import pkg.Svc.path as p;`) blocks the delete. */
	public function testStaticFieldAliasBlocks(): Void {
		assertReferencedFrom('other/U.hx', SafeDelete.safeDelete('pkg/Svc.hx', 'Svc', 'path', true, [
			{ file: 'pkg/Svc.hx', source: 'package pkg;\n\nclass Svc {\n\tpublic static function path(p:String):String return p;\n}' },
			{
				file: 'other/U.hx',
				source: 'package other;\n\nimport pkg.Svc.path as p;\n\nclass U {\n\tstatic function go():String return p("y");\n}'
			}
		], plugin(), refShape()));
	}

	/** A type wildcard over the declaring type (`import pkg.Svc.*;`) and a bare call of the member blocks the delete. */
	@:pin('control')
	@:killer('M-SAFE-DELETE-STATIC-WILDCARD')
	public function testStaticWildcardImportBlocks(): Void {
		assertReferencedFrom('other/U.hx', SafeDelete.safeDelete('pkg/Svc.hx', 'Svc', 'path', true, [
			{ file: 'pkg/Svc.hx', source: 'package pkg;\n\nclass Svc {\n\tpublic static function path(p:String):String return p;\n}' },
			{
				file: 'other/U.hx',
				source: 'package other;\n\nimport pkg.Svc.*;\n\nclass U {\n\tstatic function go():String return path("y");\n}'
			}
		], plugin(), refShape()));
	}

	/** A wildcard over another type declaring its own same-named static binds the bare call to that one: the delete goes on. */
	public function testWildcardOfAnotherTypeDoesNotBlock(): Void {
		final text: String = okRemove('pkg/Svc.hx', 'Svc', 'path', [
			{ file: 'pkg/Svc.hx', source: 'package pkg;\n\nclass Svc {\n\tpublic static function path(p:String):String return p;\n}' },
			{ file: 'pkg/Other.hx', source: 'package pkg;\n\nclass Other {\n\tpublic static function path(p:String):String return p;\n}' },
			{
				file: 'other/U.hx',
				source: 'package other;\n\nimport pkg.Other.*;\n\nclass U {\n\tstatic function go():String return path("y");\n}'
			}
		]);
		Assert.isFalse(text.contains('function path'), text);
	}

	/** A wildcard over the declaring type with no bare use of the member does not block the delete. */
	public function testUnusedWildcardDoesNotBlock(): Void {
		final text: String = okRemove('pkg/Svc.hx', 'Svc', 'path', [
			{
				file: 'pkg/Svc.hx',
				source: 'package pkg;\n\nclass Svc {\n\tpublic static function path(p:String):String return p;\n'
				+ '\tpublic static function other():Int return 1;\n}'
			},
			{
				file: 'other/U.hx',
				source: 'package other;\n\nimport pkg.Svc.*;\n\nclass U {\n\tstatic function go():Int return other();\n}'
			}
		]);
		Assert.isFalse(text.contains('function path'), text);
	}

	/**
	 * With no index to read the imports through, a file's own import statement naming the member — by its path or as the
	 * path of an alias — is still a reference: deleting the member breaks it.
	 */
	@:pin('control')
	@:killer('M-SAFE-DELETE-IMPORT-NO-INDEX')
	public function testUnindexedStaticImportBlocks(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic static function path(p:String):String return p;\n}';
		final span: Span = new Span(svc.indexOf('public static'), svc.lastIndexOf('}'));
		for (stmt in ['import pkg.Svc.path;', 'import pkg.Svc.path as p;']) {
			final refusal: Null<String> = SafeDelete.foreignReferenceRefusal([
				{ file: 'pkg/Svc.hx', source: svc },
				{ file: 'other/U.hx', source: 'package other;\n\n$stmt\n\nclass U {}' }
			], 'pkg/Svc.hx', 'path', span, plugin(), refShape(), () -> null);
			Assert.isTrue(refusal != null && refusal.indexOf('other/U.hx') >= 0, '$stmt: $refusal');
		}
	}

	/** With no index, an import of another member of the type does not block the delete. */
	public function testUnindexedImportOfAnotherMemberDoesNotBlock(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic static function path(p:String):String return p;\n}';
		final span: Span = new Span(svc.indexOf('public static'), svc.lastIndexOf('}'));
		Assert.isNull(SafeDelete.foreignReferenceRefusal([
			{ file: 'pkg/Svc.hx', source: svc },
			{ file: 'other/U.hx', source: 'package other;\n\nimport pkg.Svc.other;\n\nclass U {\n\tstatic final s:String = "path";\n}' }
		], 'pkg/Svc.hx', 'path', span, plugin(), refShape(), () -> null));
	}

	/** A self-recursive method with no other reference is removed. */
	public function testRecursiveRemoved(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic function new() {}\n'
			+ '\tpublic function loop(n:Int):Int return n <= 0 ? 0 : loop(n - 1);\n}';
		final text: String = okRemove('pkg/Svc.hx', 'Svc', 'loop', [{ file: 'pkg/Svc.hx', source: svc }]);
		Assert.isFalse(text.contains('function loop'), 'recursive dead method removed');
	}

	/** A `this.member` field access blocks the deletion. */
	public function testThisAccessBlocks(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic var count:Int = 0;\n\tpublic function new() {}\n'
			+ '\tpublic function bump():Void this.count = this.count + 1;\n}';
		assertReferencedFrom(
			'pkg/Svc.hx',
			SafeDelete.safeDelete('pkg/Svc.hx', 'Svc', 'count', false, [{ file: 'pkg/Svc.hx', source: svc }], plugin(), refShape())
		);
	}

	/** A bare in-type reference blocks the deletion. */
	public function testBareReferenceBlocks(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic function new() {}\n\tpublic function helper():Int return 1;\n'
			+ '\tpublic function calc():Int return helper() + 1;\n}';
		assertReferencedFrom(
			'pkg/Svc.hx',
			SafeDelete.safeDelete('pkg/Svc.hx', 'Svc', 'helper', false, [{ file: 'pkg/Svc.hx', source: svc }], plugin(), refShape())
		);
	}

	/** A missing member is refused. */
	public function testNoSuchMemberRefused(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		assertRefusal(
			'no member "nope"',
			SafeDelete.safeDelete('pkg/Svc.hx', 'Svc', 'nope', false, [{ file: 'pkg/Svc.hx', source: svc }], plugin(), refShape())
		);
	}

	private function okRemove(
		srcFile: String, srcType: String, member: String, scopeFiles: Array<{ file: String, source: String }>
	): String {
		switch SafeDelete.safeDelete(srcFile, srcType, member, true, scopeFiles, plugin(), refShape()) {
			case Ok(text):
				var parsed: Bool = true;
				try
					plugin().parseFile(text)
				catch (_: haxe.Exception)
					parsed = false;
				Assert.isTrue(parsed, 'result should re-parse');
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

	/** `result` is a refusal whose message contains `reason`. */
	private function assertRefusal(reason: String, result: EditResult): Void {
		switch result {
			case Ok(_):
				Assert.fail('expected Err, got Ok');
			case Err(message):
				Assert.isTrue(message.indexOf(reason) >= 0, message);
		}
	}

	/** `result` is the refusal naming `file` among the files still referencing the member — not any other `Err`. */
	private function assertReferencedFrom(file: String, result: EditResult): Void {
		switch result {
			case Ok(_):
				Assert.fail('expected a refusal naming $file, got Ok');
			case Err(message):
				Assert.isTrue(message.indexOf('still referenced') >= 0 && message.indexOf(file) >= 0, message);
		}
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

	private static function refShape(): RefShape {
		return new HaxeQueryPlugin().refShape();
	}

}
