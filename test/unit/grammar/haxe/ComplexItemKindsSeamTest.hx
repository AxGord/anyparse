package unit.grammar.haxe;

import anyparse.grammar.haxe.AstPreds;
import anyparse.grammar.haxe.AstPredsT;
import anyparse.grammar.haxe.HxComplexItems;
import anyparse.grammar.haxe.HxExpr;
import utest.Assert;
import utest.Test;

/**
 * `AstPreds.complexItemKinds` — the seam that took the LAST grammar type name
 * out of the build macro.
 *
 * `@:fmt(complexItems)` gives `WrapList` one complexity code per element of a
 * delimited list. The classifier is `HxComplexItems`, a grammar-side reflective
 * walk, and until this seam BOTH of the macro's emit sites for the flag —
 * `WriterLowering`'s plain postfix-Star and `TriviaSepLowering`'s trivia
 * sep-Star — put `anyparse.grammar.haxe.HxComplexItems.kinds` straight into the
 * code they generate. A second grammar could name the flag and get a call to
 * the Haxe classifier; that is invariant 4 read backwards.
 *
 * The predicate is now a `HxAstPredLowering` table entry like every other shape
 * gate, so the macro addresses it through the `AstPreds` naming convention and
 * never through a grammar type. What this pins is the half a byte-identity
 * capture cannot see: that the seam is WIRED — that the generated forwarder
 * exists in BOTH families and answers what the classifier answers, rather than
 * existing and being ignored.
 *
 * PROBED CONTRACT, with its limits. The samples are built with
 * `Type.createEnum` at the declared arities of `HxExpr` (`Call/2`,
 * `ArrayExpr/1`, `PostIncr/1`), which is the plain family. The `AstPredsT` arm
 * therefore feeds it PLAIN values too: legitimate, because the classifier is
 * untyped by design and both marker classes carry the same forwarder — it
 * proves the trivia family got the entry, not that a trivia-synth value
 * classifies. The `LAMBDA` code (4) is not exercised: it needs an arrow ctor
 * whose arity is not stated here, and the four codes below already discriminate
 * every arm the two consumers read.
 *
 * PILOT for the machine-checkable pin metadata: `@:pin` names what a fixture
 * is FOR and `@:killer` names the mutation arm that must break it, and
 * `testkit.TestDiscovery` refuses to BUILD a `@:pin` control that names no
 * arm. `M-KINDS` is real and was run: collapsing `CONTAINER_PLAIN` into
 * `NONE` inside `HxComplexItems.kinds` fails the control below. The seam pin
 * takes no killer on purpose — it compares the two families to each other,
 * so an arm that moves a code moves BOTH sides and the equality survives.
 * That is a property of the pin, and the role now states it instead of a
 * reader having to notice it.
 */
@:nullSafety(Strict)
class ComplexItemKindsSeamTest extends Test {

	/** A bare call — the `CALL` code, and the payload that makes a container complex. */
	private final _call: HxExpr = Type.createEnum(HxExpr, 'Call', [null, []]);

	/**
	 * One list holding every code the seam has to distinguish: a call, a
	 * container with nothing below it, a container carrying that call, and an
	 * element that is neither.
	 */
	@:pin('control')
	@:killer('M-KINDS')
	public function testTheGeneratedPredicateAnswersTheClassifier(): Void {
		final elements: Array<Any> = sampleElements();
		Assert.same([
			HxComplexItems.CALL,
			HxComplexItems.CONTAINER_PLAIN,
			HxComplexItems.CONTAINER,
			HxComplexItems.NONE
		], AstPreds.complexItemKinds(elements), 'the four codes the writer reads');
		Assert.same(HxComplexItems.kinds(elements), AstPreds.complexItemKinds(elements), 'the forwarder IS the classifier');
	}

	/**
	 * The trivia family carries the same entry. The macro reaches
	 * `AstPredsT.complexItemKinds` from `TriviaSepLowering`, so an entry present
	 * only on the plain marker class would leave the trivia writer — the one the
	 * formatter actually runs — with no predicate at all.
	 */
	@:pin('seam')
	public function testTheTriviaFamilyCarriesTheSameEntry(): Void {
		final elements: Array<Any> = sampleElements();
		Assert.same(AstPreds.complexItemKinds(elements), AstPredsT.complexItemKinds(elements), 'both families, one answer');
	}

	/** The `Trivial<T>` wrapper the trivia writer holds elements in unwraps to the same code. */
	public function testAWrappedElementClassifiesAsItsNode(): Void {
		Assert.same([HxComplexItems.CALL], AstPreds.complexItemKinds([{ node: _call }]));
	}

	/** Call, empty container, call-bearing container, neither — in that order. */
	private function sampleElements(): Array<Any> {
		return [
			_call,
			Type.createEnum(HxExpr, 'ArrayExpr', [[]]),
			Type.createEnum(HxExpr, 'ArrayExpr', [[_call]]),
			Type.createEnum(HxExpr, 'PostIncr', [null])
		];
	}

}
