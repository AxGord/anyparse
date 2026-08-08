package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-fitline-body-glue: `sameLine.fitLineBodyGlue` lets a construct-group `FitLine` body that the next line would
 * NOT rescue stay GLUED to its header line and break inside itself, instead of always moving one line down and one
 * indent deeper.
 *
 * The discriminator is the continuation indent, not the header width: `BodyFit.continuationRescuesBody` asks whether
 * the body's flat width fits `cols` deeper than the header. It does - the body earns its own line, exactly as with the
 * knob off, and `testRescuedBodyStillTakesItsOwnLine` fails first if that half is dropped. It does not - no line saves
 * the body, so gluing costs nothing and saves a line plus an indent level.
 *
 * Every fixture is asserted on BOTH knob states off one config pair that differs in nothing else, so a diff is
 * attributable to the knob rather than to a second config key.
 */
@:nullSafety(Strict)
final class HxFitLineBodyGlueSliceTest extends Test {

	/** project-shaped config with the knob ON. */
	private static final GLUE_ON: String = config(true);

	/** The same config with the knob OFF - the haxe-formatter layout the corpus pins. */
	private static final GLUE_OFF: String = config(false);

	/** The reported site: a comprehension filter body wrapping its object literal in parens, body below the `if`. */
	private static final COMPREHENSION_BELOW: String = 'class SampleContainer {\n'
		+ '\tpublic function collectRemaining(knownItems:SampleEntryBundles):SampleEntryBundles {\n' + '\t\treturn {\n'
		+ '\t\t\tfirst: [ for (item in _owner.PrimaryList)\n'
		+ '\t\t\t\tif (!knownItems.first.exists((u:SamplePrimaryEntryKind) -> u.email == item.Email))\n' + '\t\t\t\t\t({\n'
		+ '\t\t\t\t\t\talphaName: item.AlphaName,\n' + '\t\t\t\t\t\tbetaName: item.BetaName,\n' + '\t\t\t\t\t\tid: item.ItemId,\n'
		+ '\t\t\t\t\t\temail: item.Email,\n' + '\t\t\t\t\t\taccess: VIEW,\n' + '\t\t\t\t\t\timage: item.Image\n' + '\t\t\t\t\t})\n'
		+ '\t\t\t]\n' + '\t\t};\n' + '\t}\n' + '}';

	/** The same comprehension with the body glued to the `if` head - one line and one indent level cheaper. */
	private static final COMPREHENSION_GLUED: String = 'class SampleContainer {\n'
		+ '\tpublic function collectRemaining(knownItems:SampleEntryBundles):SampleEntryBundles {\n' + '\t\treturn {\n'
		+ '\t\t\tfirst: [ for (item in _owner.PrimaryList)\n'
		+ '\t\t\t\tif (!knownItems.first.exists((u:SamplePrimaryEntryKind) -> u.email == item.Email)) ({\n'
		+ '\t\t\t\t\talphaName: item.AlphaName, betaName: item.BetaName, id: item.ItemId, email: item.Email, access: VIEW, image: item.Image\n'
		+ '\t\t\t\t})\n' + '\t\t\t]\n' + '\t\t};\n' + '\t}\n' + '}';

	/** A sibling filter body that DOES fit one line deeper - the population the knob must leave alone. */
	private static final RESCUED_BODY: String = 'class SampleContainer {\n'
		+ '\tpublic function collectRemaining(knownItems:SampleEntryBundles):SampleEntryBundles {\n' + '\t\treturn {\n'
		+ '\t\t\tsecond: [ for (item in _owner.SecondaryItems)\n'
		+ '\t\t\t\tif (!knownItems.second.exists((u:SampleSecondEntryKinds) -> u.email == item.Email))\n'
		+ '\t\t\t\t\t({ id: 0, email: item.Email, access: VIEW, extraFlag: false })\n' + '\t\t\t]\n' + '\t\t};\n' + '\t}\n' + '}';

	/** An `if` whose body is a call the next line cannot rescue either - the call paren cuddles to the head. */
	private static final CALL_BODY_BELOW: String = 'class C {\n' + '\tfunction test() {\n' + '\t\tif (needsUpdate)\n'
		+ '\t\t\tattachCollectedLabel(\n'
		+ '\t\t\t\tdefaultPreviewSurface, \'$$count items\', StyleTokens.SECONDARY_MARK_COLOR, Metrics.GRID_SECOND_LABEL_X_OFFSET\n'
		+ '\t\t\t);\n' + '\t}\n' + '}';

