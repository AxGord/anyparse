package unit;

import utest.Assert;
import utest.Test;

/**
 * omega-ternary-cuddled-braces: `wrapping.ternaryCuddledBraces` (default
 * `false`) lets a broken ternary's `:` and its ELSE branch's opening delimiter
 * ride on the THEN branch's own closing line — `cond\n\t? {\n\t\t…\n\t} : {`
 * — instead of opening a continuation line that would hold nothing but `: {`.
 * The `?` gap is untouched: the branch that gains a line by breaking keeps its
 * break, and only the gap that would buy a line holding nothing closes up.
 *
 * Two admission legs, both in `BinaryChainEmit.ternaryBracesCuddle`. The
 * STRUCTURAL one reads the then branch's committed tail
 * (`DocMeasure.breakTailCloseNest` — a forced closing line whose leftmost
 * closer is a brace, landing at the indent of the line the branch started on)
 * and cuddles unconditionally. The PIVOT one resolves a branch whose break the
 * RENDERER decides and must therefore gate its shape on the branch NOT fitting
 * its own continuation line, since a branch that fits stays flat and has no
 * closing line to ride. Both legs decline a flat then branch and a
 * non-collection else operand, which is what keeps a ternary whose branches
 * both fit from being rebuilt onto one line.
 *
 * A THIRD gate, `BinaryChainEmit.cuddleShape`, answers about the ELSE branch,
 * because gluing does not move it — it SHIFTS it right by the then branch's
 * whole closing-line CLOSER RUN and the space after it: two columns for a bare
 * `}`, four for a `}))`. An else that fits its own separator line can overflow
 * the line it rides once glued, and the renderer then breaks a branch that was
 * a single line. Two width probes bracket that band, and only inside it does
 * the separator line survive.
 */
@:nullSafety(Strict)
final class HxTernaryCuddledBracesTest extends Test {

	/** The knob, as a `wrapping` fragment. Every ON config below carries it; every OFF config omits it. */
	private static final KNOB: String = '"ternaryCuddledBraces": true, ';

	/**
	 * An object-literal cascade whose break is COMMITTED at build time: a breaking default with a narrow `noWrap` rule. This is the
	 * structural leg's cascade, and Pony's own committed `hxformat.json` shape.
	 */
	private static final OBJECT_COMMITTED: String = '"objectLiteral": {"defaultWrap": "onePerLine", "rules": [{"conditions":'
		+ ' [{"cond": "totalItemLength <= n", "value": 60}], "type": "noWrap"}]}, ';

	/**
	 * An object-literal cascade whose break is deferred to the RENDERER: an `ignore` default plus a single `exceedsMaxLineLength` rule.
	 * This is the probe leg's cascade, and the shape Pony's in-flight config carries.
	 */
	private static final OBJECT_RENDER_PIVOT: String = '"objectLiteral": {"defaultWrap": "ignore", "rules": [{"conditions":'
		+ ' [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "onePerLine"}]}, ';

	/**
	 * A committed cascade whose `noWrap` threshold is wide enough to leave an else branch of ~120 columns flat while the then branch
	 * still breaks. That combination is what makes the closer-run band reachable at this config's 140-column limit at all: under the
	 * narrow `OBJECT_COMMITTED` an else that wide breaks unconditionally, so both arms would agree and the fixture would prove nothing.
	 */
	private static final OBJECT_COMMITTED_WIDE: String = '"objectLiteral": {"defaultWrap": "onePerLine", "rules": [{"conditions":'
		+ ' [{"cond": "totalItemLength <= n", "value": 120}], "type": "noWrap"}]}, ';

	/** A ternary cascade forced to `onePerLine` (the condition breaks onto its own line too), replacing the stock rules. */
	private static final TERNARY_ONE_PER_LINE: String =
		'"ternaryExpression": {"defaultWrap": "onePerLine", "defaultLocation": "beforeLast", "rules": []}, ';

	/** Committed-break cascade, knob on. */
	private static final COMMITTED_ON: String = config(KNOB + OBJECT_COMMITTED);

	/** Committed-break cascade, knob absent — the inertness arm. */
	private static final COMMITTED_OFF: String = config(OBJECT_COMMITTED);

	/** Render-pivot cascade, knob on. */
	private static final PIVOT_ON: String = config(KNOB + OBJECT_RENDER_PIVOT);

