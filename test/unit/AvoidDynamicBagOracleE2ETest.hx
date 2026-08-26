package unit;

import anyparse.check.CompilerOracle;
import anyparse.query.Cli;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * End-to-end coverage of the `avoid-dynamic` DynamicAccess bag arm (D4) through the whole
 * `lint --fix` + `compilerOracle` path: a `Dynamic` string-keyed bag whose written values
 * are `String` is converted to `DynamicAccess<String>` with map syntax, while the TM
 * `Form.hx` shape — `result.setField(g.field, g.value)` with `g.value : Dynamic` — is left
 * report-only (its values unify to `Dynamic`, and `DynamicAccess<Dynamic>` is the rejected
 * typeless shape). The oracle names the `g.value` field-access type the structural pass
 * cannot pin, and re-typechecks so a bad conversion reverts.
 *
 * Spawns the real compiler, so each scenario probes availability and skips gracefully when
 * the host has no `haxe` on PATH.
 */
class AvoidDynamicBagOracleE2ETest extends Test {

	#if (sys || nodejs)
	private static final POSITIVE: String = 'using Reflect;\n\nclass Main {\n\n\tstatic function main() {\n\t\ttrace(build());\n\t}\n\n\t'
		+ 'static function build():Dynamic {\n\t\tfinal bag:Dynamic = {};\n\t\tbag.setField("a", "x");\n\t\tbag.setField("b", "y");\n\t\t'
		+ 'return bag;\n\t}\n\n}\n';
	private static final POSITIVE_HXML: String = '-cp .\n-main Main\n';
	private static final FORM: String = 'using Reflect;\n\nclass Form {\n\n\tfinal _groups:Map<String, FormGroup> = new Map();\n\n\t'
		+ 'public function new() {}\n\n\tpublic function get_data():Dynamic {\n\t\tfinal result:Dynamic = {};\n\t\t'
		+ 'for (g in _groups) result.setField(g.field, g.value);\n\t\treturn result;\n\t}\n\n}\n\nclass FormGroup {\n\n\t'
		+ 'public var field:String = "";\n\n\tpublic var value:Dynamic;\n\n\tpublic function new() {}\n\n}\n';
	private static final FORM_HXML: String = '-cp .\nForm\n';
	private static final APQLINT: String = '{"compilerOracle":"check.hxml","rules":{"avoid-dynamic":{"enabled":true}}}';
	#end

	public function testStringBagConvertedViaCli(): Void {
		#if (sys || nodejs)
		if (!oracleWorks(POSITIVE, POSITIVE_HXML)) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('bage2e', [
			{ name: 'Main.hx', source: POSITIVE },
			{ name: 'check.hxml', source: POSITIVE_HXML },
			{ name: 'apqlint.json', source: APQLINT }
		]);
		Cli.run(['lint', '--fix', '--rule', 'avoid-dynamic', '$dir/Main.hx']);
		final onDisk: String = File.getContent('$dir/Main.hx');
		Assert.isTrue(onDisk.indexOf('DynamicAccess<String>') != -1, 'the String bag is converted');
		Assert.isTrue(onDisk.indexOf('bag["a"] = "x"') != -1, 'a setField became map syntax');
		Assert.isTrue(onDisk.indexOf('import haxe.DynamicAccess;') != -1, 'the import is added');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testFormShapeStaysTypeless(): Void {
		#if (sys || nodejs)
		if (!oracleWorks(FORM, FORM_HXML)) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('bage2e', [
			{ name: 'Form.hx', source: FORM },
			{ name: 'check.hxml', source: FORM_HXML },
			{ name: 'apqlint.json', source: APQLINT }
		]);
		Cli.run(['lint', '--fix', '--rule', 'avoid-dynamic', '$dir/Form.hx']);
		final onDisk: String = File.getContent('$dir/Form.hx');
		Assert.isTrue(onDisk.indexOf('final result:Dynamic = {}') != -1, 'the Form bag stays raw Dynamic (typeless)');
		Assert.isTrue(onDisk.indexOf('result.setField(g.field, g.value)') != -1, 'the reflect op is not rewritten');
		Assert.equals(-1, onDisk.indexOf('DynamicAccess'), 'no DynamicAccess conversion');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private function oracleWorks(source: String, hxml: String): Bool {
		final name: String = hxml.indexOf('-main Main') != -1 ? 'Main.hx' : 'Form.hx';
		final dir: String = CliFixture.writeDir('bage2e', [{ name: name, source: source }, { name: 'check.hxml', source: hxml }]);
		final ok: Bool = switch CompilerOracle.typecheck('check.hxml', dir) {
			case Confirmed: true;
			case _: false;
		};
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

}