	/** The same call glued to the `if` head. */
	private static final CALL_BODY_GLUED: String = 'class C {\n' + '\tfunction test() {\n' + '\t\tif (needsUpdate) attachCollectedLabel(\n'
		+ '\t\t\tdefaultPreviewSurface, \'$$count items\', StyleTokens.SECONDARY_MARK_COLOR, Metrics.GRID_SECOND_LABEL_X_OFFSET\n'
		+ '\t\t);\n' + '\t}\n' + '}';

	/** An arrow-lambda body the next line cannot rescue either, written below its `->`. */
	private static final ARROW_BODY_BELOW: String = 'class C {\n' + '\tfunction test() {\n'
		+ '\t\t_entryList.dataSource = sourceModel.entryViewModels.map(model ->\n' + '\t\t\t({\n'
		+ '\t\t\t\tlabel: model.entryData != null ? model.entryData.name : throw new Exception(\'Entry data not set\'),\n'
		+ '\t\t\t\tpath: model.path,\n' + '\t\t\t\treadonly: model.readonly\n' + '\t\t\t})\n' + '\t\t);\n' + '\t}\n' + '}';

	/** The same lambda with its body glued after the `->` — two lines and one indent level cheaper. */
	private static final ARROW_BODY_GLUED: String = 'class C {\n' + '\tfunction test() {\n'
		+ '\t\t_entryList.dataSource = sourceModel.entryViewModels.map(model -> ({\n'
		+ '\t\t\tlabel: model.entryData != null ? model.entryData.name : throw new Exception(\'Entry data not set\'),\n'
		+ '\t\t\tpath: model.path,\n' + '\t\t\treadonly: model.readonly\n' + '\t\t}));\n' + '\t}\n' + '}';

	/** A short arrow body that fits on the header line — the knob must not touch it. */
	private static final ARROW_BODY_FLAT: String = 'class C {\n' + '\tfunction test() {\n'
		+ '\t\t_entryList.dataSource = models.map(model -> ({ label: model.name, path: model.path, readonly: model.readonly }));\n'
		+ '\t}\n' + '}';

	/**
	 * An arrow body that is NOT an expression paren — an `if` expression the continuation does not rescue either. The
	 * arrow glue is scoped to paren bodies, so this one keeps its own line.
	 */
	private static final ARROW_IF_BODY: String = 'class C {\n' + '\tfunction test() {\n' + '\t\titemData.forEachChild(\n'
		+ '\t\t\tchild -> if (updateFlags(dfs, child, itemOldPath + child.nodePath.substr(child.nodePath.lastIndexOf(\'/\')))) updated = true\n'
		+ '\t\t);\n' + '\t}\n' + '}';

	/**
	 * An expression paren in OPERAND position — third operand of an `||` chain, too wide to stay on the chain's
	 * continuation line. It OPENS, and must keep opening under the knob.
	 */
	private static final CHAIN_OPERAND_PAREN: String = 'class C {\n' + '\tfunction test() {\n'
		+ '\t\tfinal mayModify:Bool = _source.viewKind == ViewKindConstant.LIST || chosenRoot == null || (\n'
		+ '\t\t\tchosenRoot != null && currentSelection.nodePath.startsWith(chosenRoot) && currentSelection.nodePath.length > chosenRoot.length\n'
		+ '\t\t);\n' + '\t}\n' + '}';

	public function new(): Void {
		super();
	}

	/** The reported site glues its `({` to the `if` head under the knob. */
	public function testComprehensionFilterBodyGluesToTheIfHead(): Void {
		Assert.equals(COMPREHENSION_GLUED, triviaWrite(COMPREHENSION_BELOW, GLUE_ON));
	}

	/** Knob OFF keeps the body below its head - the discriminator against the change leaking into the default. */
	public function testKnobOffKeepsTheBodyBelowItsHead(): Void {
		Assert.equals(COMPREHENSION_BELOW, triviaWrite(COMPREHENSION_BELOW, GLUE_OFF));
	}

	/** The glued layout is a fixed point - a second write neither re-breaks it nor packs it further. */
	public function testGluedBodyIsIdempotent(): Void {
		Assert.equals(COMPREHENSION_GLUED, triviaWrite(COMPREHENSION_GLUED, GLUE_ON));
	}

