package unit;

import utest.Assert;
import utest.Test;

/**
 * The `hasContainerItems` cascade condition — the container half of the
 * `complexItemKinds` array that `complexItemCount >= n` reads the complex half of.
 *
 * The two ask different questions and a bare object literal is exactly where they
 * disagree: `{ UUID: uuid, DeviceTypeId: typeId }` carries no call, so it is NOT
 * complex (and must not become so — `arrayWrap` and the `case`-arm array patterns
 * depend on that counter staying semantic), yet it IS a brace construct, and an
 * argument list that mixes one with a multi-line argument cannot start that argument
 * on the call line and stay readable.
 *
 * Every fixture is a width decision, so the configs below are real `callParameter`
 * cascades rather than compiled defaults. `CONFIG` carries both rules; `CONFIG_NO_CONTAINER`
 * is the same file with the container rule dropped — the opt-in arm that makes the
 * container pair discriminating. `CALL_ARG_SRC` is the control: it explodes under BOTH,
 * because a call argument fires the complex rule that neither config drops.
 */
@:nullSafety(Strict)
final class HxContainerItemWrapTest extends Test {

	/** A `callParameter` cascade carrying both the complex-item rule and the container rule. */
	private static final CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},'
		+ '"wrapping":{"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":['
		+ '{"conditions":[{"cond":"itemCount >= n","value":2},{"cond":"hasMultilineLambdaItems","value":1},{"cond":"complexItemCount >= '
		+ 'n","value":1}],"type":"onePerLine"},{"conditions":[{"cond":"itemCount >= n","value":2},{"cond":"hasMultilineLambdaItems",'
		+ '"value":1},{"cond":"hasContainerItems","value":1}],"type":"onePerLine"},{"conditions":[{"cond":"exceedsMaxLineLength",'
		+ '"value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],'
		+ '"type":"noWrap"}]}},"whitespace":{"bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"}}},'
		+ '"sameLine":{"ifBody":"fitLine","functionBody":"fitLine"},"emptyLines":{"classEmptyLines":{"beginType":1,"endType":1}}}';

	/** `CONFIG` with the `hasContainerItems` rule dropped — the opt-in arm. */
	private static final CONFIG_NO_CONTAINER: String = '{"indentation":{"character":"tab","tabWidth":4},'
		+ '"wrapping":{"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":['
		+ '{"conditions":[{"cond":"itemCount >= n","value":2},{"cond":"hasMultilineLambdaItems","value":1},'
		+ '{"cond":"complexItemCount >= n","value":1}],"type":"onePerLine"},{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],'
		+ '"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],'
		+ '"type":"noWrap"}]}},"whitespace":{"bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"}}},'
		+ '"sameLine":{"ifBody":"fitLine","functionBody":"fitLine"},"emptyLines":{"classEmptyLines":{"beginType":1,"endType":1}}}';

	/** A call-free object literal, a block lambda that breaks, and a one-line lambda. */
	private static final CONTAINER_SRC: String = 'class S1 {\n\n\tprivate function a():Void {\n'
		+ '\t\tapi.post({ UUID: uuid, DeviceTypeId: typeId }, success -> {\n\t\t\ttrace(\'ok\');\n\t\t\tdone();\n'
		+ '\t\t}, error -> trace(error));\n\t}\n\n}';

	/** `CONTAINER_SRC` under `CONFIG` — the container argument sends every argument to its own line. */
	private static final CONTAINER_OUT: String = 'class S1 {\n\n\tprivate function a():Void {\n\t\tapi.post(\n'
		+ '\t\t\t{ UUID: uuid, DeviceTypeId: typeId },\n\t\t\tsuccess -> {\n\t\t\t\ttrace(\'ok\');\n\t\t\t\tdone();\n\t\t\t},\n'
		+ '\t\t\terror -> trace(error)\n\t\t);\n\t}\n\n}';

	/**
	 * A block lambda beside a scalar — no container, no call. The pair with `CONTAINER_SRC` is
	 * what pins the condition on the ARGUMENT KIND rather than on multi-line-ness alone.
	 */
	private static final SCALAR_SRC: String = 'class S2 {\n\n\tprivate function b():Void {\n\t\tTimer.delay(() -> {\n'
		+ '\t\t\ttrace(\'tick\');\n\t\t\tdone();\n\t\t}, 100);\n\t}\n\n}';

	/** A call argument beside a block lambda — the control that fires the complex rule instead. */
	private static final CALL_ARG_SRC: String = 'class S3 {\n\n\tprivate function c():Void {\n\t\tfoo(t(\'Title\'), ok -> {\n'
		+ '\t\t\ttrace(\'call arg\');\n\t\t\tdone();\n\t\t});\n\t}\n\n}';

	/** `CALL_ARG_SRC` under either config. */
	private static final CALL_ARG_OUT: String = 'class S3 {\n\n\tprivate function c():Void {\n\t\tfoo(\n\t\t\tt(\'Title\'),\n'
		+ '\t\t\tok -> {\n\t\t\t\ttrace(\'call arg\');\n\t\t\t\tdone();\n\t\t\t}\n\t\t);\n\t}\n\n}';

	/**
	 * A call whose multi-line element is the COLLECTION rather than a callback — the shape
	 * `shapeMultiArgCollection` hugs to the call head, and the regression that
	 * `hasMultilineItems` caused when it stood where `hasMultilineLambdaItems` stands now:
	 * every argument went one-per-line and the bracket left the head. Both configs must
	 * reproduce the source, and the container rule is live in one of them — a container
	 * argument is present, it is simply not a callback that breaks.
	 */
	private static final COLLECTION_SRC: String = 'class S4 {\n\n\tprivate function d():Void {\n\t\tcol.addItem(new Row([\n'
		+ '\t\t\tnew Label(\'DESKTOP \', getDeviceClassTextFormat(), null, 30),\n\t\t\tnew Label(\'(ALLOWED)\', '
		+ 'getDeviceClassCountTextFormat(), null, 30)\n\t\t], Std.int(_panelWidth), null), false);\n\t}\n\n}';

	/**
	 * The container pair. Dropping the rule leaves the source glued, which is also the proof
	 * that a call-free container does NOT count as complex: the complex rule is still in
	 * `CONFIG_NO_CONTAINER` and does not fire here.
	 */
	public function testContainerArgumentSendsArgumentsOnePerLine(): Void {
		Assert.equals(CONTAINER_SRC, write(CONTAINER_SRC, CONFIG_NO_CONTAINER));
		Assert.equals(CONTAINER_OUT, write(CONTAINER_SRC, CONFIG));
	}

	/** No container and no call — the multi-line argument keeps the glue under both configs. */
	public function testScalarArgumentsKeepTheGlue(): Void {
		Assert.equals(SCALAR_SRC, write(SCALAR_SRC, CONFIG_NO_CONTAINER));
		Assert.equals(SCALAR_SRC, write(SCALAR_SRC, CONFIG));
	}

	/** A call argument fires the complex rule, so the container rule changes nothing here. */
	public function testCallArgumentExplodesUnderBothConfigs(): Void {
		Assert.equals(CALL_ARG_OUT, write(CALL_ARG_SRC, CONFIG_NO_CONTAINER));
		Assert.equals(CALL_ARG_OUT, write(CALL_ARG_SRC, CONFIG));
	}

	/**
	 * The multi-line element is the collection, not a callback — the glue holds and the
	 * source is its own fixed point. This is what `hasMultilineItems` in the rule broke.
	 */
	public function testMultilineCollectionKeepsTheGlue(): Void {
		Assert.equals(COLLECTION_SRC, write(COLLECTION_SRC, CONFIG_NO_CONTAINER));
		Assert.equals(COLLECTION_SRC, write(COLLECTION_SRC, CONFIG));
	}

	/** Every produced layout is a fixed point — a second write reproduces it. */
	public function testLayoutsAreIdempotent(): Void {
		Assert.equals(CONTAINER_OUT, write(CONTAINER_OUT, CONFIG));
		Assert.equals(SCALAR_SRC, write(SCALAR_SRC, CONFIG));
		Assert.equals(CALL_ARG_OUT, write(CALL_ARG_OUT, CONFIG));
		Assert.equals(COLLECTION_SRC, write(COLLECTION_SRC, CONFIG));
	}

	private inline function write(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

}
