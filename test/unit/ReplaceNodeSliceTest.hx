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
	public function testReplaceBySelector(): Void {
		final source: String = 'class C {\n\tfunction f():Void {}\n}\n';
		final expected: String = 'class C {\n\tfunction g():Int\n\t\treturn 0;\n}\n';
		assertReplace(source, BySelector('FnMember:f'), 'function g():Int return 0;', expected);
	}

	/**
	 * Replace the node at a cursor — column in the `apq refs` convention
	 * (the op inverts it). Line 2 col 10 is the `f` method name token; the
	 * innermost spanned node there is the whole `FnMember`.
	 */
	public function testReplaceByPosition(): Void {
		final source: String = 'class C {\n\tfunction f():Void {}\n}\n';
		final expected: String = 'class C {\n\tfunction h():Void {}\n}\n';
		assertReplace(source, ByPosition(2, 11), 'function h():Void {}', expected);
	}

	/** Refuse a selector that matches no node. */
	public function testRefuseSelectorNoMatch(): Void {
		final source: String = 'class C {\n\tfunction f():Void {}\n}\n';
		assertRefused(source, BySelector('FnMember:nope'), 'x');
	}

	/** Refuse an ambiguous selector — `VarMember` matches both fields. */
	public function testRefuseSelectorAmbiguous(): Void {
		final source: String = 'class C {\n\tvar a:Int;\n\tvar b:Int;\n}\n';
		assertRefused(source, BySelector('VarMember'), 'var c:Int;');
	}

	/** Refuse a malformed replacement — the whole-file re-emit fails. */
	public function testRefuseMalformedReplacement(): Void {
		final source: String = 'class C {\n\tfunction f():Void {}\n}\n';
		assertRefused(source, BySelector('FnMember:f'), '@@@ not haxe');
	}

	/** Refuse a non-canonical file (4-space indent) without `--reformat`. */
	public function testRefuseNonCanonicalWithoutReformat(): Void {
		final source: String = 'class C {\n    function f():Void {}\n}\n';
		assertRefused(source, BySelector('FnMember:f'), 'function h():Void {}');
	}

	/**
	 * Replace a MODIFIER-decorated method. `private static function f`
	 * projects to `(Private)(Static)(FnMember)`, so `--select FnMember`
	 * resolves only the `function …` node; the replaced range folds in the
	 * preceding modifier siblings (`RefactorSupport.declGroupSpan`) so the
	 * replacement is the FULL declaration as written — `private static` is
	 * REPLACED, not duplicated ahead of a second `private static`.
	 */
	public function testReplaceFoldsModifierGroup(): Void {
		final source: String = 'class C {\n\tprivate static function f():Void {}\n}\n';
		final expected: String = 'class C {\n\tprivate static function g():Int\n\t\treturn 0;\n}\n';
		assertReplace(source, BySelector('FnMember:f'), 'private static function g():Int return 0;', expected);
	}

	/**
	 * `--at <l>:<c> --kind <Kind>` (`ByKindPosition`) reaches a co-starting
	 * node plain `--at` skips past: the cursor sits on `b` inside `a + b * c`,
	 * `--kind Mul` selects the whole `b * c` subtree (innermost overall would
	 * be `IdentExpr b`).
	 */
	public function testReplaceByKindMul(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar x = a + b * c;\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar x = a + q;\n\t}\n}\n';
		assertReplace(source, ByKindPosition(3, 15, 'Mul'), 'q', expected, true);
	}

	/** `--kind Add` at the left operand selects the whole `a + b * c` Add. */
	public function testReplaceByKindAdd(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar x = a + b * c;\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar x = z;\n\t}\n}\n';
		assertReplace(source, ByKindPosition(3, 11, 'Add'), 'z', expected, true);
	}

	/** A cursor with no node of the requested kind is refused. */
	public function testRefuseKindNoMatch(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar x = a + b;\n\t}\n}\n';
		assertRefused(source, ByKindPosition(3, 11, 'Mul'), 'q', true);
	}

	/**
	 * `--with-doc` extends the replaced range over the leading doc comment, so
	 * the new source rewrites the declaration AND its documentation block.
	 */
	public function testReplaceWithDoc(): Void {
		final source: String = 'class C {\n\t/** old */\n\tpublic function f():Void {}\n}\n';
		final expected: String = 'class C {\n\t/** new */\n\tpublic function g():Void {}\n}\n';
		final result: EditResult = ReplaceNode.replaceNode(
			source, ByKindPosition(3, 9, 'FnMember'), '/** new */\npublic function g():Void {}', true, new HaxeQueryPlugin(), true
		);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * When `newSource` itself opens with a doc comment, the existing leading doc is
	 * absorbed automatically — WITHOUT `--with-doc` — so the result carries ONE doc
	 * block, not the new one stacked above the surviving old one.
	 */
	public function testNewSourceDocFoldsLeadingDoc(): Void {
		final source: String = 'class C {\n\t/** old */\n\tpublic function f():Void {}\n}\n';
		final expected: String = 'class C {\n\t/** new */\n\tpublic function g():Void {}\n}\n';
		assertReplace(source, ByKindPosition(3, 9, 'FnMember'), '/** new */\npublic function g():Void {}', expected, true);
	}

	/**
	 * A bare modifier keyword as `newSource` is refused — it would replace the
	 * WHOLE resolved declaration (body included) with the orphan keyword, which
	 * attaches to the next decl and may still parse (the silent-corruption trap
	 * `set-modifier` exists for).
	 */
	public function testBareModifierNewSourceRefused(): Void {
		final source: String = 'class C {\n\tprivate static function walk():Void {\n\t\ttrace(1);\n\t}\n\n\tfunction next():Void {}\n'
			+ '}\n';
		assertRefused(source, BySelector('FnMember:walk'), 'public');
		assertRefused(source, ByPosition(2, 2), ' final ');
	}

	/**
	 * The auto-fold absorbs only the leading DOC run, not a distinct block comment
	 * above it: a leading block-comment banner survives when the new source opens
	 * with a doc.
	 */
	public function testNewSourceDocPreservesBannerAboveDoc(): Void {
		final source: String = 'class C {\n\t/* banner */\n\t/** old */\n\tpublic function f():Void {}\n}\n';
		final expected: String = 'class C {\n\t/* banner */\n\t/** new */\n\tpublic function g():Void {}\n}\n';
		assertReplace(source, ByKindPosition(4, 9, 'FnMember'), '/** new */\npublic function g():Void {}', expected, true);
	}

	private function assertReplace(
		source: String, target: ReplaceTarget, newSource: String, expected: String, reformat: Bool = false
	): Void {
		final result: EditResult = replaceOf(source, target, newSource, reformat);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				assertReparses(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source: String, target: ReplaceTarget, newSource: String, reformat: Bool = false): Void {
		final result: EditResult = replaceOf(source, target, newSource, reformat);
		switch result {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

	private function assertReparses(text: String): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		try {
			plugin.parseFile(text);
			Assert.pass();
		} catch (exception: Exception) {
			Assert.fail('replace-node output failed to re-parse: ${exception.message}\n$text');
		}
	}

	private static function replaceOf(source: String, target: ReplaceTarget, newSource: String, reformat: Bool): EditResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return ReplaceNode.replaceNode(source, target, newSource, reformat, plugin);
	}

}
