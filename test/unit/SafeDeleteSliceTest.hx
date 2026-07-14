package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.SafeDelete;

/**
 * `SafeDelete.safeDelete` — remove a member only when no reference to it
 * survives across the scope. Each test drives the PURE op with an
 * in-memory scope: an unreferenced member is removed (`Ok`), a referenced
 * one is refused (`Err`).
 */
class SafeDeleteSliceTest extends Test {

	/** An unreferenced method is removed. */
	public function testDeadMethodRemoved(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic function new() {}\n\tpublic function used():Int return 1;\n\tpublic function dead():Int return 2;\n}';
		final text: String = okRemove('pkg/Svc.hx', 'Svc', 'dead', [{ file: 'pkg/Svc.hx', source: svc },]);
		Assert.isFalse(StringTools.contains(text, 'function dead'), 'dead is gone');
		Assert.isTrue(StringTools.contains(text, 'function used'), 'used stays');
	}

	/** An unreferenced field is removed. */
	public function testDeadFieldRemoved(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic var live:Int = 0;\n\tpublic var junk:Int = 0;\n\tpublic function new() {}\n\tpublic function f():Int return live;\n}';
		final text: String = okRemove('pkg/Svc.hx', 'Svc', 'junk', [{ file: 'pkg/Svc.hx', source: svc },]);
		Assert.isFalse(StringTools.contains(text, 'junk'), 'junk is gone');
	}

	/** A member referenced from another file is refused. */
	public function testCrossFileReferenceBlocks(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic function new() {}\n\tpublic function used():Int return 1;\n}';
		final client: String = 'package pkg;\n\nclass Client {\n\tpublic function new() {}\n\tpublic function go(s:Svc):Int return s.used();\n}';
		assertErr(SafeDelete.safeDelete('pkg/Svc.hx', 'Svc', 'used', false, [
			{ file: 'pkg/Svc.hx', source: svc },
			{ file: 'pkg/Client.hx', source: client },
		], plugin(), refShape()));
	}

	/** A self-recursive method with no other reference is removed. */
	public function testRecursiveRemoved(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic function new() {}\n\tpublic function loop(n:Int):Int return n <= 0 ? 0 : loop(n - 1);\n}';
		final text: String = okRemove('pkg/Svc.hx', 'Svc', 'loop', [{ file: 'pkg/Svc.hx', source: svc },]);
		Assert.isFalse(StringTools.contains(text, 'function loop'), 'recursive dead method removed');
	}

	/** A `this.member` field access blocks the deletion. */
	public function testThisAccessBlocks(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic var count:Int = 0;\n\tpublic function new() {}\n\tpublic function bump():Void this.count = this.count + 1;\n}';
		assertErr(SafeDelete.safeDelete('pkg/Svc.hx', 'Svc', 'count', false, [{ file: 'pkg/Svc.hx', source: svc },], plugin(), refShape()));
	}

	/** A bare in-type reference blocks the deletion. */
	public function testBareReferenceBlocks(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic function new() {}\n\tpublic function helper():Int return 1;\n\tpublic function calc():Int return helper() + 1;\n}';
		assertErr(
			SafeDelete.safeDelete('pkg/Svc.hx', 'Svc', 'helper', false, [{ file: 'pkg/Svc.hx', source: svc },], plugin(), refShape())
		);
	}

	/** A missing member is refused. */
	public function testNoSuchMemberRefused(): Void {
		final svc: String = 'package pkg;\n\nclass Svc {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		assertErr(SafeDelete.safeDelete('pkg/Svc.hx', 'Svc', 'nope', false, [{ file: 'pkg/Svc.hx', source: svc },], plugin(), refShape()));
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

	private function assertErr(result: EditResult): Void {
		switch result {
			case Ok(_):
				Assert.fail('expected Err, got Ok');
			case Err(_):
				Assert.pass();
		}
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

	private static function refShape(): RefShape {
		return new HaxeQueryPlugin().refShape();
	}

}
