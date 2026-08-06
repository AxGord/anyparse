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

	/** A config that turns `unused-parameter`'s silencing rename off EXPLICITLY — the `false` value, as distinct from the absent option. */
	private static inline final NO_SILENCE: String = '{"rules":{"unused-parameter":{"renameSilence":false}}}';

	/** A config that opts the silencing rename in but disables the rule carrying it — the only shape where the guard's enablement conjunct decides. */
	private static inline final SILENCE_BUT_DISABLED: String = '{"rules":{"unused-parameter":{"enabled":false,"renameSilence":true}}}';

	/** A config that cedes the supertype-shadow veto for locals / parameters. */
	private static inline final ALLOW_SHADOW: String = '{"rules":{"no-underscore-prefix":{"allowInheritedShadow":true}}}';

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
		// `_` / `__` fail the prefix regex on their own; a DUNDER matches it and is stopped only
		// by the projection's `reservedName` — renaming `__init__` silently disables the runtime hook.
		final src: String = 'package pkg;\n'
			+ 'class C {\n\tpublic function f(xs:Array<Int>):Void {\n\t\tfor (_ in xs) trace(1);\n\t\tfor (__ in xs) trace(2);\n'
			+ '\t\tfinal __init__:Int = 1;\n\t\ttrace(__init__);\n\t}\n}';
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
		// de-prefixing the same parameter here would ping-pong the two fixes forever. The
		// guard is live only while that rename is opted IN.
		Assert.equals(0, violations(unusedParamSource(), '{"rules":{"unused-parameter":{"renameSilence":true}}}').length);
	}

	public function testUnreferencedParameterFlaggedAndFixedWhenSilencingRenameAbsent(): Void {
		// `renameSilence` defaults FALSE, so an absent option leaves no silencing rename to
		// fight: the unreferenced `_event` is flagged AND de-underscored like any other
		// parameter. This is what makes the rule reach a real project's handler signatures.
		final src: String = unusedParamSource();
		Assert.equals(1, violations(src).length);
		assertFixed(src, ['f(event:Int)'], ['_event']);
	}

	public function testUnreferencedParameterFlaggedWhenSilencingRenameOff(): Void {
		Assert.equals(1, violations(unusedParamSource(), NO_SILENCE).length);
	}

	public function testUnreferencedParameterFlaggedWhenUnusedParameterDisabled(): Void {
		// `renameSilence` is opted IN here on purpose: with it absent the knob arm alone would
		// lift the guard, and the test would pass without the enablement conjunct doing anything.
		Assert.equals(1, violations(unusedParamSource(), SILENCE_BUT_DISABLED).length);
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

	public function testKeywordTargetSkippedUnderPolicyWithoutNormalizer(): Void {
		// The reserved-word veto is the GRAMMAR's, not the policy's: a `checkstyle.json`-adapted
		// rule carries no normalizer and its camelCase format matches `dynamic` exactly as it
		// matches `event`, so gating the veto on the policy would emit source the parser rejects.
		final src: String = 'package pkg;\nclass C {\n\tpublic function f(_dynamic:Int):Void {\n\t\ttrace(_dynamic);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, editsUnderPolicy(src, '{"checks":[{"type":"ParameterName","props":{"format":"^[a-z][a-zA-Z0-9]*$"}}]}').length);
	}

	public function testKeywordTargetSkippedUnderPolicyGoverningNeitherCategory(): Void {
		// No applicable rule at all: the bare strip stands, but it is STILL keyword-checked.
		final src: String = 'package pkg;\nclass C {\n\tpublic function f(_new:Int):Void {\n\t\ttrace(_new);\n\t}\n}';
		Assert.equals(0, editsUnderPolicy(src, '{"checks":[{"type":"TypeName","props":{"format":"^[A-Z][a-zA-Z0-9]*$"}}]}').length);
	}

	public function testTwoBindingsStrippingToTheSameNameBothSkipped(): Void {
		// `_a` and `__a` both strip to `a`, and neither is visible to the other's collision proof
		// (that scans the PRE-fix source, where each still carries its own prefix). Renaming both
		// would merge two bindings into one — and Haxe permits the shadowing, so it would compile.
		final src: String = 'package pkg;\n'
			+ 'class C {\n\tpublic function f(_a:Int):Void {\n\t\tfinal __a:Int = 2;\n\t\ttrace(_a + __a);\n\t}\n}';
		Assert.equals(2, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testSameTargetInDisjointFunctionsStillRenames(): Void {
		// The conflict is scope-bounded: two bodies that cannot see each other both rename.
		final src: String = 'package pkg;\n'
			+ 'class C {\n\tpublic function f(_a:Int):Void {\n\t\ttrace(_a);\n\t}\n\n\tpublic function g(__a:Int):Void {\n\t\ttrace(__a);\n\t}\n}';
		Assert.equals(2, violations(src).length);
		assertFixed(src, ['f(a:Int)', 'g(a:Int)'], ['_a', '__a']);
	}

	public function testNestedClosureClaimingTheSameTargetSkipped(): Void {
		// The closure's scope lies INSIDE the enclosing function's, so the two conflict.
		final src: String = 'package pkg;\n'
			+ 'class C {\n\tpublic function f(_x:Int):Void {\n\t\tfinal g:Int -> Int = function(__x:Int) return __x + _x;\n'
			+ '\t\ttrace(g(1));\n\t}\n}';
		Assert.equals(2, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testNonIdentifierTargetSkipped(): Void {
		// Under a policy governing NEITHER category the format gate is absent, so the identifier
		// check is the only thing standing between `_1` and an emitted `1`.
		final src: String = 'package pkg;\nclass C {\n\tpublic function f(_1:Int):Void {\n\t\ttrace(_1);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
		Assert.equals(0, editsUnderPolicy(src, '{"checks":[{"type":"TypeName","props":{"format":"^[A-Z][a-zA-Z0-9]*$"}}]}').length);
	}

	public function testStrippedNameViolatingPolicyFormatSkipped(): Void {
		// `_MAX` -> `MAX` is not a camelCase local: trading this finding for a `naming` one is
		// not a fix, so the strip is refused.
		final src: String = 'package pkg;\nclass C {\n\tpublic function f():Void {\n\t\tfinal _MAX:Int = 1;\n\t\ttrace(_MAX);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testAnonStructureFieldNeverFlagged(): Void {
		// The SHORT anon form projects its members as `Required` — category Param, marked
		// `renameUnsafe` because the identifier is a wire contract. That is the gate under test;
		// the `var _key:String;` long form projects as `VarField`, which carries no category at all.
		Assert.equals(0, violations('package pkg;\ntypedef Payload = { _key:String };').length);
		Assert.equals(0, violations('package pkg;\ntypedef Payload = {\n\tvar _key:String;\n}').length);
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

	/**
	 * The check's autofix edits for `src` under a NAMING policy adapted from `checkstyle` content, discovered the way a real run discovers it - a `checkstyle.json` written next to the linted file. That is the shape whose rules carry no `normalize`, so the reserved-word veto cannot lean on the policy.
	 */
	private function editsUnderPolicy(src: String, checkstyle: String): Array<{ span: Span, text: String }> {
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = (tmp != null && tmp.length > 0) ? tmp : '/tmp';
		final dir: String = '$base/anyparse_nup_cfg_${Sys.time()}';
		sys.FileSystem.createDirectory(dir);
		sys.io.File.saveContent('$dir/checkstyle.json', checkstyle);
		final path: String = '$dir/C.hx';
		sys.io.File.saveContent(path, src);
		final files: Array<{ file: String, source: String }> = [{ file: path, source: src }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: NoUnderscorePrefix = new NoUnderscorePrefix();
		final out: Array<{ span: Span, text: String }> = check.fix(src, check.run(files, plugin), plugin, SymbolIndex.build(files, plugin));
		sys.FileSystem.deleteFile(path);
		sys.FileSystem.deleteFile('$dir/checkstyle.json');
		sys.FileSystem.deleteDirectory(dir);
		return out;
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
	private function fixWithResolutionScope(subSrc: String, libSrc: String, ?config: String): Array<{ span: Span, text: String }> {
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/Sub.hx', source: subSrc }];
		final lib: Array<{ file: String, source: String }> = [{ file: 'ext/Base.hx', source: libSrc }];
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({ declared: true, sources: () -> {report: report, library: new LibrarySources(lib) } });
		final check: NoUnderscorePrefix = configured(config);
		final vs: Array<Violation> = check.run(report, scoped);
		Assert.equals(1, vs.length);
		return check.fix(subSrc, vs, scoped, SymbolIndex.build(report, new HaxeQueryPlugin()));
	}


	/**
	 * A STRING LITERAL that happens to spell the target name is not a binding, so it
	 * must not veto the rename. `collidesInScope` asked a raw word-boundary text scan,
	 * which counted `': items: '` as an occurrence of `items` and declined.
	 */
	public function testStringLiteralDoesNotBlockRename(): Void {
		final src: String = 'class C {\n\tpublic function f():Void {\n\t\tvar _items:Int = 1;\n\t\ttrace(\': items: \', _items);\n\t}\n}';
		assertFixed(src, ['var items:Int = 1;', 'trace(\': items: \', items);'], ['_items']);
	}

	/**
	 * A DOTTED member access on an unrelated receiver is not a binding either:
	 * `o.scaleX` cannot conflict with a local named `scaleX`.
	 */
	public function testDottedMemberAccessDoesNotBlockRename(): Void {
		final src: String =
			'class C {\n\tpublic function g(o:Other):Void {\n\t\tvar __scaleX:Float = 1;\n\t\ttrace(o.scaleX, __scaleX);\n\t}\n}';
		assertFixed(src, ['var scaleX:Float = 1;', 'trace(o.scaleX, scaleX);'], ['__scaleX']);
	}

	/** A comment mentioning the target name is not a binding. */
	public function testCommentMentionDoesNotBlockRename(): Void {
		final src: String =
			'class C {\n\t// items are counted here\n\tpublic function f():Void {\n\t\tvar _items:Int = 1;\n\t\ttrace(_items);\n\t}\n}';
		assertFixed(src, ['var items:Int = 1;'], ['_items']);
	}

	/** GUARD: a real BARE binding of the target name still vetoes the rename. */
	public function testBareBindingStillBlocksRename(): Void {
		final src: String =
			'class C {\n\tpublic function f():Void {\n\t\tvar items:Int = 0;\n\t\tvar _items:Int = 1;\n\t\ttrace(items, _items);\n\t}\n}';
		Assert.equals(0, edits(src).length);
	}

	/** GUARD: an occurrence inside a `#if` body is real code and still vetoes it. */
	public function testConditionalBodyStillBlocksRename(): Void {
		final src: String =
			'class C {\n\tpublic function f():Void {\n\t\tvar _items:Int = 1;\n\t\t#if debug\n\t\tvar items:Int = 2;\n\t\ttrace(items);\n\t\t#end\n\t\ttrace(_items);\n\t}\n}';
		Assert.equals(0, edits(src).length);
	}

	/** GUARD: a `$name` interpolation read is a real reference and still vetoes it. */
	public function testInterpolationReadStillBlocksRename(): Void {
		final src: String =
			'class C {\n\tpublic function f(items:Int):Void {\n\t\tvar _items:Int = 1;\n\t\ttrace(\'$$items\', _items);\n\t}\n}';
		Assert.equals(0, edits(src).length);
	}


	/**
	 * `allowInheritedShadow` cedes the supertype veto for a local / parameter: shadowing an
	 * inherited member is legal Haxe, and in a UI codebase almost every class inherits a
	 * display-object member (`x`, `y`, `width`), so the veto silences the rule wholesale.
	 */
	public function testInheritedShadowAllowedWhenOptionOn(): Void {
		final subSrc: String = 'package pkg;\nclass Sub extends Base {\n\tpublic function f(_value:Int):Void {\n\t\ttrace(_value);\n\t}\n}';
		final libSrc: String = 'package ext;\nclass Base {\n\tpublic var value:Int;\n}';
		Assert.equals(2, fixWithResolutionScope(subSrc, libSrc, ALLOW_SHADOW).length);
	}


	/**
	 * The option cedes only the STYLE stance, never the correctness gate: a bare read of the
	 * inherited member inside the same function would be silently recaptured by the renamed
	 * binding, and `collidesInScope` still refuses that — with the option ON.
	 */
	public function testInheritedShadowStillBlockedByBareReadWhenOptionOn(): Void {
		final subSrc: String =
			'package pkg;\nclass Sub extends Base {\n\tpublic function f(_value:Int):Void {\n\t\ttrace(_value);\n\t\ttrace(value);\n\t}\n}';
		final libSrc: String = 'package ext;\nclass Base {\n\tpublic var value:Int;\n}';
		Assert.equals(0, fixWithResolutionScope(subSrc, libSrc, ALLOW_SHADOW).length);
	}


	/**
	 * A COMMENT mention inside a `#if` region is inert text, not a reference the resolver
	 * missed — so it must not veto a rename whose binding lives in another function entirely.
	 * The conditional class was decided before the lexical one, turning every commented-out
	 * line inside a `#if` into a file-wide blocker for that name.
	 */
	public function testCommentInConditionalRegionDoesNotBlockRename(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function f(_value:Int):Void {\n\t\ttrace(_value);\n\t}\n'
			+ '\t#if debug\n\tpublic function g():Void {\n\t\t// _value moved out\n\t\ttrace(1);\n\t}\n\t#end\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(2, edits(src).length);
	}

	/** The same, with the binding ITSELF inside the `#if` region: its own comment mention renames along. */
	public function testConditionalRegionBindingWithCommentRenamed(): Void {
		final src: String = 'package pkg;\nclass C {\n\t#if debug\n\tpublic function f(_value:Int):Int {\n'
			+ '\t\t// _value doubled\n\t\treturn _value * 2;\n\t}\n\t#end\n}';
		Assert.equals(1, violations(src).length);
		assertFixed(src, ['f(value:Int)', '// value doubled', 'return value * 2;'], ['_value']);
	}

	/**
	 * A typedef STRUCTURE field is a wire contract, never a binding in any lexical scope, so
	 * it must not veto a local / parameter rename to the same name. The local/param arm of
	 * `collidesInScope` subtracted only disjoint FUNCTION spans, so a module-level `{ x:Float }`
	 * silenced every `_x` in the file.
	 */
	public function testTypedefStructureFieldDoesNotBlockRename(): Void {
		final src: String = 'package pkg;\ntypedef Zoom = {\n\tx:Float,\n\ty:Float\n}\n\n'
			+ 'class C {\n\tpublic function f(_x:Float):Float {\n\t\treturn _x;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(2, edits(src).length);
	}

	/** An OBJECT-LITERAL field name is not a binding either — same rename, same reasoning. */
	public function testObjectLiteralFieldDoesNotBlockRename(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function f(_x:Float):Dynamic {\n\t\treturn { x: _x };\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(2, edits(src).length);
	}

	/**
	 * A binding declared SECOND in a multi-variable statement (`var a = 0, _b = 0;`) is a local
	 * like any other. `HxVarDecl.more` carried it as a `@:trivia` field, so the projection surfaced
	 * no declaration node for it and every declaration-walking rule was blind: no finding, no fix,
	 * and `Refs` could not resolve its uses back to a decl.
	 */
	public function testSecondBindingOfMultiVarFlagged(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function f():Void {\n\t\tvar dirX:Float = 0, _dirY:Float = 0;\n'
			+ '\t\ttrace(dirX + _dirY);\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'_dirY'"));
		assertFixed(src, ['var dirX:Float = 0, dirY:Float = 0;', 'trace(dirX + dirY);'], ['_dirY']);
	}

	/** The THIRD binding too — `more` is right-recursive, so a consumer must walk the whole chain. */
	public function testThirdBindingOfMultiVarFlagged(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function f():Void {\n\t\tvar a:Int = 0, b:Int = 1, _c:Int = 2;\n'
			+ '\t\ttrace(a + b + _c);\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'_c'"));
	}


	/**
	 * A local `function` statement is a binding scoped to one body, exactly like a `var`, so
	 * its `_` prefix carries nothing. This is the reported shape: a `function __finish()`
	 * declared inside a drawing method and called from it.
	 */
	public function testLocalFunctionFlaggedAndRenamed(): Void {
		final src: String = 'package pkg;\n'
			+ 'class C {\n\tpublic function draw():Void {\n\t\tfunction __finish():Void {\n\t\t\ttrace(1);\n\t\t}\n\t\t__finish();\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('no-underscore-prefix', vs[0].rule);
		Assert.isTrue(vs[0].message.contains("'__finish'"));
		assertFixed(src, ['function finish():Void', 'finish();'], ['__finish']);
	}

	/**
	 * A local function is visible from its declaration to the end of the block, so a recursive call
	 * inside its body and a call after it are both occurrences the rename must carry. Haxe does NOT
	 * hoist it - a call BEFORE the declaration is a different binding, covered by the next test.
	 */
	public function testLocalFunctionReferencedRecursivelyAndAfterDeclarationRenamed(): Void {
		final src: String = 'package pkg;\n' + 'class C {\n\tpublic function draw():Void {\n'
			+ '\t\tfunction __finish(n:Int):Void {\n\t\t\tif (n > 0) __finish(n - 1);\n\t\t}\n\t\t__finish(2);\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(3, edits(src).length);
		assertFixed(src, ['function finish(n:Int):Void', 'finish(2);'], ['__finish']);
	}

	/**
	 * The resolver binds a local function's name across its whole block, INCLUDING the region before
	 * the declaration; Haxe binds a read there to whatever the local function shadows - here the
	 * method `__finish`. Rewriting that read would emit a call to a name nothing declares, so an
	 * occurrence resolved before the declaration refuses the whole rename.
	 */
	public function testOccurrenceBeforeLocalFunctionDeclarationSkipped(): Void {
		final src: String = 'package pkg;\n' + 'class C {\n\tprivate function __finish():Void {\n\t\ttrace(1);\n\t}\n\n'
			+ '\tpublic function draw():Void {\n\t\t__finish();\n\t\tfunction __finish():Void {\n\t\t\ttrace(2);\n\t\t}\n'
			+ '\t\t__finish();\n\t}\n}';
		Assert.isTrue(violations(src).length >= 1);
		Assert.equals(0, edits(src).length);
	}

	/**
	 * An unprovable `inline function` candidate must not claim the target name: `_step` strips to
	 * `step` cleanly, and blocking it over a conflict with a binding that can never be renamed would
	 * be pure coverage loss.
	 */
	public function testUnprovableInlineFunctionDoesNotBlockSiblingStrip(): Void {
		final src: String = 'package pkg;\n' + 'class C {\n\tpublic function draw():Void {\n'
			+ '\t\tinline function __step():Void {\n\t\t\ttrace(1);\n\t\t}\n\t\tvar _step:Int = 1;\n\t\t__step();\n'
			+ '\t\ttrace(_step);\n\t}\n}';
		Assert.equals(2, violations(src).length);
		assertFixed(src, ['var step:Int = 1;', 'trace(step);', 'inline function __step():Void'], ['_step:Int']);
	}

	/** A local of the target name in the ENCLOSING body is in scope for the local function, so the strip is refused. */
	public function testLocalFunctionCollidingWithEnclosingLocalSkipped(): Void {
		final src: String = 'package pkg;\n' + 'class C {\n\tpublic function draw():Void {\n\t\tfinal finish:Int = 1;\n'
			+ '\t\tfunction __finish():Void {\n\t\t\ttrace(finish);\n\t\t}\n\t\t__finish();\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/**
	 * The scope a local function binds INTO is its enclosing body, never its own. A SIBLING local
	 * function already holding the target name is therefore a collision - reading the declaration's
	 * own span as its scope makes the sibling look disjoint and lets the strip put two `finish`
	 * bindings in one block. The sibling here is referenced ONLY from inside itself: every other
	 * shape leaves an occurrence of the target in the enclosing body, which the occurrence scan
	 * catches whatever it takes for the scope.
	 */
	public function testSiblingLocalFunctionHoldingTheTargetNameSkipped(): Void {
		final src: String = 'package pkg;\n' + 'class C {\n\tpublic function draw():Void {\n'
			+ '\t\tfunction finish(n:Int):Void {\n\t\t\tif (n > 0) finish(n - 1);\n\t\t}\n'
			+ '\t\tfunction __finish():Void {\n\t\t\ttrace(1);\n\t\t}\n\t\t__finish();\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/** Two sibling local functions differing only in underscore count strip to the SAME name, so neither renames. */
	public function testTwoLocalFunctionsStrippingToTheSameNameBothSkipped(): Void {
		final src: String = 'package pkg;\n' + 'class C {\n\tpublic function draw():Void {\n'
			+ '\t\tfunction _run():Void {\n\t\t\ttrace(1);\n\t\t}\n\t\tfunction __run():Void {\n\t\t\ttrace(2);\n\t\t}\n'
			+ '\t\t_run();\n\t\t__run();\n\t}\n}';
		Assert.equals(2, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/** A local function is a LOCAL binding, so `locals: false` takes it out of scope with the rest. */
	public function testLocalsOptionOffSkipsLocalFunctions(): Void {
		final src: String = 'package pkg;\n'
			+ 'class C {\n\tpublic function draw():Void {\n\t\tfunction __finish():Void {\n\t\t\ttrace(1);\n\t\t}\n\t\t__finish();\n\t}\n}';
		Assert.equals(0, violations(src, '{"rules":{"no-underscore-prefix":{"locals":false}}}').length);
	}

	/**
	 * A local `inline function` projects as `LocalInlineFnStmt`, a kind the reference walker
	 * does not index as a declaration host: no occurrence set is provable, so the gate fails
	 * CLOSED - the finding stands, the strip is not emitted.
	 */
	public function testLocalInlineFunctionFlaggedReportOnly(): Void {
		final src: String = 'package pkg;\n'
			+ 'class C {\n\tpublic function draw():Void {\n\t\tinline function __h():Void {\n\t\t\ttrace(1);\n\t\t}\n\t\t__h();\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

}
