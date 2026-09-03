package unit.grammar.haxe;

import anyparse.format.wrap.WrapMode;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;
import utest.Assert;
import utest.Test;

/**
 * ω-methodchain-emit — writer-time chain extractor + cascade-driven
 * emission for `HxExpr.Call(FieldAccess(Call(_,_),_),_)` /
 * `HxExpr.FieldAccess(Call(_,_),_)` chain shapes against the
 * `methodChainWrap` `WrapRules` cascade on `HxModuleWriteOptions`.
 *
 * The macro detects 2+ chain segments and routes through
 * `MethodChainEmit.emit`; one-segment expressions (single calls /
 * plain field access) fall through to the default emission.
 *
 * Tests cover the three writer-driven shape modes:
 *  - `NoWrap` keeps the chain inline regardless of segment length;
 *  - `OnePerLine` puts the receiver on its own line + every segment
 *    on its own indented line;
 *  - `OnePerLineAfterFirst` keeps `receiver + seg0` inline + remaining
 *    segments on their own indented lines.
 *
 * Single-call expressions (`a.b()`) and plain field access (`a.b`)
 * MUST stay inline regardless of cascade — chain dispatch only fires
 * for two-or-more-segment shapes.
 *
 * `HxFormatWrapRules` JSON loader currently drops the `rules` array
 * (per `feedback_peg_byname_array_unsupported.md`), so tests build
 * `WrapRules` directly via the runtime struct rather than through
 * `loadHxFormatJson`.
 */
@:nullSafety(Strict)
class HxMethodChainEmitTest extends Test {

	public function new(): Void {
		super();
	}

	public function testTwoSegmentChainNoWrapStaysInline(): Void {
		final src: String = 'class Foo { static function f() { a.b().c(); } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.methodChainWrap = { rules: [], defaultMode: WrapMode.NoWrap };
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a.b().c();') != -1, 'expected chain inline under NoWrap default: <$out>');
	}

	public function testThreeSegmentChainOnePerLineBreaksAll(): Void {
		final src: String = 'class Foo { static function f() { a.b().c().d(); } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.methodChainWrap = { rules: [], defaultMode: WrapMode.OnePerLine };
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		// OnePerLine shape: receiver inline, every segment on its own
		// indented line. Match a tab-indented `.b()` AFTER a newline.
		Assert.isTrue(out.indexOf('a\n') != -1, 'expected receiver alone on first line: <$out>');
		Assert.isTrue(
			out.indexOf('.b()') != -1 && out.indexOf('.c()') != -1 && out.indexOf('.d()') != -1,
			'expected all three segments emitted: <$out>'
		);
		Assert.isTrue(out.indexOf('\n\t\t\t.b()') != -1, 'expected .b() indented on own line: <$out>');
	}

	/**
	 * ω-methodchain-all-or-nothing: the SAME `OnePerLine` mode on a cascade that
	 * carries `chainItemsAfterCloseParenOnly` uses fork's `isDotAfterPClose`
	 * definition of a chain item — a `.` counts only after a `)`. `a.b()`'s dot
	 * follows the bare ident `a`, so `.b()` is not an item: it stays with the
	 * head while `.c()` and `.d()` break. The test above is the same input under
	 * the same mode WITHOUT the flag, and it breaks all three — the pair is what
	 * keeps the flag from being a no-op, and what keeps an explicitly configured
	 * `onePerLine` on the fork's literal semantics (five fork corpus fixtures
	 * depend on that).
	 */
	public function testPolicyCascadeKeepsANonChainItemGluedToTheHead(): Void {
		final src: String = 'class Foo { static function f() { a.b().c().d(); } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.methodChainWrap = { rules: [], defaultMode: WrapMode.OnePerLine, chainItemsAfterCloseParenOnly: true };
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		assertHeadGluedTailBroken(out);
	}

	/**
	 * F3 ω-methodchain-config-key — the same policy semantic reached through
	 * `hxformat.json` instead of a hand-built struct. `wrapping.methodChain`
	 * is rebuilt from scratch by `HaxeFormatConfigLoader.wrapRulesFromConfig`,
	 * so before this slice a configured cascade could not carry
	 * `chainItemsAfterCloseParenOnly` at all — a user section silently dropped
	 * the Haxe layout policy and stranded two-token heads (`Actuate` above
	 * `.tween(…)`, `API` above `.logs…`). `itemsAfterCloseParenOnly` is the
	 * opt-in that makes it reachable.
	 */
	public function testConfiguredCascadeOptsIntoTheCloseParenItemRule(): Void {
		final out: String = abcdChainUnderConfig(
			'{"wrapping":{"methodChain":{"defaultWrap":"onePerLine","itemsAfterCloseParenOnly":true,"rules":[]}}}'
		);
		assertHeadGluedTailBroken(out);
	}

