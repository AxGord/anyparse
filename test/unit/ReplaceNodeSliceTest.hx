package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ReplaceNode;
import anyparse.query.ReplaceNode.ReplaceTarget;
import anyparse.query.RefactorSupport.EditResult;
import haxe.Exception;

/**
 * `ReplaceNode.replaceNode` — replace one node's source span, WRITER-
 * FORMATTED. The target is addressed by an `ast`-style `--select`
 * selector (exactly one match) OR by a cursor position (in the `apq refs`
 * column convention); the replacement is laid out by the writer (the
 * whole file is re-emitted), not spliced as-is. The source must be
 * canonical unless `reformat` is passed. Each `Ok` asserts the EXACT
 * canonical output and is re-parsed; refusal cases assert `Err`.
 */
class ReplaceNodeSliceTest extends Test {

	/**
	 * Replace a method via a `Kind:name` selector — the replacement
	 * `function g():Int return 0;` is re-laid-out to its canonical
	 * expression-body form.
	 */
	public function testReplaceBySelector():Void {
		final source:String =
			'class C {\n'
			+ '\tfunction f():Void {}\n'
			+ '}\n';
		final expected:String =
			'class C {\n'
			+ '\tfunction g():Int\n'
			+ '\t\treturn 0;\n'
			+ '}\n';
		assertReplace(source, BySelector('FnMember:f'), 'function g():Int return 0;', expected);
	}

	/**
	 * Replace the node at a cursor — column in the `apq refs` convention
	 * (the op inverts it). Line 2 col 10 is the `f` method name token; the
	 * innermost spanned node there is the whole `FnMember`.
	 */
	public function testReplaceByPosition():Void {
		final source:String =
			'class C {\n'
			+ '\tfunction f():Void {}\n'
			+ '}\n';
		final expected:String =
			'class C {\n'
			+ '\tfunction h():Void {}\n'
			+ '}\n';
		assertReplace(source, ByPosition(2, 10), 'function h():Void {}', expected);
	}

	/** Refuse a selector that matches no node. */
	public function testRefuseSelectorNoMatch():Void {
		final source:String =
			'class C {\n'
			+ '\tfunction f():Void {}\n'
			+ '}\n';
		assertRefused(source, BySelector('FnMember:nope'), 'x');
	}

	/** Refuse an ambiguous selector — `VarMember` matches both fields. */
	public function testRefuseSelectorAmbiguous():Void {
		final source:String =
			'class C {\n'
			+ '\tvar a:Int;\n'
			+ '\tvar b:Int;\n'
			+ '}\n';
		assertRefused(source, BySelector('VarMember'), 'var c:Int;');
	}

	/** Refuse a malformed replacement — the whole-file re-emit fails. */
	public function testRefuseMalformedReplacement():Void {
		final source:String =
			'class C {\n'
			+ '\tfunction f():Void {}\n'
			+ '}\n';
		assertRefused(source, BySelector('FnMember:f'), '@@@ not haxe');
	}

	/** Refuse a non-canonical file (4-space indent) without `--reformat`. */
	public function testRefuseNonCanonicalWithoutReformat():Void {
		final source:String =
			'class C {\n'
			+ '    function f():Void {}\n'
			+ '}\n';
		assertRefused(source, BySelector('FnMember:f'), 'function h():Void {}');
	}

	private function assertReplace(source:String, target:ReplaceTarget, newSource:String, expected:String, reformat:Bool = false):Void {
		final result:EditResult = replaceOf(source, target, newSource, reformat);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				assertReparses(text);
			case Err(message): Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source:String, target:ReplaceTarget, newSource:String, reformat:Bool = false):Void {
		final result:EditResult = replaceOf(source, target, newSource, reformat);
		switch result {
			case Ok(text): Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(_): Assert.pass();
		}
	}

	private function assertReparses(text:String):Void {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		try {
			plugin.parseFile(text);
			Assert.pass();
		} catch (exception:Exception) {
			Assert.fail('replace-node output failed to re-parse: ${exception.message}\n$text');
		}
	}

	private static function replaceOf(source:String, target:ReplaceTarget, newSource:String, reformat:Bool):EditResult {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		return ReplaceNode.replaceNode(source, target, newSource, reformat, plugin);
	}
}
