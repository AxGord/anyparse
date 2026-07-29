package unit;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.NoUnderscorePrefix;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CachingGrammarPlugin.LibrarySources;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `no-underscore-prefix` check: a parameter / local binding whose name carries a
 * leading underscore is flagged, and the autofix strips every leading underscore when
 * the rename is provably complete and collision-free. Each test runs a real
 * `HaxeQueryPlugin` over an in-memory source and asserts the findings, or canonicalizes
 * the check's edits and asserts the rewritten text.
 */
class NoUnderscorePrefixCheckTest extends Test {

	/** A config that turns `unused-parameter`'s silencing rename OFF, lifting the cross-rule loop guard. */
	private static inline final NO_SILENCE: String = '{"rules":{"unused-parameter":{"renameSilence":false}}}';

	public function testHandlerParameterFlagged(): Void {
		final vs: Array<Violation> = violations(handlerSource());
		Assert.equals(1, vs.length);
		Assert.equals('no-underscore-prefix', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains("'_event'"));
		Assert.isTrue(vs[0].message.contains('parameter'));
	}

	public function testHandlerParameterRenamed(): Void {
		final src: String = handlerSource();
		assertFixed(src, ['selectHandler(event:Event)', 'trace(event.type)'], ['_event']);
	}

	public function testConstructorParameterRenamed(): Void {
		final src: String = 'package pkg;\n'
			+ 'class SidePanel {\n\tprivate var _width:Float;\n\tpublic function new(_contentWidth:Float) {\n'
			+ '\t\t_width = _contentWidth;\n\t}\n}';
		assertFixed(src, ['new(contentWidth:Float)', '_width = contentWidth;'], ['_contentWidth']);
	}

	public function testLocalsRenamed(): Void {
		// The enclosing class declares no `items` / `selectedIndex` member, so both strips land.
		final src: String = localsSource();
		final vs: Array<Violation> = violations(src);
		Assert.equals(2, vs.length);
		assertFixed(src, [
			'var selectedIndex:Int = 0;',
			'final items:Array<String> = [];',
			'trace(selectedIndex + items.length);'
		], ['__selectedIndex', '_items']);
	}

	public function testFieldWriteConstructorSkipped(): Void {
		// The killer case: `x` is a FIELD the constructor writes from `_x`. Renaming `_x` -> `x`
		// would silently turn the field write into a parameter self-assignment, so the in-scope
		// collision proof must refuse it — reported, never fixed.
		final src: String = 'package pkg;\nclass Slider {\n\tprivate var x:Float;\n\tpublic function new(_x:Float) {\n\t\tx = _x;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testSiblingParameterCollisionSkipped(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function f(_a:Int, a:Int):Void {\n\t\ttrace(_a + a);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testOverlappingLocalCollisionSkipped(): Void {
		final src: String = 'package pkg;\n'
			+ 'class C {\n\tpublic function f():Void {\n\t\tfinal _value:Int = 1;\n\t\tfinal value:Int = 2;\n\t\ttrace(_value + value);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testCatchVariableNeverFlagged(): Void {
		// A `_`-prefixed catch variable is `swallowed-exception`'s intentional-discard marker.
		final src: String = 'package pkg;\n'
			+ 'class C {\n\tpublic function f():Void {\n\t\ttry doThing() catch (_exception:Exception) {}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testDiscardAndDunderNamesNeverFlagged(): Void {
		final src: String = 'package pkg;\n'
			+ 'class C {\n\tpublic function f(xs:Array<Int>):Void {\n\t\tfor (_ in xs) trace(1);\n\t\tfor (__ in xs) trace(2);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testLoopAndComprehensionVariablesFlagged(): Void {
		final src: String = 'package pkg;\n'
			+ 'class C {\n\tpublic function f(xs:Array<Int>):Void {\n\t\tfinal ys:Array<Int> = [for (_i in xs) _i];\n'
			+ '\t\tfor (_item in xs) trace(_item + ys.length);\n\t}\n}';
		Assert.equals(2, violations(src).length);
		assertFixed(src, ['[for (i in xs) i]', 'for (item in xs) trace(item + ys.length)'], ['_i', '_item']);
	}

