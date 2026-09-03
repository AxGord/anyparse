package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

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
 *    chain left-to-right). The guard reverts `??` operands to pristine plain-Group wrapping.
 *
 * ω-pattern-rest-probe adds the third set-site and the WIDER flag it needed.
 * `_suppressCallRestProbe` reaches the pattern's own ctor and nothing else: a
 * collection literal in the pattern carries an UNGATED `@:fmt(groupRestProbe)`
 * of its own, and its element arm CLEARS the call flag for the field values, so
 * `case FVar(t, { expr: ENew(tp, _) }) if (<long guard>):` broke the 21-column
 * PATTERN to make room for a 121-column guard that wraps perfectly well on its
 * own. `@:fmt(suppressPatternRestProbe)` on the same field turns the probe off
 * for the whole pattern subtree; `_suppressComplexItems` could not be reused,
 * because a switch SUBJECT sets it too and a subject must keep wrapping.
 *
 * T170: at THIS set-site the CALL flag is now fully subsumed. The `Call` gate
 * reads both flags, so dropping `suppressCallRestProbe` from `HxCasePattern.expr`
 * leaves this whole class, the rest of the suite AND the 946-fixture corpus
 * unchanged. The FLAG stays load-bearing: three hardcoded lowering set-sites never read the
 * meta at all (nested call arg, chain operand incl. `??`, and the collection
 * element arm that CLEARS it). But this is the ONLY `suppressCallRestProbe`
 * occurrence in the whole grammar, and at this set-site it is provably
 * redundant rather than merely unobserved — the gate is `!A && !B` and B is set
 * over the same subtree and never cleared, so M1 was green a priori, not by
 * discovery. Removing it is a grammar edit this slice does not own.
 */
@:nullSafety(Strict)
final class HxCallGroupRestProbeCasePatternTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "callParameter": {'
		+ '"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": ['
		+ '{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": ['
		+ '{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], '
		+ '"type": "noWrap"}]}, "casePattern": {"defaultWrap": "fillLine", "rules": [{"conditions": ['
		+ '{"cond": "itemCount <= n", "value": 2}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": '
		+ '"noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';

	/**
	 * ω-pattern-rest-probe: the same `callParameter` cascade beside Pony's own
	 * `objectLiteral` / `conditionWrapping` / `opBoolChain` ones — the config
	 * behind the `case FVar(t, { … }) if (…):` repro. Every one of the three
	 * resolves its break at RENDER time, which is what makes the pattern and
	 * the guard compete for the same overlong line.
	 */
	private static final PATTERN_GUARD_CONFIG: String = '{"wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": '
		+ '"ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "onePerLine"}]}, '
		+ '"arrayWrap": {"defaultWrap": "ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], '
		+ '"type": "onePerLine"}]}, ' + '"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": '
		+ '"exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, '
		+ '{"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}, "casePattern": {"defaultWrap": "noWrap", '
		+ '"rules": [{"conditions": [{"cond": "itemCount >= n", "value": 2}], "type": "fillLine"}, {"conditions": [{"cond": '
		+ '"exceedsMaxLineLength", "value": 1}], "type": "fillLine"}]}, "conditionWrapping": {"defaultWrap": '
		+ '"fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": '
		+ '"noWrap"}]}, "opBoolChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "itemCount <= n", '
		+ '"value": 3}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": '
		+ '"totalItemLength <= n", "value": 120}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}}}';

	/**
	 * ω-pattern-rest-probe / T170: the ONE shape in this class where the wider
	 * flag is the only thing holding the line. The object literal's element arm
	 * CLEARS `_suppressCallRestProbe` for a field value, so the ctor below it
	 * cannot be reached by the call flag at all — only
	 * `_suppressPatternRestProbe` survives the descent. Every construct that
	 * could absorb the overflow instead is pinned to `noWrap`, so the ctor is the
	 * only breakable thing on a 67-column line and the assertion cannot be
	 * satisfied by something else wrapping.
	 */
	private static final COLLECTION_PATTERN_CONFIG: String = '{"wrapping": {"maxLineLength": 60, "callParameter": '
		+ '{"defaultWrap": "ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": '
		+ '"onePerLine"}]}, "objectLiteral": {"defaultWrap": "noWrap", "rules": []}, "casePattern": {"defaultWrap": '
		+ '"noWrap", "rules": []}, "conditionWrapping": {"defaultWrap": "noWrap", "rules": []}, "opBoolChain": '
		+ '{"defaultWrap": "noWrap", "rules": []}}}';

