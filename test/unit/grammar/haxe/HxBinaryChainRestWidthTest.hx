package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * omega-chain-rest-width: an `&&` / `||` or `+` / `-` chain whose flat body ends
 * on the line limit but whose PHYSICAL line overflows by the trailing rest (the
 * statement `;`, an enclosing `)`) or by the un-flushed space after `=` breaks at
 * its OWN operator, as the fork does. The chain pivot used to be a plain
 * `Group(IfBreak)`, whose fit measures `col + flatWidth` only: the chain stayed
 * glued, and the line then broke at the first inner group that did see the rest
 * (before a nested `==`, after `return`) or not at all (a `+` chain spilled past
 * the limit). Identifiers are fully synthetic.
 */
@:nullSafety(Strict)
final class HxBinaryChainRestWidthTest extends Test {

	/** The client-shaped config the sister chain-indent tests pin. */
	private static final CFG: String = HxTernaryBranchChainIndentTest.CFG;

	public function new(): Void {
		super();
	}

	/**
	 * A declaration whose physical line is ONE column past the limit (the trailing `;`): the chain breaks
	 * before its last `&&`, never inside the `==` operand.
	 */
	@:pin('control')
	@:killer('M-CHAIN-REST-FILL-GROUP-PLAIN', 'M-CHAIN-REST-SHAPE-UNTHREADED', 'M-CHAIN-REST-UNSET')
	public function testDeclarationOneColumnOverBreaksAtAnd(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tfinal ready:Bool = pendingMarkers.length == 0 && sessionCh'
			+ 'anged && requestedAnchors.count() == 0\n\t\t\t&& !seenBefore(index, trailingNode);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tfinal ready:Bool = pendingMarkers.length == 0 && sessionChan'
				+ 'ged && requestedAnchors.count() == 0 && !seenBefore(index, trailingNode);\n\t}\n}',
				CFG
			)
		);
	}

	/** Two columns past the limit (the `;` and the un-flushed space after `=`): still the `&&`. */
	@:pin('control')
	@:killer('M-CHAIN-REST-PIVOT-PLAIN')
	public function testDeclarationTwoColumnsOverBreaksAtAnd(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tfinal ready:Bool = pendingMarkers.length == 0 && sessionCh'
			+ 'anged && requestedAnchors.count() == 0\n\t\t\t&& !seenBefore(index, trailingNodes);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tfinal ready:Bool = pendingMarkers.length == 0 && sessionChan'
				+ 'ged && requestedAnchors.count() == 0 && !seenBefore(index, trailingNodes);\n\t}\n}',
				CFG
			)
		);
	}

	/** REGRESSION PIN (does NOT discriminate the fix): a declaration landing EXACTLY on the limit stays on one line. */
	public function testDeclarationOnTheLimitStaysFlat(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tfinal ready:Bool = pendingMarkers.length == 0 && sessionCh'
			+ 'anged && requestedAnchors.count() == 0 && !seenBefore(index, trailingEnd);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tfinal ready:Bool = pendingMarkers.length == 0 && sessionChan'
				+ 'ged && requestedAnchors.count() == 0 && !seenBefore(index, trailingEnd);\n\t}\n}',
				CFG
			)
		);
	}

	/** A `return` value one column past the limit breaks the chain at `&&`, not after `return`. */
	public function testReturnOneColumnOverBreaksAtAnd(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\treturn pendingMarkers.length == 0 && sessionChanged && req'
			+ 'uestedAnchors.count() == 0\n\t\t\t&& !seenBefore(index, spanPaths, trailingNodes);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\treturn pendingMarkers.length == 0 && sessionChanged && reque'
				+ 'stedAnchors.count() == 0 && !seenBefore(index, spanPaths, trailingNodes);\n\t}\n}',
				CFG
			)
		);
	}

	/** A `return` value two columns past the limit breaks the chain at `&&`, not before the nested `==`. */
	public function testReturnTwoColumnsOverBreaksAtAnd(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\treturn pendingMarkers.length == 0 && sessionChanged && req'
			+ 'uestedAnchors.count() == 0\n\t\t\t&& !seenBefore(index, spanPath, trailingAnchors);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\treturn pendingMarkers.length == 0 && sessionChanged && reque'
				+ 'stedAnchors.count() == 0 && !seenBefore(index, spanPath, trailingAnchors);\n\t}\n}',
				CFG
			)
		);
	}

	/** A plain assignment one column past the limit breaks the chain at `&&`. */
	public function testAssignmentOneColumnOverBreaksAtAnd(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tready = pendingMarkers.length == 0 && sessionChanged && re'
			+ 'questedAnchors.count() == 0\n\t\t\t&& !seenBefore(index, spanPath, trailingNodes);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tready = pendingMarkers.length == 0 && sessionChanged && requ'
				+ 'estedAnchors.count() == 0 && !seenBefore(index, spanPath, trailingNodes);\n\t}\n}',
				CFG
			)
		);
	}

	/** The `+` chain shares the pivot: one column past the limit it breaks before its last `+` instead of overflowing. */
	@:pin('control')
	@:killer('M-CHAIN-REST-ADD-PIVOT-PLAIN')
	public function testAddChainOneColumnOverBreaksAtPlus(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tfinal total:Int = pendingMarkersWidth + sessionChangedWidt'
			+ 'h + requestedAnchors.count() * 10 + trailingMarkerWidth\n\t\t\t+ closingSpanWidth;\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tfinal total:Int = pendingMarkersWidth + sessionChangedWidth '
				+ '+ requestedAnchors.count() * 10 + trailingMarkerWidth + closingSpanWidth;\n\t}\n}',
				CFG
			)
		);
	}

	/** Two columns past the limit: still the `+`. */
	@:pin('control')
	@:killer('M-COLLAPSE-ADD-REBUILD-PLAIN')
	public function testAddChainTwoColumnsOverBreaksAtPlus(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tfinal total:Int = pendingMarkersWidth + sessionChangedWidt'
			+ 'h + requestedAnchors.count() * 10 + trailingMarkerWidth\n\t\t\t+ closingSpansWidth;\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tfinal total:Int = pendingMarkersWidth + sessionChangedWidth '
				+ '+ requestedAnchors.count() * 10 + trailingMarkerWidth + closingSpansWidth;\n\t}\n}',
				CFG
			)
		);
	}

	private inline function triviaWrite(src: String, cfg: String): String {
		return HxWriteFixture.triviaWrite(src, cfg);
	}

}
