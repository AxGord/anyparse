package unit.check;

import anyparse.check.ExplicitLocalType;
import anyparse.check.ExplicitType;
import anyparse.check.ShortenTypeRef;
import anyparse.check.oracle.PositionTypeOracle;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;

using StringTools;

/**
 * Every `TypeRefPrinter` consumer names the module of the file it prints into by the FILE, the
 * way the compiler and the index do — never by the module's first top-level declaration. A
 * module whose first declaration is an unrelated helper typedef is the shape that told them
 * apart: a sub-type declared beside it must still print by its short name, in the oracle passes
 * of `explicit-type` and `explicit-local-type` and in `shorten-type-ref` alike.
 */
@:nullSafety(Strict)
final class ModuleNameFromPathTest extends Test {

	/** The sub-type's declaration path — what `shorten-type-ref` finds written out in full. */
	private static inline final CANONICAL: String = 'p.Mod.Content';

	/** How the compiler names that sub-type: package plus simple name, with the module dropped. */
	private static inline final HYBRID: String = 'p.Content';

	/** The module `p.Mod` with an unrelated typedef ahead of its main type, and `Content` declared beside both. */
	private static final HELPER_FIRST: String = 'package p;\n\ntypedef First = {a:Int};\n\ntypedef Content = Holder;\n\n'
		+ 'class Mod {\n\n\tpublic function new() {}\n\n\tprivate function cb(c):Int {\n\t\treturn take(c);\n\t}\n\n'
		+ '\tprivate function f():Void {\n\t\tvar v = load();\n\t\ttrace(v);\n\t}\n\n'
		+ '\tprivate static function take(c:Content):Int {\n\t\treturn c.x;\n\t}\n\n}\n';

	/** `HELPER_FIRST` with the main type declared first — the shape the first-declaration reading already got right. */
	private static final MAIN_FIRST: String = 'package p;\n\nclass Mod {\n\n\tpublic function new() {}\n\n\tprivate function cb(c):Int {\n'
		+ '\t\treturn take(c);\n\t}\n\n\tprivate function f():Void {\n\t\tvar v = load();\n\t\ttrace(v);\n'
		+ '\t}\n\n\tprivate static function take(c:Content):Int {\n\t\treturn c.x;\n\t}\n\n}\n\n'
		+ 'typedef First = {a:Int};\n\ntypedef Content = Holder;\n';

	private static final HOLDER: String = 'package p;\n\nclass Holder {\n\n\tpublic final x:Int = 0;\n\n}\n';

	public function new() {
		super();
	}

	@:pin('control')
	@:killer('M-PRINTER-MODULE-FROM-FIRST-DECL')
	public function testExplicitTypeOraclePrintsTheSubTypeShortBehindAHelperTypedef(): Void {
		final out: String = annotateParams(HELPER_FIRST);
		Assert.isTrue(out.indexOf('function cb(c:Content):Int') != -1, 'short name, got: $out');
		Assert.equals(-1, out.indexOf('import '), 'a module never imports its own sub-type, got: $out');
	}

	public function testExplicitTypeOraclePrintsTheSubTypeShortWithTheMainTypeFirst(): Void {
		final out: String = annotateParams(MAIN_FIRST);
		Assert.isTrue(out.indexOf('function cb(c:Content):Int') != -1, 'short name, got: $out');
	}

	@:pin('control')
	@:killer('M-PRINTER-MODULE-FROM-FIRST-DECL')
	public function testExplicitLocalTypeOraclePrintsTheSubTypeShortBehindAHelperTypedef(): Void {
		final out: String = annotateLocals(HELPER_FIRST);
		Assert.isTrue(out.indexOf('var v:Content = load();') != -1, 'short name, got: $out');
		Assert.equals(-1, out.indexOf('import '), 'a module never imports its own sub-type, got: $out');
	}

	@:pin('control')
	@:killer('M-PRINTER-MODULE-FROM-FIRST-DECL')
	public function testShortenTypeRefShortensTheSubTypeBehindAHelperTypedef(): Void {
		final src: String = HELPER_FIRST.replace('take(c:Content)', 'take(c:$CANONICAL)');
		final report: Array<{ file: String, source: String }> = beside(src);
		final plugin: CachingGrammarPlugin = scopedPlugin(report);
		Assert.equals(1, CheckFixture.violationsIn(new ShortenTypeRef(), report, plugin).length);
		final out: String = CanonicalEdit.applyEdits(src, CheckFixture.fixRun(new ShortenTypeRef(), report, plugin).edits);
		Assert.isTrue(out.indexOf('take(c:Content):Int') != -1, 'shortened, got: $out');
	}

	// --- helpers -------------------------------------------------------------------

	/** `source` as `p/Mod.hx` after `explicit-type`'s oracle pass, with the compiler naming `CANONICAL` everywhere. */
	private function annotateParams(source: String): String {
		final check: ExplicitType = new ExplicitType();
		final report: Array<{ file: String, source: String }> = beside(source);
		final plugin: CachingGrammarPlugin = scopedPlugin(report);
		final violations: Array<Violation> = CheckFixture.violationsIn(check, [report[0]], plugin);
		return CanonicalEdit.applyEdits(source, check.fixWithOracle(source, violations, plugin, new OneTypeOracle(HYBRID)));
	}

	/** `source` as `p/Mod.hx` after `explicit-local-type`'s oracle pass, with the compiler naming `CANONICAL` everywhere. */
	private function annotateLocals(source: String): String {
		final check: ExplicitLocalType = new ExplicitLocalType();
		final report: Array<{ file: String, source: String }> = beside(source);
		final plugin: CachingGrammarPlugin = scopedPlugin(report);
		final violations: Array<Violation> = CheckFixture.violationsIn(check, [report[0]], plugin);
		return CanonicalEdit.applyEdits(source, check.fixWithOracle(source, violations, plugin, new OneTypeOracle(HYBRID)));
	}

	/** `source` as `p/Mod.hx` with the class its sub-type aliases, the report and resolution scope every pin runs over. */
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
private final class OneTypeOracle extends PositionTypeOracle {

	private final _type: String;

	public function new(type: String) {
		super(new HaxeQueryPlugin().typeSyntax);
		_type = type;
	}

	public function typeAt(file: String, bytePos: Int): Null<String> {
		return _type;
	}

}
