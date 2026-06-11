package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BracePlacement;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-typedef-anon-force-multi — runtime force-multi-line layout for
 * typedef-RHS anon types. Verifies the `_inTypedefBody` opt-fanout
 * (set by `propagateTypedefContext` on `HxTypedefDecl.type`) plus the
 * `forceMultiInTypedef` Star meta on `HxType.Anon.fields` gated by
 * `opt.anonTypeLeftCurly == BracePlacement.Next` reaches `WrapList.emit`
 * and bypasses the cascade.
 */
@:nullSafety(Strict)
class HxTypedefAnonForceMultiTest extends Test {

	public function new(): Void {
		super();
	}

	public function testFlagDefaultsFalse(): Void {
		final defaults: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.isFalse(defaults._inTypedefBody);
	}

	public function testFlatTypedefStaysFlatUnderSame(): Void {
		// Default `anonTypeLeftCurly = Same` — even with the propagation
		// flag set, the gate `anonTypeLeftCurly == Next` is false → no
		// force-multi → cascade picks `NoWrap` → output stays flat.
		final out: String = writeFlat('typedef T = {x:Int, y:Int, z:Int};', BracePlacement.Same);
		Assert.isTrue(out.indexOf('typedef T = {x:Int, y:Int, z:Int};') != -1, 'expected flat typedef-RHS under Same in: <$out>');
	}

	public function testFlatTypedefForcedMultiUnderNext(): Void {
		// `anonTypeLeftCurly = Next` — gate fires, forceMode threads
		// `WrapMode.OnePerLine` into `WrapList.emit`. Body must break
		// each field onto its own line and `{` lands on its own line
		// (leadBreak = `_doh()` for Next).
		final out: String = writeFlat('typedef T = {x:Int, y:Int, z:Int};', BracePlacement.Next);
		Assert.isTrue(out.indexOf('typedef T =\n{') != -1, 'expected `typedef T =\\n{` in: <$out>');
		Assert.isTrue(out.indexOf('\n\tx:Int,\n\ty:Int,\n\tz:Int\n}') != -1, 'expected one-per-line body in: <$out>');
	}

	public function testFlatNonTypedefAnonNotForcedUnderNext(): Void {
		// Even with `anonTypeLeftCurly = Next`, a var-type-hint anon
		// (`var a:{x:Int, y:Int};`) does NOT have `_inTypedefBody=true`
		// — gate stays false, cascade decides layout. Short field count
		// stays flat per `WrapRules`.
		final out: String = writeFlat('class C { var a:{x:Int, y:Int}; }', BracePlacement.Next);
		Assert.isTrue(out.indexOf('var a:{x:Int, y:Int};') != -1, 'expected flat var-type-hint anon under Next in: <$out>');
	}

	public function testIssue301Probe(): Void {
		// Diagnostic probe: write the exact issue_301 corpus input with
		// fork's `{"lineEnds": {"leftCurly": "both"}}` config and inspect
		// what shape we produce. Used to identify whether force-multi
		// fires AND whether the residual diff is body-shape or
		// inter-typedef blank line.
		final src: String = 'typedef Point2D = {\n\tx:Int,\n\ty:Int\n\t};\ntypedef Point3D = {x:Int, y:Int, z:Int};\n\nclass A {\n\tvar a:{x:Int, y:Int, z:Int};\n\tvar a:{\n\t\tx:Int,\n\t\ty:Int,\n\t\tz:Int\n\t};\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"leftCurly": "both"}}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		// Probe: Point3D body should be multi-line (force-multi fires).
		// This is the contract of THIS slice. The remaining residual byte-
		// diff in the corpus issue_301 fixture is driven by two unrelated
		// gaps (deferred to follow-up slices):
		//  - inter-typedef blank-line (emptylines policy at HxModule.decls)
		//  - extra-indent on multi-line var-type-hint anon (RHS-indent gate)
		Assert.isTrue(
			out.indexOf('typedef Point3D =\n{\n\tx:Int,\n\ty:Int,\n\tz:Int\n}') != -1,
			'expected force-multi Point3D body in output:\n<$out>'
		);
	}

	private inline function writeFlat(src: String, leftCurly: BracePlacement): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(leftCurly));
	}

	private inline function makeOpts(leftCurly: BracePlacement): HxModuleWriteOptions {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.anonTypeLeftCurly = leftCurly;
		return opts;
	}

}
