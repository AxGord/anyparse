package unit.check;

import anyparse.check.NullFlowScan;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * `NullFlowScan` — the gates the null-flow consumers share: the seam bundle answers null when a
 * required seam is unset, a null comparison yields its identifier operand with the comparison's
 * span, and a first child reads as an identifier operand only when it is one and the host has a
 * span. Green at base by construction: each helper restates a gate its adopters already ran.
 */
@:nullSafety(Strict)
class NullFlowScanTest extends Test {

	private static final SHAPE: RefShape = new HaxeQueryPlugin().refShape();

	public function testSeamsOfCarriesTheHaxeSeams(): Void {
		final s: Null<NullFlowSeams> = NullFlowScan.seamsOf(SHAPE);
		Assert.notNull(s);
		if (s == null) return;
		Assert.isTrue(s.equalityKinds.length > 0);
		Assert.equals(SHAPE.identKind, s.identKind);
		Assert.equals(SHAPE.nullLiteralKind, s.nullLitKind);
		Assert.equals(SHAPE.eqKind, s.eqKind);
	}

	public function testSeamsOfIsNullWhenARequiredSeamIsUnset(): Void {
		Assert.isNull(NullFlowScan.seamsOf(withoutEquality()));
	}

	public function testNullComparedOperandReadsTheIdentifierSide(): Void {
		final s: Null<NullFlowSeams> = NullFlowScan.seamsOf(SHAPE);
		if (s == null) {
			Assert.fail('the Haxe shape declares every seam');
			return;
		}
		final x: QueryNode = ident('x');
		final cmp: QueryNode = new QueryNode(s.equalityKinds[0], null, [nullLit(s), x], new Span(4, 13));
		final m: Null<IdentOperand> = NullFlowScan.nullComparedOperand(cmp, s);
		Assert.notNull(m);
		if (m == null) return;
		Assert.equals(x, m.operand);
		Assert.equals('x', m.name);
		Assert.equals(4, m.span.from);
		Assert.equals(13, m.span.to);
	}

	public function testNullComparedOperandRefusesOtherComparisons(): Void {
		final s: Null<NullFlowSeams> = NullFlowScan.seamsOf(SHAPE);
		if (s == null) {
			Assert.fail('the Haxe shape declares every seam');
			return;
		}
		final eq: String = s.equalityKinds[0];
		Assert.isNull(NullFlowScan.nullComparedOperand(new QueryNode(eq, null, [ident('x'), ident('y')], new Span(0, 6)), s));
		Assert.isNull(NullFlowScan.nullComparedOperand(new QueryNode(eq, null, [nullLit(s), nullLit(s)], new Span(0, 12)), s));
		Assert.isNull(NullFlowScan.nullComparedOperand(new QueryNode('Other', null, [nullLit(s), ident('x')], new Span(0, 9)), s));
		Assert.isNull(NullFlowScan.nullComparedOperand(new QueryNode(eq, null, [nullLit(s), ident('x')]), s));
	}

	public function testIdentOperandNeedsANamedIdentifierAndAHostSpan(): Void {
		final x: QueryNode = ident('x');
		final host: QueryNode = new QueryNode('SafeNav', null, [x], new Span(2, 6));
		final m: Null<IdentOperand> = NullFlowScan.identOperand(host, x, SHAPE.identKind);
		Assert.notNull(m);
		if (m != null) Assert.equals(2, m.span.from);
		Assert.isNull(NullFlowScan.identOperand(new QueryNode('SafeNav', null, [x]), x, SHAPE.identKind));
		Assert.isNull(NullFlowScan.identOperand(host, null, SHAPE.identKind));
		Assert.isNull(NullFlowScan.identOperand(host, new QueryNode('Call', null, []), SHAPE.identKind));
		Assert.isNull(NullFlowScan.identOperand(host, new QueryNode(SHAPE.identKind, null, []), SHAPE.identKind));
	}

	private static function ident(name: String): QueryNode {
		return new QueryNode(SHAPE.identKind, name, [], new Span(0, name.length));
	}

	private static function nullLit(s: NullFlowSeams): QueryNode {
		return new QueryNode(s.nullLitKind, null, [], new Span(0, 4));
	}

	private static function withoutEquality(): RefShape {
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		shape.equalityKinds = [];
		return shape;
	}

}
