package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-comprehension-fit-measure: an over-long `for` / `while` / map array
 * comprehension in a declaration-initializer or assignment-RHS position breaks
 * INSIDE its brackets (`= [` on the head line, generator one indent deeper,
 * `];` back at the head indent) instead of pushing the whole literal onto a
 * continuation line after the `=`.
 *
 * Two defects held that shape back, both fixed here:
 *
 *  1. WIDTH BLINDNESS. Under `sameLine.comprehensionFor: fitLine` the list runs
 *     the `defaultComprehensionWrap` cascade, whose only rule is
 *     `exceedsMaxLineLength` — a pure width question. A filter `if` inside the
 *     generator parks its then-branch behind a `BodyGroup` (`sameLine.ifBody:
 *     fitLine`, reached through `HxIfExpr.thenBranch`'s `noSiblingFallback`),
 *     and every static width measure DEFERS a `BodyGroup` to width 0. The sole
 *     item therefore under-measured, the cascade answered `NoWrap`, and the
 *     overflow was absorbed by whatever inner construct broke first — typically
 *     the filter `if`'s own condition parens. `WrapList.emit` now re-tags the
 *     item's hardline-free `BodyGroup`s as render-identical `Group`s (the
 *     `groupifyInlineBodies` mechanism that already served over-long arrow-`if`
 *     call args), so the cascade sees the width it is asked to weigh.
 *
 *  2. TWO ±1 COLUMN SKEWS AT THE BOUNDARY, each of which let a comprehension
 *     one column past the limit stay put. The bracket's own fit was blind to
 *     the same-line tail after `]` (the statement `;`), so `emit` now routes a
 *     fit-cascade comprehension through `GroupWithRestProbe`. And
 *     `HxVarDecl.init`'s `@:fmt(breakAfterLeadOnOverflow('type'))` gate 1 —
 *     armed by any type-param LHS — resolves that bracket's Group one column
 *     EARLIER than the renderer does (the renderer holds the post-`=`
 *     `OptSpace` pending; the probe spends it), so it broke the `=` where the
 *     renderer would have opened the bracket. A comprehension RHS now disarms
 *     gate 1: its `[` IS its wrap point, which is the documented reason that
 *     probe exists. BOTH arms are load-bearing for the `+1` fixture below —
 *     reverting either one alone turns it red.
 *
 * Boundary contract pinned below: a comprehension whose glued line lands
 * EXACTLY on `maxLineLength` stays flat; one column past it opens the bracket.
 * The same threshold holds for a type-param LHS, a bare-name LHS, a plain
 * assignment and a map comprehension — the four host shapes that used to
 * disagree.
 *
 * The two halves are gated differently on purpose and the fixtures cover both
 * sides: the `emit` half needs `comprehensionBracketsOpen == After` (the fit
 * cascade's own precondition, from `sameLine.comprehensionFor: fitLine`), while
 * the gate-1 disarm is config-independent — a comprehension's bracket is its
 * wrap point under every bracket policy.
 *
 * Identifiers are synthetic; the shapes are anonymised from a real project tree.
 */
@:nullSafety(Strict)
final class HxComprehensionDeclRhsBracketWrapTest extends Test {

	/** Project-shaped config: tab indent, maxLineLength 140, `ifBody`/`comprehensionFor` fitLine, `expressionIf` next, cuddled-open on. */
	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4},'
		+ ' "wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": true},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';

	/** Same, plus the project's `callParameter` cascade — needed by the call-host fixtures, whose hug depends on its `totalItemLength <= 100` rule. */
	private static final CFG_CALL: String = '{"indentation": {"character": "tab", "tabWidth": 4},'
		+ ' "wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": true,'
		+ ' "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"},'
		+ '{"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';

	/** `CFG` without `wrapping.comprehensionCuddledOpen` — the gate-1 disarm is config-independent and must hold here too. */
	private static final CFG_NO_CUDDLE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140},'
		+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';

	public function new(): Void {
		super();
	}

	/** The motivating shape: a typed declaration whose comprehension overflows breaks at the `[`, not after the `=`. */
	public function testOverflowingDeclComprehensionBreaksInsideBrackets(): Void {
		final src: String = 'class Renderer {\n\tprivate function collect():Void {\n'
			+ '\t\tfinal selectedUnits:Array<SceneNode<NodePayload>> = [for (sceneNode in _sceneLayer.sceneNodes) if (sceneNode is UnitBase) sceneNode];'
			+ '\n\t}\n}';
		final expected: String = 'class Renderer {\n\tprivate function collect():Void {\n'
			+ '\t\tfinal selectedUnits:Array<SceneNode<NodePayload>> = [\n'
			+ '\t\t\tfor (sceneNode in _sceneLayer.sceneNodes) if (sceneNode is UnitBase) sceneNode\n\t\t];\n\t}\n}';
		assertWrite(expected, src, CFG);
	}

	/**
	 * A comprehension whose glued line measures EXACTLY `maxLineLength` stays on
	 * one line. NEGATIVE pin — it holds with this slice reverted too; it exists
	 * to state that the fits case (including the padded `[ … ]` inner spacing)
	 * is untouched, not to exercise the re-tag. It DOES bound the new rest
	 * probe from the other side: a probe that over-subtracted would break this
	 * line.
	 */
	public function testComprehensionAtLimitStaysFlat(): Void {
		final src: String = 'class Boundary {\n\tprivate function edge():Void {\n'
			+ '\t\tfinal atLimit:Array<Item> = [for (o in list) if (o is UnitXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX) o];'
			+ '\n\t}\n}';
		final expected: String = 'class Boundary {\n\tprivate function edge():Void {\n'
			+ '\t\tfinal atLimit:Array<Item> = [ for (o in list) if (o is UnitXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX) o ];'
			+ '\n\t}\n}';
		assertWrite(expected, src, CFG);
	}

	/**
	 * One column past `maxLineLength` opens the bracket — the fits+1 side of the
	 * boundary, and the ±1 window both arms of defect 2 had to close. It sits
	 * behind a CHAIN: reverting the `GroupWithRestProbe` arm alone, or the
	 * gate-1 disarm alone, turns it red for different reasons. A reader
	 * bisecting one of them should not read this failure as evidence about the
	 * other.
	 */
	public function testComprehensionOnePastLimitBreaksInsideBrackets(): Void {
		final src: String = 'class Boundary {\n\tprivate function edge():Void {\n'
			+ '\t\tfinal atLimit:Array<Item> = [for (o in list) if (o is UnitXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX) o];'
			+ '\n\t}\n}';
		final expected: String = 'class Boundary {\n\tprivate function edge():Void {\n\t\tfinal atLimit:Array<Item> = [\n'
			+ '\t\t\tfor (o in list) if (o is UnitXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX) o\n\t\t];\n\t}\n}';
		assertWrite(expected, src, CFG);
	}

	/** The same boundary pair with `comprehensionCuddledOpen` absent — the fit cascade and the gate-1 disarm do not depend on that knob. */
	public function testBoundaryHoldsWithoutCuddledOpen(): Void {
		final atLimitSrc: String = 'class NoCuddle {\n\tprivate function edge():Void {\n'
			+ '\t\tfinal atLimit:Array<Item> = [for (o in list) if (o is UnitXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX) o];'
			+ '\n\t}\n}';
		final atLimitOut: String = 'class NoCuddle {\n\tprivate function edge():Void {\n'
			+ '\t\tfinal atLimit:Array<Item> = [ for (o in list) if (o is UnitXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX) o ];'
			+ '\n\t}\n}';
		assertWrite(atLimitOut, atLimitSrc, CFG_NO_CUDDLE);
		final pastSrc: String = 'class NoCuddle {\n\tprivate function edge():Void {\n'
			+ '\t\tfinal atLimit:Array<Item> = [for (o in list) if (o is UnitXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX) o];'
			+ '\n\t}\n}';
		final pastOut: String = 'class NoCuddle {\n\tprivate function edge():Void {\n\t\tfinal atLimit:Array<Item> = [\n'
			+ '\t\t\tfor (o in list) if (o is UnitXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX) o\n\t\t];\n\t}\n}';
		assertWrite(pastOut, pastSrc, CFG_NO_CUDDLE);
	}

	/** Assignment RHS (no declaration, no type hint) takes the same bracket break. */
	public function testAssignmentRhsComprehensionBreaksInsideBrackets(): Void {
		final src: String = 'class Assign {\n\tprivate function run():Void {\n'
			+ '\t\tunitRegistryTable = [for (sceneNode in _sceneLayer.sceneNodes) if (sceneNode is UnitBaseDerivedNameXXXXXXXXXXXXXXXXXXXXXXXXXXXX) sceneNode];'
			+ '\n\t}\n}';
		final expected: String = 'class Assign {\n\tprivate function run():Void {\n\t\tunitRegistryTable = [\n'
			+ '\t\t\tfor (sceneNode in _sceneLayer.sceneNodes) if (sceneNode is UnitBaseDerivedNameXXXXXXXXXXXXXXXXXXXXXXXXXXXX) sceneNode'
			+ '\n\t\t];\n\t}\n}';
		assertWrite(expected, src, CFG);
	}

	/** A map comprehension (`k => v` generator body) is the same list ctor and takes the same shape. */
	public function testMapComprehensionBreaksInsideBrackets(): Void {
		final src: String = 'class Renderer {\n\tprivate function collect():Void {\n'
			+ '\t\tfinal lookupTable:Map<String, SceneNode> = [for (sceneNode in _sceneLayer.sceneNodes) if (sceneNode is UnitBase) sceneNode.key => sceneNode];'
			+ '\n\t}\n}';
		final expected: String = 'class Renderer {\n\tprivate function collect():Void {\n\t\tfinal lookupTable:Map<String, SceneNode> = [\n'
			+ '\t\t\tfor (sceneNode in _sceneLayer.sceneNodes) if (sceneNode is UnitBase) sceneNode.key => sceneNode\n\t\t];\n\t}\n}';
		assertWrite(expected, src, CFG);
	}

	/**
	 * The `while` generator form shares the comprehension classification and the
	 * same bracket break. Carries a filter `if` on purpose: the first draft of
	 * this fixture had none, and it PASSED with the whole slice reverted —
	 * without a filter there is no `BodyGroup` to park the body behind, so no
	 * width was ever lost and only the (config-independent) gate-1 disarm would
	 * have been under test.
	 */
	public function testWhileComprehensionBreaksInsideBrackets(): Void {
		final src: String = 'class Whiles {\n\tprivate function run():Void {\n'
			+ '\t\tfinal drainedNodes:Array<SceneNode<NodePayload>> = [while (_pendingQueue.hasNext()) if (_pendingQueue.peekIsReady()) _pendingQueue.takeNext()];'
			+ '\n\t}\n}';
		final expected: String = 'class Whiles {\n\tprivate function run():Void {\n\t\tfinal drainedNodes:Array<SceneNode<NodePayload>> = ['
			+ '\n\t\t\twhile (_pendingQueue.hasNext()) if (_pendingQueue.peekIsReady()) _pendingQueue.takeNext()\n\t\t];' + '\n' + '\t}'
			+ '\n' + '}';
		assertWrite(expected, src, CFG);
	}

	/** A generator that STILL overflows on its own line keeps the opened bracket and lets the existing inner wrap take the rest. */
	public function testInnerOverflowKeepsOpenBracketAndWrapsBody(): Void {
		final src: String = 'class Inner {\n\tprivate function run():Void {\n'
			+ '\t\tfinal removedPaths:Array<String> = [for (entry in pendingEntries) if (entry.state == REMOVED && entry.path.startsWith(Const.SHARED_ROOT_PREFIX_WITH_TRAILING_SLASH)) entry.path];'
			+ '\n\t}\n}';
		final expected: String = 'class Inner {\n\tprivate function run():Void {\n\t\tfinal removedPaths:Array<String> = [\n'
			+ '\t\t\tfor (entry in pendingEntries) if (entry.state == REMOVED && entry.path.startsWith(Const.SHARED_ROOT_PREFIX_WITH_TRAILING_SLASH))'
			+ '\n\t\t\t\tentry.path\n\t\t];\n\t}\n}';
		assertWrite(expected, src, CFG_CALL);
	}

	/** A call whose sole arg is an over-long comprehension keeps the call hugged and opens only the bracket. */
	public function testCallArgComprehensionHugsTheCallAndOpensBracket(): Void {
		final src: String = 'class CallHost {\n\tprivate function run(payload:NodePayload, nodes:Array<SceneNode<NodePayload>>):Void {\n'
			+ '\t\tdispatchNodeUpdate([for (sceneNode in nodes) if (payload.kind == sceneNode.kind) new UpdateNodePropsCommand(this, cast sceneNode, payload)]);'
			+ '\n\t}\n}';
		final expected: String = 'class CallHost {\n\tprivate function run(payload:NodePayload, nodes:Array<SceneNode<NodePayload>>):Void {'
			+ '\n\t\tdispatchNodeUpdate([\n'
			+ '\t\t\tfor (sceneNode in nodes) if (payload.kind == sceneNode.kind) new UpdateNodePropsCommand(this, cast sceneNode, payload)'
			+ '\n' + '\t\t]);' + '\n' + '\t}' + '\n' + '}';
		assertWrite(expected, src, CFG_CALL);
	}

	/**
	 * The `flatLength(item) >= 0` half of the re-tag gate. This comprehension's
	 * item already FORCES a hardline, so the array is committed to break either
	 * way and the re-tag would decide nothing — it would only leak the
	 * newly-visible width out to the enclosing call's `totalItemLength` rule and
	 * open a paren that used to hug. Byte-identical round-trip is the contract.
	 */
	public function testAlreadyBrokenItemKeepsCuddledShapeAndCallHug(): Void {
		final src: String = 'class NodeHost {\n'
			+ '\tprivate function updateNodeLabels(payload:NodePayload, nodes:Array<SceneNode<NodePayload>>):Void {\n'
			+ '\t\tswitch payload.kind {\n\t\t\tcase UnitPayload.KIND_KEEPER, UnitPayload.KIND_FIELD, UnitPayload.KIND_BENCH:\n'
			+ '\t\t\t\tdispatchNodeUpdate([ for (sceneNode in nodes)\n'
			+ '\t\t\t\t\tif (payload.kind == sceneNode.kind) new UpdateNodePropsCommand(this, cast sceneNode, payload)\n'
			+ '\t\t\t\t]);\n\t\t\tcase _:\n\t\t}\n\t}\n}';
		assertWrite(src, src, CFG_CALL);
	}

	/** Writes `src` under `cfg`, asserts it equals `expected`, and asserts the result is a fixed point. */
	private function assertWrite(expected: String, src: String, cfg: String): Void {
		final out: String = triviaWrite(src, cfg);
		Assert.equals(expected, out);
		Assert.equals(out, triviaWrite(out, cfg));
	}

	private inline function triviaWrite(src: String, cfg: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