	/**
	 * A body that FITS at the continuation indent still takes its own line, knob or no knob. This is the half
	 * `continuationRescuesBody` adds over a bare glue-width probe: measured on the header line alone the body's first
	 * line fits (the paren opens, so that line is two columns), and the glue would cost a third line for a shape that
	 * renders in two.
	 */
	public function testRescuedBodyStillTakesItsOwnLine(): Void {
		Assert.equals(RESCUED_BODY, triviaWrite(RESCUED_BODY, GLUE_ON));
		Assert.equals(RESCUED_BODY, triviaWrite(RESCUED_BODY, GLUE_OFF));
	}

	/** The glue is not object-literal-specific: a call body the next line cannot rescue cuddles its open paren too. */
	public function testCallBodyCuddlesItsOpenParen(): Void {
		Assert.equals(CALL_BODY_GLUED, triviaWrite(CALL_BODY_BELOW, GLUE_ON));
		Assert.equals(CALL_BODY_BELOW, triviaWrite(CALL_BODY_BELOW, GLUE_OFF));
	}

	/** The arrow-lambda body takes the same answer as a construct body — it is the other after-the-header placement. */
	public function testArrowLambdaBodyGluesAfterTheArrow(): Void {
		Assert.equals(ARROW_BODY_GLUED, triviaWrite(ARROW_BODY_BELOW, GLUE_ON));
		Assert.equals(ARROW_BODY_GLUED, triviaWrite(ARROW_BODY_GLUED, GLUE_ON));
	}

	/** Knob OFF keeps the arrow body below its `->`, and normalises the glued input back down. */
	public function testKnobOffKeepsTheArrowBodyBelow(): Void {
		Assert.equals(ARROW_BODY_BELOW, triviaWrite(ARROW_BODY_BELOW, GLUE_OFF));
		Assert.equals(ARROW_BODY_BELOW, triviaWrite(ARROW_BODY_GLUED, GLUE_OFF));
	}

	/**
	 * The arrow glue is KIND-scoped, not just width-scoped: an `if`-expression body the continuation cannot rescue
	 * either still takes its own line. Widened to every arrow body, this fixture glues the `if` head and then explodes
	 * its own condition at the deeper column — which is what the real-tree measurement showed and what this pins.
	 */
	public function testNonParenArrowBodyKeepsItsOwnLine(): Void {
		Assert.equals(ARROW_IF_BODY, triviaWrite(ARROW_IF_BODY, GLUE_ON));
		Assert.equals(ARROW_IF_BODY, triviaWrite(ARROW_IF_BODY, GLUE_OFF));
	}

	/** A lambda body that already fits beside its `->` is untouched by either knob state. */
	public function testShortArrowBodyIsUntouched(): Void {
		Assert.equals(ARROW_BODY_FLAT, triviaWrite(ARROW_BODY_FLAT, GLUE_ON));
		Assert.equals(ARROW_BODY_FLAT, triviaWrite(ARROW_BODY_FLAT, GLUE_OFF));
	}

	/**
	 * The paren pin is POSITION-scoped: it applies to a body committed to a header line, never to an expression paren
	 * that is an operand of a chain. This fixture is what the shared paren-open gate decides, and a pin implemented as a
	 * stricter gate there (rather than at the glue site) collapses it into a ragged `|| (a && b` / `&& c` split.
	 */
	public function testChainOperandParenStillOpens(): Void {
		Assert.equals(CHAIN_OPERAND_PAREN, triviaWrite(CHAIN_OPERAND_PAREN, GLUE_ON));
		Assert.equals(CHAIN_OPERAND_PAREN, triviaWrite(CHAIN_OPERAND_PAREN, GLUE_OFF));
	}

	private inline function triviaWrite(src: String, config: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

	/** project-shaped config parameterised on the one key under test. */
	private static function config(glue: Bool): String {
		return '{"indentation": {"character": "tab", "tabWidth": 4},'
			+ ' "wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": true,'
			+ ' "objectLiteral": {"defaultWrap": "ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "packedOrOnePerLine"}]},'
			+ ' "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]},'
			+ ' "opBoolChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "itemCount <= n", "value": 3}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "totalItemLength <= n", "value": 120}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]},'
			+ ' "expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}},'
			+ ' "whitespace": {"bracesConfig": {"objectLiteralBraces": {"openingPolicy": "after", "closingPolicy": "before"}}},'
			+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine", "fitLineBodyGlue": ' + glue + '}}';
	}

}