	public function new(): Void {
		super();
	}

	public function testStatementCallAtLimitPlusOneWraps(): Void {
		// The drawRect line at 3-tab indent (tab=4) is exactly 141 columns --
		// the close `)` sits at 140 and the `;` at 141. The rest-probe counts
		// the `;`, so the call opens its args (fork parity).
		final glued: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tcolorSprite.graphics.drawRect(1 * scaleFactor, 1 * '
			+ 'scaleFactor, (CELL_WIDTH - 2) * scaleFactor, (CELL_HEIGHT - 2) * scaleFactor);\n\t\t}\n\t}\n}';
		final wrapped: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tcolorSprite.graphics.drawRect(\n\t\t\t\t1 * scaleFactor, '
			+ '1 * scaleFactor, (CELL_WIDTH - 2) * scaleFactor, (CELL_HEIGHT - 2) * scaleFactor\n\t\t\t);\n\t\t}\n\t}\n}';
		Assert.equals(wrapped, triviaWrite(glued));
		Assert.equals(wrapped, triviaWrite(wrapped));
	}

	public function testStatementCallExactlyOnLimitStaysGlued(): Void {
		// One char shorter callee (`drawRec`) puts the `;` at exactly 140 --
		// the strict limit+1 boundary keeps the whole call flat.
		final src: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tcolorSprite.graphics.drawRec(1 * scaleFactor, 1 * '
			+ 'scaleFactor, (CELL_WIDTH - 2) * scaleFactor, (CELL_HEIGHT - 2) * scaleFactor);\n\t\t}\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * A multi-arg ctor pattern `Nest(_, _)` inside an overflowing `|` chain must
	 * stay GLUED (not `Nest(\n\t_, _\n)`) — the fork breaks the `|` chain, not the
	 * ctor args. It renders byte-identically to pristine anyparse: every fitting
	 * ctor glued, only the boundary ctor's arg dropping to its own line (a
	 * pre-existing anyparse-vs-fork gap this pins as neither introduced nor
	 * worsened).
	 *
	 * ⚠️ T170 — what this method does NOT do any more is ATTRIBUTE that to
	 * `@:fmt(suppressCallRestProbe)`, which is what its previous comment claimed.
	 * `HxCasePattern.expr` carries BOTH suppress flags and the `Call` gate reads
	 * `!opt._suppressCallRestProbe && !opt._suppressPatternRestProbe`, so either
	 * one alone keeps this ctor glued. Measured, three mutation arms on that one
	 * `@:fmt`: drop `suppressCallRestProbe` → this method OK (and the whole suite
	 * AND the 946-fixture corpus unchanged — the case-pattern set-site of the call
	 * flag is unobservable); drop `suppressPatternRestProbe` → OK; drop BOTH →
	 * 3 assertion failures. It pins the invariant and neither flag.
	 * `testCasePatternCtorInsideACollectionStaysGlued` is the arm that DOES
	 * discriminate the wider flag; `testCoalesceOperandDoesNotOverWrap` and the
	 * sibling chain-operand / nested-arg classes are where
	 * `suppressCallRestProbe` is still the only thing holding a line.
	 */
	public function testCasePatternCtorStaysGlued(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tswitch (x) {\n'
			+ '\t\t\tcase Nest(_, _) | Concat(_) | Group(_) | BodyGroup(_) | GroupProbe(_) | Flatten(_) | WrapBoundary(_) '
			+ '| HardFlatten(_) | CollapseProbe(\n\t\t\t\t_\n\t\t\t):\n\t\t\t\tg();\n\t\t}\n\t}\n}';
		final out: String = triviaWrite(src);
		Assert.equals(src, out);
		// Explicit glued invariant: the leading multi-arg ctor never splits.
		Assert.isTrue(out.indexOf('Nest(_, _)') >= 0);
		Assert.isTrue(out.indexOf('Nest(\n') < 0);
	}

	/**
	 * T170's discriminating control for the SUBSUMING flag, at the one position
	 * inside a case pattern the call flag provably cannot reach: a ctor in an
	 * object-literal FIELD VALUE, whose element arm sets
	 * `_suppressCallRestProbe = false` so a nested call in a real value still
	 * wraps. At tab = 4 the ctor closes at column 51 and the whole pattern at 53,
	 * both well inside the 60 limit; only the trailing `) if (isReady):` takes the
	 * line to 67. So `Wrap(` and `Ctor(` are the only two movable things on it and
	 * a rest probe is the only thing that could move either — with different flags
	 * holding each: `Wrap(` on the call flag, `Ctor(` on nothing but
	 * `_suppressPatternRestProbe`, since the literal cleared the call flag above it.
	 *
	 * Killed by the arm that drops `suppressPatternRestProbe` from
	 * `HxCasePattern.expr` (`case Wrap({key: Ctor(\n\t\t\t\talphaArg,\n…`, while
	 * the outer `Wrap(` stays glued on the call flag); green under the arm that
	 * drops `suppressCallRestProbe`, which is what makes it a discriminator
	 * rather than a second copy of `testCasePatternCtorStaysGlued`.
	 */
	public function testCasePatternCtorInsideACollectionStaysGlued(): Void {
		final src: String = 'class C {\n\tstatic function f():Void {\n\t\tswitch v {\n\t\t\tcase Wrap({key: Ctor(alphaArg, '
			+ 'betaArg)}) if (isReady):\n\t\t\t\tg();\n\t\t}\n\t}\n}';
		final out: String = HxWriteFixture.triviaWrite(src, COLLECTION_PATTERN_CONFIG);
		Assert.equals(src, out);
		// Diagnostic, not a second check: the equality above already implies it.
		// It exists so a failure names the construct instead of dumping two files.
		Assert.isTrue(out.indexOf('Ctor(\n') < 0, 'the ctor below the literal must not rest-probe, got:\n<$out>');
	}

	public function testCoalesceOperandDoesNotOverWrap(): Void {
		// A `??` (Coalesce, right-assoc) chain of calls: the leading operands must
		// stay GLUED, not each wrap its own args. groupRestProbe on the operand
		// calls would over-count (the outer-left operand's rest-stack is the whole
		// chain), wrapping args the fork keeps glued; `_suppressCallRestProbe`
		// reverts `??` operands to pristine plain-Group (wrap-on-own-overflow), so
		// only the operand that itself overflows (`returnCallSource`) opens.
		final src: String = 'class C {\n\tfunction f() {\n\t\treturn mapIndexSource(receiver, root, declaredTypes, cfg) '
			+ '?? instanceCallSource(receiver, root, declaredTypes, cfg) ?? returnCallSource(receiver, root, returnTypes, cfg) '
			+ '?? crossFileReturnCallSource(receiver, root, declaredTypes, cfg, index);\n\t}\n}';
		final wrapped: String = 'class C {\n\tfunction f() {\n\t\treturn\n\t\t\tmapIndexSource(receiver, root, declaredTypes, cfg) '
			+ '?? instanceCallSource(receiver, root, declaredTypes, cfg) ?? returnCallSource(\n\t\t\t\treceiver, root, returnTypes, cfg\n'
			+ '\t\t\t) ?? crossFileReturnCallSource(receiver, root, declaredTypes, cfg, index);\n\t}\n}';
		final out: String = triviaWrite(src);
		Assert.equals(wrapped, out);
		Assert.equals(wrapped, triviaWrite(wrapped));
		// Leading `??` operands stay glued -- NOT split as `mapIndexSource(\n` etc.
		Assert.isTrue(out.indexOf('mapIndexSource(receiver, root, declaredTypes, cfg) ??') >= 0);
		Assert.isTrue(out.indexOf('?? instanceCallSource(receiver, root, declaredTypes, cfg) ??') >= 0);
	}

	/**
	 * ω-pattern-rest-probe: BOTH constructs on this line can break, and the
	 * guard owns 121 of its 170 columns while the object pattern owns 21 — yet
	 * the writer broke the pattern. `_suppressCallRestProbe` had already turned
	 * the rest-probe off for the pattern's own ctor, but the object literal
	 * carries an UNGATED `@:fmt(groupRestProbe)` of its own, and the literal's
	 * element arm CLEARS the call flag, so `ENew(` got one back too: the
	 * pattern was charged the guard's whole flat width and broke to make room
	 * for it. A pattern is a matching shape, not a value — it never owns the
	 * overflow — so the whole pattern subtree now declines the rest probe and
	 * the guard wraps into `if (` / cond / `):` instead.
	 *
	 * THREE independent assertions, because the first fix attempt satisfied one
	 * of them and not the others: suppressing only the object literal's own
	 * rest probe kept the literal flat and moved the break into
	 * `ENew(\n\ttp, _\n)`, leaving the guard unwrapped. So the pattern text, the
	 * absence of a break inside the ctor, and the guard's own wrap are each
	 * asserted on their own rather than folded into one anchor.
	 */
	public function testCasePatternStaysFlatAndTheGuardWraps(): Void {
		final src: String = 'class C {\n\tstatic function g(): Void {\n\t\tswitch field.kind {\n\t\t\tcase FVar(t, { expr: '
			+ 'ENew(tp, _) }) if (t != null && field.meta.getMeta(OWN) != null && field.meta.getMeta(SHARE) == null && '
			+ 'field.meta.getMeta(USE) == null):\n\t\t\t\tg();\n\t\t\tcase _:\n\t\t}\n\t}\n}';
		final out: String = write(src);
		Assert.isTrue(out.indexOf('case FVar(t, {expr: ENew(tp, _)})') >= 0, 'expected the whole pattern on one line, got:\n<$out>');
		Assert.isTrue(out.indexOf('ENew(\n') < 0, 'the break must not sink into the ctor pattern either, got:\n<$out>');
		Assert.isTrue(out.indexOf(' if (\n\t\t\t\tt != null &&') >= 0, 'expected the guard to be the construct that wrapped, got:\n<$out>');
		Assert.equals(out, write(out), 'one round trip must land on the fixed point');
	}

	/**
	 * The same mechanism one collection kind over: an ARRAY literal inside a
	 * pattern carries the same ungated `@:fmt(groupRestProbe)` the object
	 * literal does, so it broke for the guard too. Covers the widening — the
	 * flag turns the probe off for EVERY construct below the pattern, not for
	 * the one shape the repro happened to use.
	 */
	public function testArrayPatternStaysFlatAndTheGuardWraps(): Void {
		final src: String = 'class C {\n\tstatic function g(): Void {\n\t\tswitch field.kind {\n\t\t\tcase Compound([alphaOption, '
			+ 'betaOption]) if (t != null && field.meta.getMeta(OWN) != null && field.meta.getMeta(SHARE) == null && '
			+ 'field.meta.getMeta(USE) == null):\n\t\t\t\tg();\n\t\t\tcase _:\n\t\t}\n\t}\n}';
		final out: String = write(src);
		Assert.isTrue(out.indexOf('case Compound([alphaOption, betaOption]) if (\n') >= 0, 'expected the pattern flat, got:\n<$out>');
		Assert.equals(out, write(out), 'one round trip must land on the fixed point');
	}

	/**
	 * The set-site boundary — green BEFORE the slice as well as after, on
	 * purpose: reverting `_suppressPatternRestProbe` cannot fail it, so it is a
	 * guard against a rejected DESIGN rather than coverage of the landed one.
	 * `@:fmt(suppressComplexItems)` sits on the switch SUBJECT as well as on the
	 * case pattern, so reusing it for the rest probe is the cheap-looking move —
	 * and it is wrong: a subject is a real expression whose call must still wrap
	 * at `maxLineLength + 1`. Measured on that shortcut, this header stayed flat
	 * at 141 columns, the one invariant the whole Pony sweep had held at zero.
	 */
	public function testSwitchSubjectKeepsItsRestProbe(): Void {
		final src: String = 'class C {\n\tstatic function g(): Void {\n\t\tswitch ExtractSuperclass.extract(\'pkg/Unpack.hx\', '
			+ '\'Unpack\', \'BaseUnpack\', \'pkg/BaseUnpack.hx\', [\'readNode\'], src, plugin(), config) {\n'
			+ '\t\t\tcase Ok(changes, advisory):\n\t\t\t\tg();\n\t\t\tcase _:\n\t\t}\n\t}\n}';
		final out: String = write(src);
		Assert.isTrue(out.indexOf('switch ExtractSuperclass.extract(\n') >= 0, 'expected the subject call to open its paren, got:\n<$out>');
		Assert.equals(out, write(out), 'one round trip must land on the fixed point');
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

	/** ω-pattern-rest-probe sister of `triviaWrite`, under `PATTERN_GUARD_CONFIG`. */
	private inline function write(src: String): String {
		return HxWriteFixture.triviaWrite(src, PATTERN_GUARD_CONFIG);
	}

}