	public function testParamsOptionOff(): Void {
		final vs: Array<Violation> = violations(mixedSource(), '{"rules":{"no-underscore-prefix":{"params":false}}}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'_total'"));
	}

	public function testLocalsOptionOff(): Void {
		final vs: Array<Violation> = violations(mixedSource(), '{"rules":{"no-underscore-prefix":{"locals":false}}}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'_count'"));
	}

	public function testUnreferencedParameterSkippedWhileSilencingRenameLive(): Void {
		// `unused-parameter` silences an unremovable parameter by renaming it to `_<name>`;
		// de-prefixing the same parameter here would ping-pong the two fixes forever.
		final src: String = unusedParamSource();
		Assert.equals(0, violations(src).length);
		Assert.equals(0, violations(src, '{"rules":{"unused-parameter":{"renameSilence":true}}}').length);
	}

	public function testUnreferencedParameterFlaggedWhenSilencingRenameOff(): Void {
		Assert.equals(1, violations(unusedParamSource(), NO_SILENCE).length);
	}

	public function testUnreferencedParameterFlaggedWhenUnusedParameterDisabled(): Void {
		Assert.equals(1, violations(unusedParamSource(), '{"rules":{"unused-parameter":{"enabled":false}}}').length);
	}

	public function testStringInterpolationReadRenamesAlong(): Void {
		// A simple `$name` read is not in the reference walker's index; the check resolves it
		// through `stringInterpIdentKind` so it renames along instead of blocking the fix.
		final src: String = "package pkg;\nclass C {\n\tpublic function f(_name:String):Void {\n\t\ttrace('hi $_name');\n\t}\n}";
		assertFixed(src, ['f(name:String)', "hi $name"], ['_name']);
	}

	public function testDoubleQuotedDollarBlocksFix(): Void {
		// `"$_name"` in a DOUBLE-quoted string is literal text, not a read: it stays uncovered
		// and the completeness gate refuses the whole rename.
		final src: String = 'package pkg;\n'
			+ "class C {\n\tpublic function f(_name:String):Void {\n\t\ttrace(_name);\n\t\ttrace(\"hi $_name\");\n\t}\n}";
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testConditionalRegionRenamesAlong(): Void {
		// A `#if` region whose body PARSES is projected as real statements the resolver binds, so
		// its occurrence renames with the rest instead of blocking (the raw-trivia case still does).
		final src: String = 'package pkg;\n'
			+ 'class C {\n\tpublic function f(_flag:Bool):Void {\n\t\ttrace(_flag);\n\t\t#if debug\n\t\ttrace(_flag);\n\t\t#end\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(3, edits(src).length);
		assertFixed(src, ['f(flag:Bool)', '#if debug'], ['_flag']);
	}

	public function testKeywordTargetSkipped(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function f(_new:Int):Void {\n\t\ttrace(_new);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testNonIdentifierTargetSkipped(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function f(_1:Int):Void {\n\t\ttrace(_1);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testStrippedNameViolatingPolicyFormatSkipped(): Void {
		// `_MAX` -> `MAX` is not a camelCase local: trading this finding for a `naming` one is
		// not a fix, so the strip is refused.
		final src: String = 'package pkg;\nclass C {\n\tpublic function f():Void {\n\t\tfinal _MAX:Int = 1;\n\t\ttrace(_MAX);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testAnonStructureFieldNeverFlagged(): Void {
		final src: String = 'package pkg;\ntypedef Payload = {\n\tvar _key:String;\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testInheritedMemberBlocksRename(): Void {
		// `Base.value` is inherited but never written in this file, so the in-file scan cannot
		// see it; the supertype closure walked through the resolution scope does.
		final subSrc: String = 'package pkg;\nclass Sub extends Base {\n\tpublic function f(_value:Int):Void {\n\t\ttrace(_value);\n\t}\n}';
		Assert.equals(0, fixWithResolutionScope(subSrc, 'package ext;\nclass Base {\n\tpublic var value:Int;\n}').length);
	}

	public function testCleanSupertypeAllowsRename(): Void {
		final subSrc: String = 'package pkg;\nclass Sub extends Base {\n\tpublic function f(_value:Int):Void {\n\t\ttrace(_value);\n\t}\n}';
		Assert.equals(2, fixWithResolutionScope(subSrc, 'package ext;\nclass Base {}').length);
	}

	public function testTargetNamingADeclaredTypeSkipped(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function f(_payload:Int):Void {\n\t\ttrace(_payload);\n\t}\n}';
		final other: String = 'package pkg;\nclass payload {}';
		final files: Array<{ file: String, source: String }> =
			[{ file: 'pkg/C.hx', source: src }, { file: 'pkg/payload.hx', source: other }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: NoUnderscorePrefix = new NoUnderscorePrefix();
		final vs: Array<Violation> = check.run(files, plugin).filter(v -> v.file == 'pkg/C.hx');
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, plugin, SymbolIndex.build(files, plugin)).length);
	}

	/** A handler whose event parameter carries the private-field `_` prefix and IS referenced. */
	private function handlerSource(): String {
		return 'package pkg;\n' + 'class ViewPanel {\n\tprivate function selectHandler(_event:Event):Void {\n\t\ttrace(_event.type);\n\t}\n}';
	}

	/** Two underscore-prefixed locals in a class declaring neither name as a member. */
	private function localsSource(): String {
		return 'package pkg;\n' + 'class ListView {\n\tpublic function refresh():Void {\n\t\tvar __selectedIndex:Int = 0;\n'
			+ '\t\tfinal _items:Array<String> = [];\n\t\ttrace(__selectedIndex + _items.length);\n\t}\n}';
	}

	/** One underscore-prefixed parameter and one underscore-prefixed local, for the option toggles. */
	private function mixedSource(): String {
		return 'package pkg;\n'
			+ 'class C {\n\tpublic function f(_count:Int):Void {\n\t\tfinal _total:Int = _count + 1;\n\t\ttrace(_total);\n\t}\n}';
	}

	/** A parameter that is never referenced in its function — the cross-rule loop-guard fixture. */
	private function unusedParamSource(): String {
		return 'package pkg;\nclass C {\n\tpublic function f(_event:Int):Void {\n\t\ttrace(1);\n\t}\n}';
	}

	/** The check's findings for `src`, with `config` (raw `apqlint.json` text) in effect when given. */
	private function violations(src: String, ?config: String): Array<Violation> {
		final check: NoUnderscorePrefix = configured(config);
		return check.run([{ file: 'pkg/C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The check's autofix edits for `src`, resolved against a single-file index. */
	private function edits(src: String, ?config: String): Array<{ span: Span, text: String }> {
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: NoUnderscorePrefix = configured(config);
		return check.fix(src, check.run(files, plugin), plugin, SymbolIndex.build(files, plugin));
	}

	/** A check carrying `config` (raw `apqlint.json` text) as its per-file resolver, or the default one. */
	private function configured(config: Null<String>): NoUnderscorePrefix {
		final check: NoUnderscorePrefix = new NoUnderscorePrefix();
		if (config != null) {
			final parsed: LintConfig = LintConfig.parse(config);
			check.setConfigResolver(file -> parsed);
		}
		return check;
	}

	/** Canonicalize the check's edits for `src` and assert every `present` fragment appears and every `absent` one does not. */
	private function assertFixed(src: String, present: Array<String>, absent: Array<String>): Void {
		final applied: Array<{ span: Span, text: String }> = edits(src);
		Assert.isTrue(applied.length > 0);
		switch RefactorSupport.canonicalize(src, applied, true, new HaxeQueryPlugin()) {
			case Ok(text):
				for (fragment in present) Assert.isTrue(text.indexOf(fragment) >= 0, 'missing "$fragment" in:\n$text');
				for (fragment in absent) Assert.isTrue(text.indexOf(fragment) == -1, 'still present "$fragment" in:\n$text');
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	/** The check's edits for `subSrc` with `libSrc` joined as a RESOLUTION-scope library (never reported, never edited). */
	private function fixWithResolutionScope(subSrc: String, libSrc: String): Array<{ span: Span, text: String }> {
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/Sub.hx', source: subSrc }];
		final lib: Array<{ file: String, source: String }> = [{ file: 'ext/Base.hx', source: libSrc }];
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({ declared: true, sources: () -> {report: report, library: new LibrarySources(lib) } });
		final check: NoUnderscorePrefix = new NoUnderscorePrefix();
		final vs: Array<Violation> = check.run(report, scoped);
		Assert.equals(1, vs.length);
		return check.fix(subSrc, vs, scoped, SymbolIndex.build(report, new HaxeQueryPlugin()));
	}

}