	/** Render-pivot cascade, knob absent. */
	private static final PIVOT_OFF: String = config(OBJECT_RENDER_PIVOT);

	/**
	 * A `whitespace` fragment that pads a call's closing paren (`} )` instead of `})`), so the then branch's closing-line closer run
	 * carries an interior space the closer characters alone do not count.
	 */
	private static final PADDED_CALL_PARENS: String =
		'"parenConfig": {"callParens": {"openingPolicy": "onlyAfter", "closingPolicy": "before"}}, ';

	/** Wide committed-break cascade, knob on. */
	private static final COMMITTED_WIDE_ON: String = config(KNOB + OBJECT_COMMITTED_WIDE);

	/** The same with the knob absent. */
	private static final COMMITTED_WIDE_OFF: String = config(OBJECT_COMMITTED_WIDE);

	/** The wide committed cascade plus the padded call parens, knob on. */
	private static final PADDED_ON: String = config(KNOB + OBJECT_COMMITTED_WIDE, PADDED_CALL_PARENS);

	/** The same with the knob absent. */
	private static final PADDED_OFF: String = config(OBJECT_COMMITTED_WIDE, PADDED_CALL_PARENS);

	/** Committed-break cascade plus a `onePerLine` ternary cascade, knob on. */
	private static final ONE_PER_LINE_ON: String = config(KNOB + OBJECT_COMMITTED + TERNARY_ONE_PER_LINE);

	/** The same with the knob absent. */
	private static final ONE_PER_LINE_OFF: String = config(OBJECT_COMMITTED + TERNARY_ONE_PER_LINE);

