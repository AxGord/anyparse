package unit.check.haxe.expressions;

import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.haxe.expressions.PreferStaticExtension;
import anyparse.check.haxe.loops.PreferExists;
import anyparse.query.CanonicalEdit;
import unit.cli.CliFixture;

/**
 * `prefer-static-extension --fix` under an AMBIENT `using`: a module whose folder's `import.hx` already
 * brings the extension module in gets the rewrite and no second `using` line; one without it still gets the insert.
 */
class PreferStaticExtensionAmbientUsingTest extends Test {

	private static final EXT_SOURCE: String = 'class Ext {\n\tpublic static function deco(w: Widget, n: Int): Widget return w;\n}\n';
	private static final USER_SOURCE: String = 'import Widget;\n\nclass C {\n\tfunction f(w:Widget):Void {\n\t\tExt.deco(w, 1);\n\t}\n}\n';
	private static final EXT_CONFIG: String = '{"rules": {"prefer-static-extension": {"types": ["Ext"]}}}';
	private static final EXISTS_SOURCE: String =
		'class C {\n\tfunction f(xs:Array<Int>):Bool {\n\t\tfor (x in xs) if (x > 2) return true;\n\t\treturn false;\n\t}\n}\n';

	@:pin('control')
	@:killer('M-PSE-AMBIENT-USING-IGNORED')
	public function testAmbientUsingGetsRewriteAndNoInsert(): Void {
		final out: String = fixResultOf('using Ext;\n');
		Assert.isTrue(out.indexOf('w.deco(1);') != -1, out);
		Assert.isTrue(out.indexOf('using Ext;') == -1, out);
	}

	@:pin('guard')
	public function testNoAmbientUsingStillGetsInsert(): Void {
		final out: String = fixResultOf('import Widget;\n');
		Assert.isTrue(out.indexOf('w.deco(1);') != -1, out);
		Assert.isTrue(out.indexOf('using Ext;') != -1, out);
	}

	/** A sibling inserter (`prefer-exists`) reads the same scope answer, so a folder's `using Lambda;` spares it the insert too. */
	@:pin('control')
	@:killer('M-PSE-AMBIENT-USING-IGNORED')
	public function testSiblingRuleUnderAmbientLambdaGetsNoInsert(): Void {
		final out: String = fixResultOf('using Lambda;\n', EXISTS_SOURCE, true);
		Assert.isTrue(out.indexOf('xs.exists(') != -1, out);
		Assert.isTrue(out.indexOf('using Lambda;') == -1, out);
	}

	/** An ambient `using` under `#if` binds in some builds only, so it is no cover: the rewrite keeps its own `using`. */
	@:pin('control')
	@:killer('M-AMBIENT-USING-GUARDED-COUNTS')
	public function testGuardedAmbientUsingStillGetsInsert(): Void {
		final out: String = fixResultOf('#if FLAG\nusing Ext;\n#end\n');
		Assert.isTrue(out.indexOf('w.deco(1);') != -1, out);
		Assert.isTrue(out.indexOf('using Ext;') != -1, out);
	}

	private function fixResultOf(importHx: String, ?userSource: String, exists: Bool = false): String {
		final tree: Array<{ name: String, source: String }> = [
			{ name: 'src/lib/C.hx', source: userSource ?? USER_SOURCE },
			{ name: 'src/lib/import.hx', source: importHx },
			{ name: 'src/Ext.hx', source: EXT_SOURCE },
			{ name: 'src/Widget.hx', source: 'class Widget {}\n' }
		];
		final root: String = CliFixture.writeTree('prefer_static_ext_ambient', tree);
		final files: Array<{ file: String, source: String }> = tree.map(t -> { file: '$root/${t.name}', source: t.source });
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: Check = exists ? new PreferExists() : new PreferStaticExtension();
		if (!exists) cast(check, PreferStaticExtension).setConfigResolver(_ -> LintConfig.parse(EXT_CONFIG));
		final own: Array<Violation> = CheckFixture.violationsIn(check, files, plugin).filter(v -> v.file == files[0].file);
		Assert.equals(1, own.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(files[0].source, own, plugin, CheckFixture.index(files, plugin));
		final result: EditResult = CanonicalEdit.canonicalize(files[0].source, edits, false, plugin);
		CliFixture.removeDir(root);
		switch result {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

}
