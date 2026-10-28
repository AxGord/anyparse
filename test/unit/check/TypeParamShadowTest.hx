package unit.check;

import anyparse.check.ExplicitType;
import anyparse.check.ShortenTypeRef;
import anyparse.check.oracle.PositionTypeOracle;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;

/**
 * A type parameter in scope binds its simple name ahead of every type, so a short name the
 * printer would otherwise write there re-binds the reference to the parameter — and it still
 * compiles, the function silently turning generic over it. Each fixer that prints through
 * `TypeRefPrinter` must keep the qualified form at such a site.
 */
@:nullSafety(Strict)
final class TypeParamShadowTest extends Test {

	private static final HOLDER: String = 'package p;\n\nclass Holder {\n\n\tpublic final x:Int = 0;\n\n}\n';

	/** A method's type parameter named like the module's own sub-type, both written module-qualified. */
	private static final METHOD_PARAM: String = 'package p;\n\ntypedef First = {a:Int};\n\ntypedef Content = Holder;\n\nclass Mod {\n\n'
		+ '\tstatic function g<Content:Holder>(c:p.Mod.Content):Int {\n\t\tfinal d:p.Mod.Content = c;\n\t\treturn d.x;\n\t}\n\n}\n';

	/** A class's type parameter named like a same-package type the class body writes qualified. */
	private static final CLASS_PARAM: String =
		'package p;\n\nclass Mod<Holder> {\n\n\tpublic function new() {}\n\n\tfunction f(c:p.Holder):Int {\n\t\treturn c.x;\n\t}\n\n}\n';

	/** A method's type parameter named like the same-package type its untyped parameter holds. */
	private static final ORACLE_PARAM: String = 'package p;\n\nclass Mod {\n\n\tpublic function new() {}\n\n'
		+ '\tstatic function cb<Holder:p.Holder>(t:Holder, c):Int {\n\t\treturn take(c) + t.x;\n\t}\n\n'
		+ '\tstatic function take(c:p.Holder):Int {\n\t\treturn c.x;\n\t}\n\n}\n';

	public function new() {
		super();
	}

	@:pin('control')
	@:killer('M-PRINTER-TYPE-PARAM-BLIND')
	public function testShortenTypeRefKeepsAPathAMethodTypeParameterShadows(): Void {
		assertUntouchedByShorten(METHOD_PARAM);
	}

	@:pin('control')
	@:killer('M-PRINTER-TYPE-PARAM-BLIND')
	public function testShortenTypeRefKeepsAPathAClassTypeParameterShadows(): Void {
		assertUntouchedByShorten(CLASS_PARAM);
	}

	@:pin('control')
	@:killer('M-PRINTER-TYPE-PARAM-BLIND')
	public function testExplicitTypeOracleKeepsAPathAMethodTypeParameterShadows(): Void {
		final check: ExplicitType = new ExplicitType();
		final report: Array<{ file: String, source: String }> = beside(ORACLE_PARAM);
		final plugin: CachingGrammarPlugin = scopedPlugin(report);
		final violations: Array<Violation> = CheckFixture.violationsIn(check, [report[0]], plugin);
		final out: String = CanonicalEdit.applyEdits(
			ORACLE_PARAM, check.fixWithOracle(ORACLE_PARAM, violations, plugin, new HolderTypeOracle('p.Holder'))
		);
		Assert.isTrue(out.indexOf('cb<Holder:p.Holder>(t:Holder, c:p.Holder):Int') != -1, 'qualified, got: $out');
	}

	// --- helpers -------------------------------------------------------------------

	/** `source` as `p/Mod.hx` draws no `shorten-type-ref` finding and no edit. */
	private function assertUntouchedByShorten(source: String): Void {
		final report: Array<{ file: String, source: String }> = beside(source);
		final plugin: CachingGrammarPlugin = scopedPlugin(report);
		Assert.equals(0, CheckFixture.violationsIn(new ShortenTypeRef(), report, plugin).length);
		Assert.equals(source, CanonicalEdit.applyEdits(source, CheckFixture.fixRun(new ShortenTypeRef(), report, plugin).edits));
	}

	/** `source` as `p/Mod.hx` with the class it refers to — the report and resolution scope every pin runs over. */
	private function beside(source: String): Array<{ file: String, source: String }> {
		return [{ file: 'p/Mod.hx', source: source }, { file: 'p/Holder.hx', source: HOLDER }];
	}

	/** A plugin whose resolution scope is exactly `report`. */
	private function scopedPlugin(report: Array<{ file: String, source: String }>): CachingGrammarPlugin {
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({
			declared: true,
			sources: () -> {report: report, projectRoots: [], library: new LibrarySources([]) }
		});
		return scoped;
	}

}

/** A `TypeOracle` double answering one type at every position — no compiler, no process. */
@:nullSafety(Strict)
private final class HolderTypeOracle extends PositionTypeOracle {

	private final _type: String;

	public function new(type: String) {
		super(new HaxeQueryPlugin().typeSyntax);
		_type = type;
	}

	public function typeAt(file: String, bytePos: Int): Null<String> {
		return _type;
	}

}