	/**
	 * Both ternary branches are object literals wide enough that the whole statement overflows and the branches themselves break. The
	 * shape the user asked about, minimised.
	 */
	private static final SRC_OBJECTS: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag ? { alphaFieldNameThatIsQuiteL'
		+ 'ong: 1234567, betaFieldNameThatIsQuiteLong: 2345678, gammaFieldNameThatIsLong: 34 } : { alphaFieldNameThatIsQuit'
		+ 'eLong: 9876543, betaFieldNameThatIsQuiteLong: 8765432, gammaFieldNameThatIsLong: 76 };\n\t}\n}';

	/**
	 * The same shape one field wider, so each branch also overflows the CONTINUATION line it lands on. That is what makes a
	 * render-time-pivot cascade break the branches at all, and it is the only input the probe leg can cuddle.
	 */
	private static final SRC_OBJECTS_WIDE: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag ? { alphaFieldNameThatIsQ'
		+ 'uiteLong: 1234567, betaFieldNameThatIsQuiteLong: 2345678, gammaFieldNameThatIsQuiteLong: 3456789, deltaFieldName'
		+ 'ThatIsLong: 4 } : { alphaFieldNameThatIsQuiteLong: 9876543, betaFieldNameThatIsQuiteLong: 8765432, gammaFieldNam'
		+ 'eThatIsQuiteLong: 7654321, deltaFieldNameThatIsLong: 5 };\n\t}\n}';

	/**
	 * A ternary that breaks while BOTH branches stay flat, nested deep enough to overflow. Pony `Classes.hx` / `ExtendedTextInput.hx`
	 * reduced: there is no closing line to ride, so cuddling here would rebuild the whole ternary on one line.
	 */
	private static final SRC_FLAT_BRANCHES: String = 'class T {\n\tprivate function f():Void {\n\t\tfor (e in items) {\n\t\t\tfor (s in par'
		+ 'ts) {\n\t\t\t\tex = ex == null ? { expr: EConst(CIdent(s)), pos: Context.currentPos() } : { expr: EField(ex, s),'
		+ ' pos: Context.currentPos() };\n\t\t\t}\n\t\t}\n\t}\n}';

	/**
	 * A broken then branch whose ELSE operand is a block-bodied ARROW, not a delimited body — the operand class the gate declines. The
	 * else must ALSO break, or the pre-existing `ternaryHugCollectionBranchIndex` hug (exactly one multi-line branch) answers first
	 * and this fixture proves nothing about the conjunct it is here for.
	 */
	private static final SRC_NON_COLLECTION_ELSE: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag ? { alphaFieldName'
		+ 'ThatIsQuiteLong: 1234567, betaFieldNameThatIsQuiteLong: 2345678, gammaFieldNameThatIsLong: 34 } : (payloadValue)'
		+ ' -> { handleFallbackPayload(payloadValue); reportFallbackTaken(payloadValue); };\n\t}\n}';

	/**
	 * A ternary carrying a trailing LINE comment on the then operand. The captured
	 * comment forces the source-faithful `Keep` shape, which this slice does not
	 * touch — and must not: a cuddled `: {` landing after a `//` would comment the
	 * whole else branch out.
	 */
	private static final SRC_COMMENT_ON_THEN: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag ? { alphaFieldNameThat'
		+ 'IsQuiteLong: 1234567, betaFieldNameThatIsQuiteLong: 2345678, gammaFieldNameThatIsLong: 34 } // keep the then pay'
		+ 'load above\n\t\t\t: { alphaFieldNameThatIsQuiteLong: 9876543, betaFieldNameThatIsQuiteLong: 8765432, gammaFieldN'
		+ 'ameThatIsLong: 76 };\n\t}\n}';

	/**
	 * The ELSE leg's lower edge: a then branch that breaks and an else whose flat width leaves its glued line landing exactly on the
	 * limit. Cuddling is free here and must happen — this is the fixture an over-reserved guard kills, and the one that fixes the band's
	 * position rather than merely its existence.
	 */
	private static final SRC_ELSE_FITS_GLUED: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag ? { alphaFieldNameThat'
		+ 'IsQuiteLong: 1234567, betaFieldNameThatIsQuiteLong: 2345678, gammaFieldNameThatIsQuiteLong: 3456789, deltaFieldNameThatIsLong: 4'
		+ ' } : { alphaFieldNameThatIsQuiteLong: 9876543, betaFieldNameThatIsQuiteLong: 8765432, gammaFieldNameThatIsRatherLongerStill: 7 }'
		+ ';\n\t}\n}';

	/**
	 * The same fixture with ONE more digit in the else's last value — the whole regression, in one character. The else still fits the
	 * separator line it would keep, and no longer fits the two-columns-wider line it would ride glued, so a cuddle would explode a branch
	 * that was a single line.
	 */
	private static final SRC_ELSE_ONLY_FITS_UNGLUED: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag ? { alphaFieldN'
		+ 'ameThatIsQuiteLong: 1234567, betaFieldNameThatIsQuiteLong: 2345678, gammaFieldNameThatIsQuiteLong: 3456789, deltaFieldNameThatIs'
		+ 'Long: 4 } : { alphaFieldNameThatIsQuiteLong: 9876543, betaFieldNameThatIsQuiteLong: 8765432, gammaFieldNameThatIsRatherLongerSti'
		+ 'll: 76 };\n\t}\n}';

	/**
	 * Acceptance shape: only the `:` side moved, `} : {` on one line, the `?` break untouched.
	 */
	private static final CUDDLED: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? {\n\t\t\t\talphaFieldName'
		+ 'ThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFieldNameThatIsLong: 34'
		+ '\n\t\t\t} : {\n\t\t\t\talphaFieldNameThatIsQuiteLong: 9876543,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 8765432,\n'
		+ '\t\t\t\tgammaFieldNameThatIsLong: 76\n\t\t\t};\n\t}\n}';

	/**
	 * The same input with the knob absent — the pre-knob layout, `: {` on a continuation line of its own.
	 */
	private static final SEPARATE: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? {\n\t\t\t\talphaFieldNam'
		+ 'eThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFieldNameThatIsLong: 34'
		+ '\n\t\t\t}\n\t\t\t: {\n\t\t\t\talphaFieldNameThatIsQuiteLong: 9876543,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 876'
		+ '5432,\n\t\t\t\tgammaFieldNameThatIsLong: 76\n\t\t\t};\n\t}\n}';

	/**
	 * The flat-branch ternary, identical with the knob on and off.
	 */
	private static final FLAT_TERNARY: String = 'class T {\n\tprivate function f():Void {\n\t\tfor (e in items) {\n\t\t\tfor (s in parts) {'
		+ '\n\t\t\t\tex = ex == null\n\t\t\t\t\t? { expr: EConst(CIdent(s)), pos: Context.currentPos() }\n\t\t\t\t\t: { exp'
		+ 'r: EField(ex, s), pos: Context.currentPos() };\n\t\t\t}\n\t\t}\n\t}\n}';

	/**
	 * The non-collection else, identical with the knob on and off — the separator keeps a continuation line of its own.
	 */
	private static final NON_COLLECTION_ELSE: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? {\n\t\t\t\tal'
		+ 'phaFieldNameThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFieldNameTha'
		+ 'tIsLong: 34\n\t\t\t}\n\t\t\t: (payloadValue) -> {\n\t\t\t\thandleFallbackPayload(payloadValue);\n\t\t\t\treportF'
		+ 'allbackTaken(payloadValue);\n\t\t\t};\n\t}\n}';

	/**
	 * The comment-bearing ternary, identical with the knob on and off — the `Keep`
	 * shaper reproduces the source's own `?` / `:` placement and never sees the flag.
	 */
	private static final COMMENT_ON_THEN: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? {\n\t\t\t\talphaF'
		+ 'ieldNameThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFieldNameThatIsL'
		+ 'ong: 34\n\t\t\t} // keep the then payload above\n\t\t\t: {\n\t\t\t\talphaFieldNameThatIsQuiteLong: 9876543,\n\t'
		+ '\t\t\tbetaFieldNameThatIsQuiteLong: 8765432,\n\t\t\t\tgammaFieldNameThatIsLong: 76\n\t\t\t};\n\t}\n}';

	/**
	 * The probe leg firing: under a cascade that defers every object-literal break to the renderer, the wide branches still cuddle.
	 */
	private static final PIVOT_CUDDLED: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? {\n\t\t\t\talphaFie'
		+ 'ldNameThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFieldNameThatIsQui'
		+ 'teLong: 3456789,\n\t\t\t\tdeltaFieldNameThatIsLong: 4\n\t\t\t} : {\n\t\t\t\talphaFieldNameThatIsQuiteLong: 98765'
		+ '43,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 8765432,\n\t\t\t\tgammaFieldNameThatIsQuiteLong: 7654321,\n\t\t\t\tde'
		+ 'ltaFieldNameThatIsLong: 5\n\t\t\t};\n\t}\n}';

	/**
	 * The same input and cascade with the knob absent.
	 */
	private static final PIVOT_SEPARATE: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? {\n\t\t\t\talphaFi'
		+ 'eldNameThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFieldNameThatIsQu'
		+ 'iteLong: 3456789,\n\t\t\t\tdeltaFieldNameThatIsLong: 4\n\t\t\t}\n\t\t\t: {\n\t\t\t\talphaFieldNameThatIsQuiteLon'
		+ 'g: 9876543,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 8765432,\n\t\t\t\tgammaFieldNameThatIsQuiteLong: 7654321,\n\t'
		+ '\t\t\tdeltaFieldNameThatIsLong: 5\n\t\t\t};\n\t}\n}';

	/**
	 * The probe leg DECLINING: under the same render-time cascade the narrower branches fit their own continuation lines, so they stay
	 * flat and there is no closing line to ride. Identical with the knob on and off.
	 */
	private static final PIVOT_FLAT: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? { alphaFieldNameThatIs'
		+ 'QuiteLong: 1234567, betaFieldNameThatIsQuiteLong: 2345678, gammaFieldNameThatIsLong: 34 }\n\t\t\t: { alphaFieldN'
		+ 'ameThatIsQuiteLong: 9876543, betaFieldNameThatIsQuiteLong: 8765432, gammaFieldNameThatIsLong: 76 };\n\t}\n}';

	/**
	 * The lower edge cuddling: `} : {` glued, the else still one line.
	 */
	private static final ELSE_FITS_GLUED_CUDDLED: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? {\n\t\t\t'
		+ '\talphaFieldNameThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFieldNameThatIsQuiteLong'
		+ ': 3456789,\n\t\t\t\tdeltaFieldNameThatIsLong: 4\n\t\t\t} : { alphaFieldNameThatIsQuiteLong: 9876543, betaFieldNameThatIsQuiteLon'
		+ 'g: 8765432, gammaFieldNameThatIsRatherLongerStill: 7 };\n\t}\n}';

	/**
	 * The same input with the knob absent — the separator keeps its own line, one line longer.
	 */
	private static final ELSE_FITS_GLUED_SEPARATE: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? {\n\t\t'
		+ '\t\talphaFieldNameThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFieldNameThatIsQuiteLo'
		+ 'ng: 3456789,\n\t\t\t\tdeltaFieldNameThatIsLong: 4\n\t\t\t}\n\t\t\t: { alphaFieldNameThatIsQuiteLong: 9876543, betaFieldNameThatI'
		+ 'sQuiteLong: 8765432, gammaFieldNameThatIsRatherLongerStill: 7 };\n\t}\n}';

	/**
	 * One digit wider, and the layout the knob must NOT change: identical with the knob on and off.
	 */
	private static final ELSE_ONLY_FITS_UNGLUED_SEPARATE: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? {'
		+ '\n\t\t\t\talphaFieldNameThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFieldNameThatIsQ'
		+ 'uiteLong: 3456789,\n\t\t\t\tdeltaFieldNameThatIsLong: 4\n\t\t\t}\n\t\t\t: { alphaFieldNameThatIsQuiteLong: 9876543, betaFieldNam'
		+ 'eThatIsQuiteLong: 8765432, gammaFieldNameThatIsRatherLongerStill: 76 };\n\t}\n}';

	/**
	 * The closer-run edge: the same one-character straddle, one closer wider. The then branch is an object inside a CALL, so its closing
	 * line is `})` — two columns, not one — and the else rides that whole run. This narrower fixture's glued line lands exactly on the
	 * limit and must cuddle. Stated in the SEPARATED layout, so the single write this fixture measures is the one that glues it.
	 */
	private static final SRC_CLOSER_RUN_FITS_GLUED: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? wrapIt('
		+ '{\n\t\t\t\talphaFieldNameThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFieldNameThatI'
		+ 'sQuiteLong: 3456789\n\t\t\t})\n\t\t\t: { alphaFieldNameThatIsQuiteLong: 9876543, betaFieldNameIsLong: 8765432, gaaaaaaaaaaaaaaa'
		+ 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaa: 7 };\n\t}\n}';

	/** One character wider, so the glued line lands one past the limit and cuddling there explodes a one-line else into four. */
	private static final SRC_CLOSER_RUN_ONLY_FITS_UNGLUED: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? '
		+ 'wrapIt({\n\t\t\t\talphaFieldNameThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFieldNa'
		+ 'meThatIsQuiteLong: 3456789\n\t\t\t})\n\t\t\t: { alphaFieldNameThatIsQuiteLong: 9876543, betaFieldNameIsLong: 8765432, gaaaaaaaa'
		+ 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: 7 };\n\t}\n}';

	/** The closer-run edge cuddling: `}) : {` glued, the else still one line, that line exactly 140 columns. */
	private static final CLOSER_RUN_CUDDLED: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? wrapIt({\n\t\t'
		+ '\t\talphaFieldNameThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFieldNameThatIsQuiteL'
		+ 'ong: 3456789\n\t\t\t}) : { alphaFieldNameThatIsQuiteLong: 9876543, betaFieldNameIsLong: 8765432, gaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
		+ 'aaaaaaaaaaaaaaa: 7 };\n\t}\n}';

	/**
	 * The padded-run edge. A `closingPolicy: "before"` call paren renders the then branch's closing line as `} )` — three columns,
	 * one of which is a SPACE the closer characters alone do not count. This narrower fixture's glued line lands exactly on the limit
	 * and must cuddle; stated in the SEPARATED layout, so the single write it measures is the one that glues it.
	 */
	private static final SRC_PADDED_RUN_FITS_GLUED: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? wrapIt('
		+ ' {\n\t\t\t\talphaFieldNameThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFieldNameThat'
		+ 'IsQuiteLong: 3456789\n\t\t\t} )\n\t\t\t: { alphaFieldNameThatIsQuiteLong: 9876543, betaFieldNameIsLong: 8765432, gggggggggggggg'
		+ 'gggggggggggggggggggggggggggggg: 7 };\n\t}\n}';

	/** One character wider, so the glued line lands one past the limit — the width the space is what decides it. */
	private static final SRC_PADDED_RUN_ONLY_FITS_UNGLUED: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? '
		+ 'wrapIt( {\n\t\t\t\talphaFieldNameThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFieldN'
		+ 'ameThatIsQuiteLong: 3456789\n\t\t\t} )\n\t\t\t: { alphaFieldNameThatIsQuiteLong: 9876543, betaFieldNameIsLong: 8765432, ggggggg'
		+ 'gggggggggggggggggggggggggggggggggggggg: 7 };\n\t}\n}';

	/** The padded-run edge cuddling: `} ) : {` glued, the else still one line. */
	private static final PADDED_RUN_CUDDLED: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag\n\t\t\t? wrapIt( {\n\t'
		+ '\t\t\talphaFieldNameThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFieldNameThatIsQuit'
		+ 'eLong: 3456789\n\t\t\t} ) : { alphaFieldNameThatIsQuiteLong: 9876543, betaFieldNameIsLong: 8765432, ggggggggggggggggggggggggggg'
		+ 'ggggggggggggggggg: 7 };\n\t}\n}';

	/**
	 * The `onePerLine` shaper leg — a cascade that breaks before the condition too still cuddles the `:` gap.
	 */
	private static final ONE_PER_LINE_CUDDLED: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg =\n\t\t\tflag\n\t\t\t? {\n\t'
		+ '\t\t\talphaFieldNameThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFiel'
		+ 'dNameThatIsLong: 34\n\t\t\t} : {\n\t\t\t\talphaFieldNameThatIsQuiteLong: 9876543,\n\t\t\t\tbetaFieldNameThatIsQu'
		+ 'iteLong: 8765432,\n\t\t\t\tgammaFieldNameThatIsLong: 76\n\t\t\t};\n\t}\n}';

	/**
	 * The same `onePerLine` cascade with the knob absent.
	 */
	private static final ONE_PER_LINE_SEPARATE: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg =\n\t\t\tflag\n\t\t\t? {\n'
		+ '\t\t\t\talphaFieldNameThatIsQuiteLong: 1234567,\n\t\t\t\tbetaFieldNameThatIsQuiteLong: 2345678,\n\t\t\t\tgammaFi'
		+ 'eldNameThatIsLong: 34\n\t\t\t}\n\t\t\t: {\n\t\t\t\talphaFieldNameThatIsQuiteLong: 9876543,\n\t\t\t\tbetaFieldNam'
		+ 'eThatIsQuiteLong: 8765432,\n\t\t\t\tgammaFieldNameThatIsLong: 76\n\t\t\t};\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** Acceptance: two object-literal branches put `} : {` on one line, and the `?` keeps its own break. */
	public function testObjectBranchesCuddleTheSeparator(): Void {
		Assert.equals(CUDDLED, triviaWrite(SRC_OBJECTS, COMMITTED_ON));
	}

	/** Knob absent (`false`): the separator keeps a continuation line of its own — byte-inert default. */
	public function testKnobOffKeepsTheSeparatorOnItsOwnLine(): Void {
		Assert.equals(SEPARATE, triviaWrite(SRC_OBJECTS, COMMITTED_OFF));
	}

	/**
	 * The cuddled layout is a fixed point: the compact output fed back in reproduces itself byte for byte. Stated against the literal
	 * expected output rather than against a previous write, so a shaper that stopped cuddling would fail here too.
	 */
	public function testCuddledTernaryIsIdempotent(): Void {
		Assert.equals(CUDDLED, triviaWrite(CUDDLED, COMMITTED_ON));
	}

	/**
	 * A broken ternary whose branches BOTH render flat keeps the separator on its own line even with the knob on: neither branch has a
	 * closing line to ride, and cuddling would rebuild the whole ternary on one line. The Pony sites that must not move.
	 */
	public function testFlatBranchesKeepTheSeparatorOnItsOwnLine(): Void {
		Assert.equals(FLAT_TERNARY, triviaWrite(SRC_FLAT_BRANCHES, COMMITTED_ON), 'knob on must leave a flat-branch ternary alone');
		Assert.equals(FLAT_TERNARY, triviaWrite(SRC_FLAT_BRANCHES, COMMITTED_OFF));
	}

	/** An else operand that is not a delimited body is declined: `} : (v) -> {` is not the shape the knob is about. */
	public function testNonCollectionElseIsDeclined(): Void {
		Assert.equals(
			NON_COLLECTION_ELSE, triviaWrite(SRC_NON_COLLECTION_ELSE, COMMITTED_ON), 'knob on must not glue an arrow-bodied else'
		);
		Assert.equals(NON_COLLECTION_ELSE, triviaWrite(SRC_NON_COLLECTION_ELSE, COMMITTED_OFF));
	}

	/**
	 * The probe leg: under a cascade that defers every object-literal break to the renderer, branches too wide for their own
	 * continuation line still cuddle — the structural read sees no committed hardline there, so only the resolved pivot can.
	 */
	public function testRenderPivotBranchesCuddleWhenTheContinuationOverflows(): Void {
		Assert.equals(PIVOT_CUDDLED, triviaWrite(SRC_OBJECTS_WIDE, PIVOT_ON));
		Assert.equals(PIVOT_SEPARATE, triviaWrite(SRC_OBJECTS_WIDE, PIVOT_OFF), 'knob off must keep the separator line');
	}

	/**
	 * The probe leg declining, and the reason the probe exists: under the SAME render-time cascade, branches that fit their own
	 * continuation line stay flat, so there is no closing line to ride. Without the probe this input would be glued onto one line.
	 */
	public function testRenderPivotBranchesStayFlatWhenTheContinuationFits(): Void {
		Assert.equals(PIVOT_FLAT, triviaWrite(SRC_OBJECTS, PIVOT_ON), 'knob on must not cuddle a branch the renderer keeps flat');
		Assert.equals(PIVOT_FLAT, triviaWrite(SRC_OBJECTS, PIVOT_OFF));
	}

	/** The probe leg's output is a fixed point too — the second pass reads the newline the first one wrote and still cuddles. */
	public function testCuddledPivotTernaryIsIdempotent(): Void {
		Assert.equals(PIVOT_CUDDLED, triviaWrite(PIVOT_CUDDLED, PIVOT_ON));
	}

	/**
	 * The ELSE leg of the gate, and the only shape in this class where cuddling
	 * COSTS lines. Gluing does not move the else branch, it shifts it right by the
	 * then branch's closing-line closer run and the space after it — two columns
	 * for the bare `}` these fixtures have — so an else that fits its own separator
	 * line can overflow the line it rides once glued, and the renderer then breaks
	 * a branch that was a single line. The two fixtures differ by ONE digit and
	 * straddle that edge: the narrower one's glued line lands exactly on the limit
	 * and must cuddle, the wider one's lands one past it and must keep the
	 * separator line the knob normally removes. Both knob-off arms are the same
	 * pre-knob layout, so the wider case asserts inertness against a config that
	 * changes nothing.
	 */
	public function testElseThatOnlyFitsUngluedKeepsTheSeparatorOnItsOwnLine(): Void {
		Assert.equals(ELSE_FITS_GLUED_CUDDLED, triviaWrite(SRC_ELSE_FITS_GLUED, PIVOT_ON), 'an else whose glued line fits must cuddle');
		Assert.equals(ELSE_FITS_GLUED_SEPARATE, triviaWrite(SRC_ELSE_FITS_GLUED, PIVOT_OFF));
		Assert.equals(
			ELSE_ONLY_FITS_UNGLUED_SEPARATE, triviaWrite(SRC_ELSE_ONLY_FITS_UNGLUED, PIVOT_ON),
			'knob on must not glue an else the glue would break'
		);
		Assert.equals(ELSE_ONLY_FITS_UNGLUED_SEPARATE, triviaWrite(SRC_ELSE_ONLY_FITS_UNGLUED, PIVOT_OFF));
	}

	/**
	 * The width the else rides is the whole CLOSER RUN of the then branch's closing
	 * line, not its last token. An object inside a call closes `})`, so the glue
	 * costs three columns, not two. Charging one closer admits a glued line one past
	 * the limit, and the renderer then explodes a one-line else into four. Same
	 * one-character straddle as above, one closer wider.
	 */
	public function testCloserRunWidthIsChargedInFull(): Void {
		Assert.equals(
			CLOSER_RUN_CUDDLED, triviaWrite(SRC_CLOSER_RUN_FITS_GLUED, COMMITTED_WIDE_ON), 'a glued line landing on the limit must cuddle'
		);
		Assert.equals(SRC_CLOSER_RUN_FITS_GLUED, triviaWrite(SRC_CLOSER_RUN_FITS_GLUED, COMMITTED_WIDE_OFF));
		Assert.equals(
			SRC_CLOSER_RUN_ONLY_FITS_UNGLUED, triviaWrite(SRC_CLOSER_RUN_ONLY_FITS_UNGLUED, COMMITTED_WIDE_ON),
			'the `})` run costs two columns, not one'
		);
		Assert.equals(SRC_CLOSER_RUN_ONLY_FITS_UNGLUED, triviaWrite(SRC_CLOSER_RUN_ONLY_FITS_UNGLUED, COMMITTED_WIDE_OFF));
	}

	/**
	 * The run is measured as the closing line RENDERS, not as a count of closer characters. A `closingPolicy: "before"` call paren
	 * pads it to `} )`, and the space is a column the else rides just like the parens do — charged short, the knob glues a line one
	 * past the limit and the renderer explodes the else. The two fixtures differ by one character in the else and straddle that edge.
	 */
	public function testPaddedCloserRunChargesItsWhitespace(): Void {
		Assert.equals(
			PADDED_RUN_CUDDLED, triviaWrite(SRC_PADDED_RUN_FITS_GLUED, PADDED_ON), 'a padded run whose glued line fits must cuddle'
		);
		Assert.equals(SRC_PADDED_RUN_FITS_GLUED, triviaWrite(SRC_PADDED_RUN_FITS_GLUED, PADDED_OFF));
		Assert.equals(
			SRC_PADDED_RUN_ONLY_FITS_UNGLUED, triviaWrite(SRC_PADDED_RUN_ONLY_FITS_UNGLUED, PADDED_ON),
			'the space inside `} )` is a column the else rides'
		);
		Assert.equals(SRC_PADDED_RUN_ONLY_FITS_UNGLUED, triviaWrite(SRC_PADDED_RUN_ONLY_FITS_UNGLUED, PADDED_OFF));
	}

	/**
	 * The `onePerLine` shaper leg: a ternary cascade that breaks before the CONDITION as well cuddles the same `:` gap. The knob's
	 * meaning does not depend on which one-operand-per-line shape the cascade picked.
	 */
	public function testOnePerLineCascadeCuddlesTheSeparator(): Void {
		Assert.equals(ONE_PER_LINE_CUDDLED, triviaWrite(SRC_OBJECTS, ONE_PER_LINE_ON));
		Assert.equals(ONE_PER_LINE_SEPARATE, triviaWrite(SRC_OBJECTS, ONE_PER_LINE_OFF), 'knob off must keep the separator line');
	}

	/**
	 * A trailing LINE comment on the then operand must never be glued past — a cuddled
	 * `: {` landing after a `//` would comment the whole else branch out. DOUBLE
	 * protected, and the doubling is stated because it is what this pin can and
	 * cannot catch: the captured comment becomes the LAST thing in the then branch
	 * Doc, so the gate's closing-line requirement declines before any shaper runs,
	 * AND the comment forces the source-faithful `Keep` shape, which never reads the
	 * flag. Reverting either alone leaves this case green; reverting BOTH flips it.
	 */
	public function testCommentOnThenOperandIsDeclined(): Void {
		Assert.equals(COMMENT_ON_THEN, triviaWrite(SRC_COMMENT_ON_THEN, COMMITTED_ON), 'knob on must not glue past a line comment');
		Assert.equals(COMMENT_ON_THEN, triviaWrite(SRC_COMMENT_ON_THEN, COMMITTED_OFF));
	}

	private inline function triviaWrite(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	/**
	 * The shared config with `extraWrapping` (a comma-terminated JSON fragment) spliced into its `wrapping` section. Static because the
	 * fixture constants are initialised before any instance exists.
	 */
	private static function config(extraWrapping: String, extraWhitespace: String = ''): String {
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {$extraWrapping'
			+ '"maxLineLength": 140}, "sameLine": {"ifBody": "fitLine", "functionBody": "fitLine"}, "whitespace": {$extraWhitespace'
			+ '"bracesConfig": {"objectLiteralBraces": {"openingPolicy": "after", "closingPolicy": "before"}}}}';
	}

}
