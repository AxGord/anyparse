package unit;

import anyparse.core.D;
import anyparse.core.Doc;
import anyparse.format.wrap.BinaryChainEmit;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrapRules;
import anyparse.format.wrap.WrappingLocation;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * omega-ternary-cuddle-tail, second half: `BinaryChainEmit.honoursCuddleLast`
 * USED to ask about the WRAP MODE alone, while both shapers that honour the
 * flag read it only in their `BeforeLast` location arm. Under
 * `defaultLocation: "afterLast"` the two slots a cuddle-gated shape wraps are
 * therefore the SAME layout twice, and the pair of width probes bracketing them
 * could only ever pick between two identical Docs. The knob now takes the
 * location as well, and builds no probes there at all.
 *
 * That costs no layout — which is exactly why no write fixture can pin it. This
 * class asserts on the emitted `Doc` instead: the probe nodes must be ABSENT
 * under `AfterLast` and PRESENT under `BeforeLast`, from one call to
 * `BinaryChainEmit.emit` over hand-built operands, with the shared end-to-end
 * inertness stated alongside so the two halves of the claim sit together.
 *
 * The counter matches on the ctor NAME prefix rather than a pattern, so it
 * counts the plain `IfArrowContinuationFits` and its rest-aware sibling alike —
 * which is what lets the same assertions run against an engine that has only
 * the first.
 */
@:nullSafety(Strict)
final class HxTernaryCuddleProbeShapeTest extends Test {

	/** The knob on, at the 140-column limit the rest of the cuddle fixtures use. */
	private static final CFG_ON: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"ternaryCuddledBraces": true, "maxLineLength": 140}}';

	/**
	 * A ternary whose then branch is an object literal already broken in the source and whose else branch is a second one — the shape
	 * the cuddle's structural leg admits. Written wide enough that the cascade breaks it at every location.
	 */
	private static final SRC: String = 'class T {\n\tprivate function f():Void {\n\t\tvar cfg = flag ? { alphaFieldNameThatIsQuiteLong:'
		+ ' 1234567, betaFieldNameThatIsQuiteLong: 2345678, gammaFieldNameThatIsLong: 34 } : { alphaFieldNameThatIsQuiteLong: 9876543,'
		+ ' betaFieldNameThatIsQuiteLong: 8765432, gammaFieldNameThatIsLong: 76 };\n\t}\n}';

	public function new(): Void {
		super();
	}

	/**
	 * `BeforeLast` builds the pair of width probes the cuddle decision needs;
	 * `AfterLast` builds NONE, because the shape it would choose between is the
	 * same one twice. The `BeforeLast` count is the control: it proves the counter
	 * reaches the probes at all, so a zero on the other arm is an absence rather
	 * than a walker that never looked. The exact `2` pins one more thing than the
	 * control needs — that a single cascade leaf reaches `cuddleShape`, and that
	 * the leg reached is the STRUCTURAL one (the probe-gated leg builds three, and
	 * nothing here pins that count).
	 */
	public function testAfterLastLocationBuildsNoCuddleProbes(): Void {
		Assert.equals(
			2, probes(WrappingLocation.BeforeLast), 'the beforeLast shaper reads the flag, so its slots differ and need the probes'
		);
		Assert.equals(
			0, probes(WrappingLocation.AfterLast),
			'the afterLast shaper never reads the flag, so a probe there picks between identical Docs'
		);
	}

	/**
	 * The other half of the same claim, end to end: under `afterLast` the knob's output is byte-identical to the knob off. Stated as an
	 * equality between two writes rather than against a literal, because what it asserts is that the knob does NOTHING there — a
	 * literal would also pass if both arms regressed together.
	 *
	 * The `beforeLast` inequality comes FIRST and is not decoration: it is the non-vacuity witness. This same fixture under the format's
	 * default object-literal cascade keeps both branches flat, and then the knob moves nothing at EITHER location — the equality below
	 * would pass while proving nothing about the location axis. Asserting that the knob does move the beforeLast arm is what makes the
	 * afterLast equality a statement about `honoursCuddleLast` rather than about the fixture.
	 */
	public function testAfterLastOutputIsKnobIndependent(): Void {
		Assert.notEquals(
			HxWriteFixture.triviaWrite(SRC, ternaryCascade('beforeLast', false)),
			HxWriteFixture.triviaWrite(SRC, ternaryCascade('beforeLast', true)),
			'the fixture must be one the knob actually moves, or the afterLast equality is vacuous'
		);
		Assert.equals(
			HxWriteFixture.triviaWrite(SRC, ternaryCascade('afterLast', false)),
			HxWriteFixture.triviaWrite(SRC, ternaryCascade('afterLast', true))
		);
	}

	/** The number of continuation-fits probe nodes `emit` puts in a cuddle-admitted ternary at `location`. */
	private static function probes(location: WrappingLocation): Int {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CFG_ON);
		final rules: WrapRules = { rules: [], defaultMode: WrapMode.OnePerLineAfterFirst, defaultLocation: location };
		return countProbes(BinaryChainEmit.emit([Text('flag'), brokenObject(), Text('{ beta: 2 }')], ['?', ':'], opts, rules));
	}

	/**
	 * An object literal whose break is already committed: an open brace, one nested member line, and a closing line back at the
	 * branch's own indent. That closing line is what the cuddle's structural leg looks for.
	 */
	private static function brokenObject(): Doc {
		return Concat([
			Text('{'),
			Nest(1, Concat([Line('\n'), Text('alphaFieldName: 1')])),
			Line('\n'),
			Text('}')
		]);
	}

	/**
	 * Every `IfArrowContinuationFits*` node in `d`, counted by ctor-name prefix so the walk is blind to which of the two spellings the
	 * engine emitted. `D.mapChildren` supplies the traversal; its result is discarded, only the visit matters.
	 */
	private static function countProbes(d: Doc): Int {
		var n: Int = Type.enumConstructor(d).indexOf('IfArrowContinuationFits') == 0 ? 1 : 0;
		D.mapChildren(d, c -> {
			n += countProbes(c);
			c;
		}); // noqa: unused-return-value
		return n;
	}

	/**
	 * A ternary cascade forced to `onePerLineAfterFirst`, its operator location and the knob's presence supplied per call. The
	 * object-literal cascade is COMMITTED (a breaking default with a narrow `noWrap` rule) rather than left at the format default:
	 * without it both branches of `SRC` stay flat, the cuddle's own closing-line requirement declines before any location is consulted,
	 * and every knob-on/knob-off equality below would hold for a reason that has nothing to do with the location.
	 */
	private static function ternaryCascade(location: String, knob: Bool): String {
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {${knob ? '"ternaryCuddledBraces": true, ' : ''}'
			+ '"objectLiteral": {"defaultWrap": "onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 60}],'
			+ ' "type": "noWrap"}]}, "ternaryExpression": {"defaultWrap": "onePerLineAfterFirst", "defaultLocation": "$location",'
			+ ' "rules": []}, "maxLineLength": 140}, "sameLine": {"ifBody": "fitLine", "functionBody": "fitLine"}, "whitespace":'
			+ ' {"bracesConfig": {"objectLiteralBraces": {"openingPolicy": "after", "closingPolicy": "before"}}}}';
	}

}
