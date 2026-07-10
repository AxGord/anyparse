package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-call-grouprestprobe-casepattern: a statement/expression-position
 * `Call` wraps its args when the physical line is exactly `maxLineLength + 1`
 * (141 at the 140 limit) -- counting the trailing `;`/rest-of-line, matching
 * the fork. The `Call` ctor carries `@:fmt(groupRestProbe)` so the
 * cascade-disagree `emitZeroThreshold` routes through `GroupWithRestProbe`,
 * subtracting `flatTokenWidthOfRestStack` at the fit. A line exactly ON the
 * limit (140) stays glued (strict boundary at limit+1).
 *
 * The rest-probe is gated OFF in a sub-position (`opt._suppressCallRestProbe`)
 * via two set-sites:
 *  - Case patterns (`HxCasePattern.expr`'s `@:fmt(suppressCallRestProbe)`): a
 *    ctor pattern (`Nest(_, _)` in `case Nest(_, _) | Concat(_) | ...:`) must
 *    NOT wrap its own args -- the fork breaks the `|` (BitOr) chain instead.
 *    Without the guard, every ctor over-wraps (`case Nest(\n\t_, _\n) | ...`),
 *    a real regression visible in anyparse's own `Renderer.hx` self-drift that
 *    the corpus sweep does not catch.
 *  - `??` (Coalesce) operands (`lowerInfixBranch`): `??` is right-assoc, so its
 *    outer-left operand carries the whole rest-chain; the rest-probe would
 *    over-count and wrap operand args the fork keeps glued (the fork packs the
 *    chain left-to-right). The guard reverts `??` operands to pristine
 *    plain-Group wrapping.
 */
@:nullSafety(Strict)
final class HxCallGroupRestProbeCasePatternTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}, "casePattern": {"defaultWrap": "fillLine", "rules": [{"conditions": [{"cond": "itemCount <= n", "value": 2}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	public function testStatementCallAtLimitPlusOneWraps(): Void {
		// The drawRect line at 3-tab indent (tab=4) is exactly 141 columns --
		// the close `)` sits at 140 and the `;` at 141. The rest-probe counts
		// the `;`, so the call opens its args (fork parity).
		final glued: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tcolorSprite.graphics.drawRect(1 * scaleFactor, 1 * scaleFactor, (CELL_WIDTH - 2) * scaleFactor, (CELL_HEIGHT - 2) * scaleFactor);\n\t\t}\n\t}\n}';
		final wrapped: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tcolorSprite.graphics.drawRect(\n\t\t\t\t1 * scaleFactor, 1 * scaleFactor, (CELL_WIDTH - 2) * scaleFactor, (CELL_HEIGHT - 2) * scaleFactor\n\t\t\t);\n\t\t}\n\t}\n}';
		Assert.equals(wrapped, triviaWrite(glued));
		Assert.equals(wrapped, triviaWrite(wrapped));
	}

	public function testStatementCallExactlyOnLimitStaysGlued(): Void {
		// One char shorter callee (`drawRec`) puts the `;` at exactly 140 --
		// the strict limit+1 boundary keeps the whole call flat.
		final src: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tcolorSprite.graphics.drawRec(1 * scaleFactor, 1 * scaleFactor, (CELL_WIDTH - 2) * scaleFactor, (CELL_HEIGHT - 2) * scaleFactor);\n\t\t}\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testCasePatternCtorStaysGlued(): Void {
		// The crux: a multi-arg ctor pattern `Nest(_, _)` inside an overflowing
		// `|` chain must stay GLUED (not `Nest(\n\t_, _\n)`). The
		// `_suppressCallRestProbe` guard turns the ctor's rest-probe off, so it
		// renders byte-identically to pristine anyparse -- every fitting ctor
		// glued, only the boundary ctor's arg dropping to its own line (a
		// pre-existing anyparse-vs-fork gap the
		// guard neither introduces nor worsens).
		final src: String = 'class C {\n\tfunction f() {\n\t\tswitch (x) {\n\t\t\tcase Nest(_, _) | Concat(_) | Group(_) | BodyGroup(_) | GroupProbe(_) | Flatten(_) | WrapBoundary(_) | HardFlatten(_) | CollapseProbe(\n\t\t\t\t_\n\t\t\t):\n\t\t\t\tg();\n\t\t}\n\t}\n}';
		final out: String = triviaWrite(src);
		Assert.equals(src, out);
		// Explicit glued invariant: the leading multi-arg ctor never splits.
		Assert.isTrue(out.indexOf('Nest(_, _)') >= 0);
		Assert.isTrue(out.indexOf('Nest(\n') < 0);
	}

	public function testCoalesceOperandDoesNotOverWrap(): Void {
		// A `??` (Coalesce, right-assoc) chain of calls: the leading operands must
		// stay GLUED, not each wrap its own args. groupRestProbe on the operand
		// calls would over-count (the outer-left operand's rest-stack is the whole
		// chain), wrapping args the fork keeps glued; `_suppressCallRestProbe`
		// reverts `??` operands to pristine plain-Group (wrap-on-own-overflow), so
		// only the operand that itself overflows (`returnCallSource`) opens.
		final src: String = 'class C {\n\tfunction f() {\n\t\treturn mapIndexSource(receiver, root, declaredTypes, cfg) ?? instanceCallSource(receiver, root, declaredTypes, cfg) ?? returnCallSource(receiver, root, returnTypes, cfg) ?? crossFileReturnCallSource(receiver, root, declaredTypes, cfg, index);\n\t}\n}';
		final wrapped: String = 'class C {\n\tfunction f() {\n\t\treturn\n\t\t\tmapIndexSource(receiver, root, declaredTypes, cfg) ?? instanceCallSource(receiver, root, declaredTypes, cfg) ?? returnCallSource(\n\t\t\t\treceiver, root, returnTypes, cfg\n\t\t\t) ?? crossFileReturnCallSource(receiver, root, declaredTypes, cfg, index);\n\t}\n}';
		final out: String = triviaWrite(src);
		Assert.equals(wrapped, out);
		Assert.equals(wrapped, triviaWrite(wrapped));
		// Leading `??` operands stay glued -- NOT split as `mapIndexSource(\n` etc.
		Assert.isTrue(out.indexOf('mapIndexSource(receiver, root, declaredTypes, cfg) ??') >= 0);
		Assert.isTrue(out.indexOf('?? instanceCallSource(receiver, root, declaredTypes, cfg) ??') >= 0);
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