	/**
	 * The default half of the pair: an `onePerLine` section that does NOT name
	 * the key keeps the fork's literal every-segment semantic. This is the
	 * fork-parity contract five corpus fixtures rest on, and the reason the key
	 * is opt-in rather than inherited from the built-in cascade.
	 */
	public function testConfiguredCascadeWithoutTheKeyKeepsForkLiteralItems(): Void {
		final out: String = abcdChainUnderConfig('{"wrapping":{"methodChain":{"defaultWrap":"onePerLine","rules":[]}}}');
		Assert.isTrue(out.indexOf('a\n') != -1, 'expected receiver alone on first line: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t.b()') != -1, 'expected .b() on own indented line: <$out>');
	}

	/**
	 * An explicit `false` is the same as absent — spelling it out must not
	 * accidentally re-enable the policy through some other seam.
	 */
	public function testConfiguredCascadeExplicitFalseKeepsForkLiteralItems(): Void {
		final out: String = abcdChainUnderConfig(
			'{"wrapping":{"methodChain":{"defaultWrap":"onePerLine","itemsAfterCloseParenOnly":false,"rules":[]}}}'
		);
		Assert.isTrue(out.indexOf('a\n') != -1, 'expected receiver alone on first line: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t.b()') != -1, 'expected .b() on own indented line: <$out>');
	}

	public function testThreeSegmentChainOnePerLineAfterFirstKeepsFirstInline(): Void {
		final src: String = 'class Foo { static function f() { a.b().c().d(); } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.methodChainWrap = { rules: [], defaultMode: WrapMode.OnePerLineAfterFirst };
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a.b()') != -1, 'expected receiver+seg0 inline: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t.c()') != -1, 'expected .c() on own indented line: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t.d()') != -1, 'expected .d() on own indented line: <$out>');
	}

	public function testFieldOnlySegmentEndsChain(): Void {
		// Mixed chain: `a.b().c` ends with field-only segment.
		// Two segments: `.b()` (call) + `.c` (field). Under OnePerLine
		// both should break.
		final src: String = 'class Foo { static function f() { a.b().c; } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.methodChainWrap = { rules: [], defaultMode: WrapMode.OnePerLine };
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('\n\t\t\t.b()') != -1, 'expected .b() on own indented line: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t.c;') != -1, 'expected .c (field-only) on own indented line: <$out>');
	}

	public function testSingleCallStaysInlineRegardlessOfMode(): Void {
		// `a.b()` is a single chain segment — chain dispatch's `>= 2`
		// guard keeps this on the default emission path. Must stay
		// inline even with an aggressive default mode.
		final src: String = 'class Foo { static function f() { a.b(); } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.methodChainWrap = { rules: [], defaultMode: WrapMode.OnePerLine };
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a.b();') != -1, 'expected single call inline: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t.b()') == -1, 'single call must NOT break: <$out>');
	}

	public function testPlainFieldAccessStaysInlineRegardlessOfMode(): Void {
		// `a.b` is plain field access — neither chain segment
		// transition (Call→FieldAccess→Call) nor a Call wrapping a
		// chain. Stays inline.
		final src: String = 'class Foo { static var x = a.b; }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.methodChainWrap = { rules: [], defaultMode: WrapMode.OnePerLine };
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a.b;') != -1, 'expected plain field access inline: <$out>');
	}

	public function testChainSegmentSingleArgMultilineLambdaNoExtraIndent(): Void {
		// ω-fillline-single-noncascade regression: chain segment whose
		// lone arg is a multi-line anon function with `leftCurly=Next`
		// (Allman). The single hardline-bearing arg used to route
		// through `WrapList.shapeFillLine`'s continuation `Nest(cols,
		// …)`, drifting the lambda's `\n{` and body lines one tab too
		// deep relative to the segment column. Fix short-circuits the
		// single-item FillLine shape to drop the Nest, mirroring fork's
		// inline `(<item>)` emission.
		final src: String = 'class M { function f() { a.b().c(function(x) { stmt; }); } }';
		final cfg: String = '{
			"lineEnds":{"leftCurly":"both"},
			"wrapping":{"methodChain":{"rules":[
				{"conditions":[{"cond":"itemCount >= n","value":2}],"type":"onePerLine"}
			]}}
		}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		// Function body at 2 tabs; chain Nest pushes segs to 3 tabs;
		// lambda's `\n{` lands at 3 tabs (chain seg column), body at 4.
		Assert.isTrue(
			out.indexOf('\n\t\t\t.c(function(x)\n\t\t\t{\n\t\t\t\tstmt;\n\t\t\t});') != -1,
			'expected lambda `{` at chain seg column, body one tab deeper: <$out>'
		);
	}

	/**
	 * F3 ω-methodchain-config-key — the three config-path tests above differ only
	 * in the `wrapping.methodChain` JSON they load, so the chain under test and the
	 * writer call live here. `a.b().c().d()`: the head `a` is not a call, so under
	 * the close-paren item rule `.b()` is not a chain item and stays glued to it.
	 */
	private static function abcdChainUnderConfig(cfg: String): String {
		final src: String = 'class Foo { static function f() { a.b().c().d(); } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}


	/**
	 * The close-paren item rule's whole observable effect on `a.b().c().d()` under a
	 * break mode: the head keeps `.b()` (its dot follows the ident `a`, not a `)`),
	 * and the two real chain items each take a line. Asserted identically by the
	 * struct-driven test and by the config-driven one, which is the point — the key
	 * must reach exactly the semantic the built-in cascade already had.
	 */
	private static function assertHeadGluedTailBroken(out: String): Void {
		Assert.isTrue(out.indexOf('a.b()') != -1, 'expected the non-chain-item `.b()` glued to the head: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t.c()') != -1, 'expected .c() on own indented line: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t.d()') != -1, 'expected .d() on own indented line: <$out>');
	}

}
