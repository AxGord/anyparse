package unit.format;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.query.CanonicalEdit;
import anyparse.query.FormatFixedPoint;
import utest.Assert;
import utest.Test;

/**
 * ω-flat-source-fixed-point — ONE writer round trip must land where every
 * further round trip leaves the file.
 *
 * A sep-Star without `@:fmt(reflowSourceMultiline)` force-one-per-lines any
 * list whose SOURCE carried a newline, without consulting the wrap cascade.
 * For a source-FLAT list the cascade IS consulted, and when it answers a
 * break mode other than `OnePerLine` the newline pass 1 writes is read by
 * pass 2 as author intent and overridden. `fmt` then needs two rewrites, and
 * `writeRoundTrip(s) == s` — the canonical gate every writer-emit mutation op
 * is built on — fails after one pass.
 *
 * On the Pony tree under its own `hxformat.json` every file that took two
 * rewrites did so on the inline anon type hint of
 * `testAnonTypeFillLineOnOverflow`. haxe-formatter reproduces both passes
 * byte-for-byte on the same
 * config, so the shape is inherited from the fork's
 * `MarkWrapping.anonTypeWrapping` (`!isOriginalSameLine` →
 * `wrapChildOneLineEach`) rather than an anyparse regression — but the fork
 * ships no canonical gate, and anyparse does.
 *
 * Each fixture pins the SHAPE as well as the convergence: `once == twice`
 * alone would also hold for a writer that reflowed nothing.
 */
@:nullSafety(Strict)
class WrapFlatSourceFixedPointTest extends Test {

	/**
	 * Pony's own `anonType` cascade, reduced: everything short stays flat, an
	 * overflowing hint takes `fillLine`. `fillLine` breaks BETWEEN fields
	 * without breaking after `{`, which is not a shape the force-multi path
	 * can reproduce — hence the second rewrite.
	 */
	private static final ANON_FILL_LINE: String = '{"wrapping": {"maxLineLength": 40, "anonType": {"defaultWrap": "noWrap", "rules": ['
		+ '{"conditions": [{"cond": "itemCount <= n", "value": 3}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine"}]}}}';

	/**
	 * The widest instance — a large share of Pony's files under this one
	 * value. `fillLineWithLeadingBreak` breaks after `{` and then PACKS, so
	 * pass 1 writes `x: 1, y: 2` on one continuation line and pass 2 splits
	 * it.
	 */
	private static final OBJECT_LEADING_BREAK: String =
		'{"wrapping": {"objectLiteral": {"defaultWrap": "fillLineWithLeadingBreak", "rules": []}}}';

	/**
	 * A bare `fillLine` cascade with no rules: the mode is the cascade's
	 * answer in BOTH the fits and the overflows state. Guards the half of the
	 * fix that must NOT fire — see `testShortListUnderFillLineStaysFlat`.
	 */
	private static final ANON_BARE_FILL_LINE: String =
		'{"wrapping": {"maxLineLength": 100, "anonType": {"defaultWrap": "fillLine", "rules": []}}}';

	/**
	 * Pony's own `objectLiteral` cascade paired with its `callParameter` one.
	 * The literal is short enough for the `noWrap` rule, which SHADOWS a
	 * breaking `defaultWrap` — so the cascade agree-path hands the host an
	 * `IfFirstLineExceeds` pivot instead of a committed mode, and the pivot's
	 * flat arm carries no hardline for the host to measure.
	 */
	private static final CALL_ARG_OBJECT: String = '{"wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": '
		+ '"onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}, '
		+ '"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": '
		+ '"exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';

	/**
	 * The same literal cascade under a `callParameter` one whose BREAK mode is
	 * also its FITS answer — a rules-free `fillLine`, so nothing above the glue
	 * intercept ever refused the flat line.
	 */
	private static final CALL_ARG_FILL_LINE: String = '{"wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": '
		+ '"onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}, '
		+ '"callParameter": {"defaultWrap": "fillLine", "rules": []}}}';

	/**
	 * Pony's OWN `objectLiteral` cascade — `defaultWrap: ignore` plus a single
	 * `exceedsMaxLineLength → onePerLine` rule. The two cascade runs DISAGREE, so
	 * the literal reaches its host as `Group(IfBreak(brk, flat))`: a break the
	 * renderer decides by FIT, not by an `IfFirstLineExceeds` threshold. That is
	 * the pivot shape `pivotBreakArm` did not recognise, which is why every
	 * compact `f(a, {` … `});` hug was unreachable under this config.
	 */
	private static final CALL_ARG_EXCEEDS_OBJECT: String = '{"wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": '
		+ '"ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "onePerLine"}]}, '
		+ '"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": '
		+ '"exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, '
		+ '{"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}}';

	/**
	 * A Tactics Manager cascade, reduced: `arrayWrap` left to its two
	 * `exceedsMaxLineLength` runs — which resolve to `Group(IfBreak(…))`, the fit
	 * pivot — under the same leading-break `callParameter` the object fixtures use.
	 * Its fixture puts the array FIRST of four arguments, the position the fit
	 * pivot used to decline.
	 */
	private static final CALL_ARG_EXCEEDS_ARRAY: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": '
		+ '{"maxLineLength": 140, "arrayWrap": {"defaultWrap": "ignore", "rules": [{"conditions": [{"cond": '
		+ '"exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", '
		+ '"value": 1}], "type": "packedOrOnePerLine"}]}, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", '
		+ '"rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';

	/**
	 * The exceeds cascade for object literals beside a THRESHOLD one for arrays
	 * (`onePerLine` shadowed by a `totalItemLength <= 140` `noWrap`, the shape
	 * that emits `IfFirstLineExceeds`). One call, two collection arguments, one
	 * pivot of each kind — the population where widening the pivot scan in place
	 * would DE-NOMINATE the earlier arg instead of nominating the later one.
	 */
	private static final TWO_COLLECTION_ARGS: String = '{"wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": '
		+ '"ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "onePerLine"}]}, '
		+ '"arrayWrap": {"defaultWrap": "onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", '
		+ '"value": 140}], "type": "noWrap"}]}, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": '
		+ '[{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": '
		+ '"itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}}';

	/**
	 * The reduced form of THIS project's own `hxformat.json` `callParameter`
	 * cascade — `fillLineWithLeadingBreak` shadowed by an `exceedsMaxLineLength:
	 * 0` and an `itemCount <= 1 && totalItemLength <= 100` `noWrap`. The object
	 * literal is deliberately left UNCONFIGURED, so it resolves through
	 * `HaxeFormat.defaultObjectLiteralWrap`, whose `totalItemLength >= 60` rule
	 * commits it to `OnePerLine` in BOTH fit states. That commitment is the
	 * fixture's whole point.
	 */
	private static final CALL_ARG_COMMITTED_OBJECT: String = '{"wrapping": {"maxLineLength": 140, "callParameter": '
		+ '{"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", '
		+ '"value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": '
		+ '"totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}}';

	/** The same literal cascade under a ternary host instead of a call host. */
	private static final TERNARY_ARG_OBJECT: String = '{"wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": '
		+ '"onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}, '
		+ '"ternaryExpression": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", '
		+ '"value": 1}], "type": "onePerLineAfterFirst", "location": "beforeLast"}]}}}';

	/**
	 * The case-body source behind `tools/src/module/Unpack.hx`, reduced. ONE copy,
	 * because FOUR tests read it and they must not drift apart: the tail pin
	 * asserts it still takes two writer rewrites, the mechanism split re-reads it
	 * under a committed cascade, and `testCanonicalizeWritesTheWriterFixedPoint` is
	 * only a regression test for as long as the first of those holds.
	 * (`unit.query.NewFileSliceTest` needs its own copy — a different class — and carries
	 * a local precondition instead.)
	 */
	private static final CASE_BODY_SRC: String = 'class C {\n\tfunction readNode(xml: Fast): Void {\n'
		+ '\t\tswitch xml.name {\n\t\t\tcase \'zip\':\n\t\t\t\tcfg.zips.push({ path: try '
		+ 'StringTools.trim(xml.innerData) catch (_: Any) \'\', file: xml.att.file, rm: xml.isTrue(\'rm\'), '
		+ 'log: !xml.isFalse(\'log\') });\n\t\t\tcase _:\n\t\t\t\tsuper.readNode(xml);\n\t\t}\n\t}\n}';

	/**
	 * Pony's own `objectLiteral` cascade under a `sameLine.caseBody: fitLine`
	 * switch — the host is `BodyFit.fitLineLayout`, which asks
	 * `WrapList.flatLength` whether the body can render on one line at all.
	 */
	private static final CASE_BODY_OBJECT: String = '{"indentation": {"character": "tab", "tabWidth": 4, '
		+ '"alignInlineSwitchCaseBody": true}, "sameLine": {"caseBody": "fitLine", "expressionCase": "fitLine"}, '
		+ '"wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": "onePerLine", "rules": [{"conditions": '
		+ '[{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}}}';

	/**
	 * The same literal cascade with an `arrayWrap` one beside it, under a
	 * value-`if` host. The pivot sits under the literal's own ARRAY item, so
	 * every enclosing measure reads it two levels down.
	 */
	private static final VALUE_IF_NESTED: String = '{"indentation": {"character": "tab", "tabWidth": 4}, '
		+ '"sameLine": {"ifBody": "fitLine", "expressionIf": "next"}, "wrapping": {"maxLineLength": 140, '
		+ '"objectLiteral": {"defaultWrap": "onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", '
		+ '"value": 140}], "type": "noWrap"}]}, "arrayWrap": {"defaultWrap": "noWrap", "rules": [{"conditions": '
		+ '[{"cond": "hasMultilineItems", "value": 1}], "type": "onePerLine"}, {"conditions": [{"cond": '
		+ '"totalItemLength <= n", "value": 80}], "type": "noWrap"}, {"conditions": [{"cond": "anyItemLength >= n", '
		+ '"value": 30}], "type": "onePerLine"}]}}}';

	/**
	 * A sole-argument call whose argument is a TERNARY whose branches are the
	 * pivot-bearing literals — the pivot is two levels below the call.
	 *
	 * Its `callParameter` cascade is this project's own, so it serves a SECOND
	 * reader unchanged: `testMultiArgFillPacksACommittedBodyOnPassTwo`'s control
	 * arm, over `MULTI_ARG_FILL_SRC`. One copy rather than two identical ones, for
	 * the reason `CASE_BODY_SRC` gives about sources.
	 */
	private static final CALL_TERNARY_NESTED: String = '{"indentation": {"character": "tab", "tabWidth": 4}, '
		+ '"wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": "onePerLine", "rules": [{"conditions": '
		+ '[{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}, "callParameter": {"defaultWrap": '
		+ '"fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], '
		+ '"type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", '
		+ '"value": 100}], "type": "noWrap"}]}}}';

	/**
	 * Pony's `objectLiteral` + `callParameter` cascades beside the
	 * `anonFunctionSignature` one that makes a lambda argument's own signature
	 * wrap — the pair behind `tools/nodesrc/module/Bmfont.hx` and
	 * `src/pony/ui/xml/PixiXmlUi.hx`.
	 */
	private static final COMMITTED_BODY_PREFIX: String = '{"indentation": {"character": "tab", "tabWidth": 4}, '
		+ '"wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": "onePerLine", "rules": [{"conditions": '
		+ '[{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}, "callParameter": {"defaultWrap": '
		+ '"fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], '
		+ '"type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", '
		+ '"value": 100}], "type": "noWrap"}]}, "anonFunctionSignature": {"defaultWrap": "noWrap", "rules": '
		+ '[{"conditions": [{"cond": "totalItemLength >= n", "value": 80}], "type": "fillLine"}]}, '
		+ '"ternaryExpression": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", '
		+ '"value": 1}], "type": "onePerLineAfterFirst", "location": "beforeLast"}]}}}';

	/**
	 * `CASE_BODY_OBJECT` with the literal cascade's `noWrap` SHADOW removed. A
	 * rules-free cascade answers the same mode in BOTH fit states, so it can emit
	 * no pivot at all — which is the whole discriminator between the tail's two
	 * mechanisms.
	 */
	private static final CASE_BODY_COMMITTED: String = '{"indentation": {"character": "tab", "tabWidth": 4, "alignInlineSwitchCaseBody": tr'
		+ 'ue}, "sameLine": {"caseBody": "fitLine", "expressionCase": "fitLine"}, "wrapping": {"maxLineLength": 140, "objectLiteral": {"def'
		+ 'aultWrap": "onePerLine", "rules": []}}}';

	/**
	 * `VALUE_IF_NESTED` with the same shadow removed, its `arrayWrap` cascade
	 * left exactly as it was so the only variable is the literal's.
	 */
	private static final VALUE_IF_COMMITTED: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "sameLine": {"ifBody": "fitLine'
		+ '", "expressionIf": "next"}, "wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": "onePerLine", "rules": []}, "arr'
		+ 'ayWrap": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "hasMultilineItems", "value": 1}], "type": "onePerLine"}, '
		+ '{"conditions": [{"cond": "totalItemLength <= n", "value": 80}], "type": "noWrap"}, {"conditions": [{"cond": "anyItemLength >= n"'
		+ ', "value": 30}], "type": "onePerLine"}]}}}';

	/**
	 * `CALL_TERNARY_NESTED` with the same shadow removed. This is the one of the
	 * three that KEEPS diverging under it — which is what places it in mechanism
	 * B rather than beside its two siblings.
	 *
	 * Second reader, same one-copy rule as its pivot twin above:
	 * `testMultiArgFillPacksACommittedBodyOnPassTwo`'s committed arm.
	 */
	private static final CALL_TERNARY_COMMITTED: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength'
		+ '": 140, "objectLiteral": {"defaultWrap": "onePerLine", "rules": []}, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak"'
		+ ', "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCoun'
		+ 't <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}}';

	/**
	 * The two mechanisms STACKED: a rules-free `fillLine` array cascade
	 * (mechanism B, committed either way) inside a literal cascade that still
	 * carries its `totalItemLength <= 140` shadow (mechanism A, a pivot).
	 * `rules: []` is load-bearing — `defaultWrap: fillLine` alone leaves Pony's
	 * shipped `arrayWrap` rules shadowing it, and `tools/src/create/ides/VSCode.hx`
	 * then converges in one.
	 */
	private static final STACKED_ARRAY_PIVOT: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": '
		+ '140, "objectLiteral": {"defaultWrap": "onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 140}], "'
		+ 'type": "noWrap"}]}, "arrayWrap": {"defaultWrap": "fillLine", "rules": []}}}';

	/**
	 * The same pair with the literal cascade committed: one link of the chain is
	 * gone and the source settles one pass earlier.
	 */
	private static final STACKED_ARRAY_COMMITTED: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLengt'
		+ 'h": 140, "objectLiteral": {"defaultWrap": "onePerLine", "rules": []}, "arrayWrap": {"defaultWrap": "fillLine", "rules": []}}}';

	/**
	 * `tools/src/create/ides/VSCode.hx`'s `createElectron`, reduced: an object
	 * literal whose second field is an array of two parenthesised type-checks.
	 * The array is the mechanism-B link, the enclosing literal the mechanism-A one.
	 */
	private static final STACKED_SRC: String = 'class A {\n\tpublic static function createElectron(output: String): Void {\n\t\tfinal data '
		+ '= { version: \'0.2.0\', configurations: [\n\t\t\t({ type: \'node\', request: \'launch\', name: mainConfName, protocol: \'inspect'
		+ 'or\', runtimeExecutable: electronExecutable, runtimeArgs: [output, \'--remote-debugging-port\'], windows: { runtimeExecutable: e'
		+ 'lectronExecutable\n\t\t\t\t+ \'.cmd\' }, preLaunchTask: PRELAUNCH_TASK, internalConsoleOptions: \'neverOpen\' }: Dynamic),\n\t\t'
		+ '\t({ name: renderConfName, type: \'chrome\', request: \'attach\', port: port, webRoot: resultDir, timeout: 20000, internalConsol'
		+ 'eOptions: \'openOnSessionStart\' }: Dynamic)\n\t\t], compounds: [{ name: \'AllConfigurations\', configurations: [mainConfName, r'
		+ 'enderConfName] }] };\n\t\tUtils.saveJson(\'.vscode/launch.json\', data);\n\t}\n}';

	/**
	 * `src/anyparse/query/Cli.hx`'s `limitEntries(...)` call, reduced: four
	 * arguments whose last is a lambda returning an object literal.
	 */
	private static final MULTI_ARG_FILL_SRC: String = 'class A {\n\tfunction f(): Void {\n\t\tfinal shown: Array<{ file: String, source: St'
		+ 'ring, hits: Array<RefHit> }> = limitEntries(\n\t\t\tallEntries, cappedLimit, e -> e.hits.length, (e, k) -> {file: e.file, source'
		+ ': e.source, hits: e.hits.slice(0, k) }\n\t\t);\n\t}\n}';

	/**
	 * The value-`if` branch behind `src/pony/magic/builder/DIBuilder.hx`, reduced.
	 * ONE copy for the same reason `CASE_BODY_SRC` gives: two tests read it — the
	 * tail pin and the mechanism split — and they must not drift apart.
	 */
	private static final VALUE_IF_SRC: String = 'class C {\n\tfunction f(): Void {\n\t\tfinal v = if (staticDIVar != null)\n\t\t\t{ expr: E'
		+ 'Vars([\n\t\t\t\t{ name: staticDIVar.varName, type: TPath({ pack: [], name: \'Null\', params: [TPType(t)] }), expr: macro null, i'
		+ 'sFinal: false }\n\t\t\t]), pos: Context.currentPos() }\n\t\telse\n\t\t\tcheckExpr(x);\n\t}\n}';

	/**
	 * The ternary-under-a-sole-argument-call behind
	 * `src/pony/magic/builder/HasSignalBuilder.hx`, reduced. Same one-copy rule.
	 */
	private static final CALL_TERNARY_SRC: String = 'class C {\n\tfunction f(): Void {\n\t\tfields.push({\n\t\t\tname: setterName,\n\t\t\ta'
		+ 'ccess: ast.concat([AInline, setterAccess]),\n\t\t\tmeta: null,\n\t\t\tpos: f.pos,\n\t\t\tkind: FFun(setcontroll ? { args: [{ nam'
		+ 'e: \'v\', type: null }], ret: null, expr: macro return evName == null || v != fName && !evName.dispatchWithFlag(v, fName, notsav'
		+ 'e) ? fName = v : fName } : { args: [{ name: \'v\', type: null }], ret: null, expr: macro { if (evName == null) { var prev = fNam'
		+ 'e; } return fName; } })\n\t\t});\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** The Pony repro: an inline anon type hint whose line overflows. */
	public function testAnonTypeFillLineOnOverflow(): Void {
		final once: String = write(
			'class C {\n\tfunction f(): Void {\n\t\tfinal e: { pos: Int, expr: String } = null;\n\t}\n}', ANON_FILL_LINE
		);
		Assert.isTrue(
			once.indexOf('final e:{\n\t\t\tpos:Int,\n\t\t\texpr:String\n\t\t} = null;') != -1,
			'expected the one-per-line shape the next pass would force, got:\n<$once>'
		);
		Assert.equals(once, write(once, ANON_FILL_LINE), 'one round trip must land on the fixed point');
	}

	/** The same shape one Star over: an object literal under a leading-break cascade. */
	public function testObjectLiteralLeadingBreakOnOverflow(): Void {
		final once: String = write('class C {\n\tfunction f(): Void {\n\t\tvar p = { x: 1, y: 2 };\n\t}\n}', OBJECT_LEADING_BREAK);
		Assert.isTrue(
			once.indexOf('var p = {\n\t\t\tx: 1,\n\t\t\ty: 2\n\t\t};') != -1,
			'expected the one-per-line shape the next pass would force, got:\n<$once>'
		);
		Assert.equals(once, write(once, OBJECT_LEADING_BREAK), 'one round trip must land on the fixed point');
	}

	/**
	 * The other half: `fillLine` renders FLAT when the list fits, and a list
	 * that stays on one line grows no newline for the next pass to read — so
	 * it is already a fixed point and must be left alone. Collapsing every
	 * `fillLine` answer to `OnePerLine` regardless of the fit state would
	 * break this line for no convergence gain.
	 */
	public function testShortListUnderFillLineStaysFlat(): Void {
		final src: String = 'class C {\n\tfunction f(): Void {\n\t\tfinal e: { pos: Int, expr: String } = null;\n\t}\n}';
		final once: String = write(src, ANON_BARE_FILL_LINE);
		Assert.isTrue(
			once.indexOf('final e:{pos:Int, expr:String} = null;') != -1, 'expected the fitting hint left on one line, got:\n<$once>'
		);
		Assert.equals(once, write(once, ANON_BARE_FILL_LINE), 'a list that fits was already a fixed point');
	}

	/**
	 * A CALL whose sole collection argument breaks only at RENDER time. The
	 * literal's own cascade resolves `NoWrap` in both fit states, so
	 * `emitZeroThresholdAgree` hands back `IfFirstLineExceeds(break, flat)` —
	 * and `flatLength` reads the flat arm, so the call measures the argument as
	 * one-line and opens its own paren. The renderer then takes the literal's
	 * break arm anyway; pass 2 reads that newline as author intent, commits the
	 * literal to `OnePerLine`, and the call — now seeing a real hardline —
	 * glues instead.
	 */
	public function testCallArgObjectLiteralGluesOnFirstPass(): Void {
		final src: String = 'class C {\n\tstatic function g(): Void {\n\t\trecordResolution(verifiedClass, consumer.fieldName, '
			+ '{ ownerClass: levelClass, fieldName: producer.fieldName, scopeLevel: i, fromRootExport: exports != null '
			+ '&& !locals.contains(producer) });\n\t}\n}';
		final once: String = write(src, CALL_ARG_OBJECT);
		Assert.isTrue(
			once.indexOf('recordResolution(verifiedClass, consumer.fieldName, {\n\t\t\townerClass: levelClass,') != -1,
			'expected the glued shape the next pass produces, got:\n<$once>'
		);
		Assert.equals(once, write(once, CALL_ARG_OBJECT), 'one round trip must land on the fixed point');
	}

	/**
	 * The same render-time break under a TERNARY host: pass 1 breaks `?` / `:`
	 * onto their own lines because the branch measures flat, pass 2 hugs
	 * (`cond ? a : {`) because the branch now carries a hardline.
	 */
	public function testTernaryBranchObjectLiteralHugsOnFirstPass(): Void {
		final src: String = 'class C {\n\tstatic function f(p: Null<PosInfos>): Null<PosInfos> {\n\t\treturn p == null ? null : '
			+ '{ fileName: p.fileName, customParams: p.customParams, methodName: p.methodName, className: p.className, '
			+ 'lineNumber: p.lineNumber };\n\t}\n}';
		final once: String = write(src, TERNARY_ARG_OBJECT);
		Assert.isTrue(
			once.indexOf('return p == null ? null : {\n\t\t\tfileName: p.fileName,') != -1,
			'expected the hugged shape the next pass produces, got:\n<$once>'
		);
		Assert.equals(once, write(once, TERNARY_ARG_OBJECT), 'one round trip must land on the fixed point');
	}

	/**
	 * The other half of the call leg, and the reason the glue it adds is
	 * fit-gated. A cascade that answers a BREAK mode in the FITS state — a
	 * rules-free `fillLine` — reaches the same glue shape without anything
	 * above it having refused the flat line, and the resolved collection's
	 * first line always fits. Ungated, this call exploded a literal the line
	 * had room for.
	 */
	public function testShortCallArgObjectLiteralUnderFillLineStaysFlat(): Void {
		final src: String = 'class C {\n\tstatic function g(): Void {\n\t\tf(a, b, { x: 1, y: 2 });\n\t}\n}';
		final once: String = write(src, CALL_ARG_FILL_LINE);
		Assert.isTrue(once.indexOf('f(a, b, {x: 1, y: 2});') != -1, 'expected the fitting call left on one line, got:\n<$once>');
		Assert.equals(once, write(once, CALL_ARG_FILL_LINE), 'a call that fits was already a fixed point');
	}

	/**
	 * ω-fit-pivot-collection-arg — the same glue under the cascade Pony actually
	 * ships. `exceedsMaxLineLength` resolves to `Group(IfBreak(…))`, not to the
	 * `IfFirstLineExceeds` threshold the pivot scan knew, so
	 * `soleMultilineCollectionArg` answered -1 and the whole multi-arg glue was
	 * unreachable — the call opened its paren and gave the literal a THIRD line
	 * of its own. The real site is `DIVerifier.addProducer(diSummary, { … })` in
	 * Pony's `DIBuilder.hx`.
	 */
	public function testCallArgObjectLiteralHugsUnderAnExceedsCascade(): Void {
		final src: String = 'class C {\n\tstatic function g(): Void {\n\t\tDIVerifier.addProducer(diSummary, { fieldName: field.name, '
			+ 'producerTypeNames: producerTypeNames, childDITypeName: childDITypeName, kindOfProducer: kind, pos: field.pos });\n\t}\n}';
		final once: String = write(src, CALL_ARG_EXCEEDS_OBJECT);
		Assert.isTrue(
			once.indexOf('DIVerifier.addProducer(diSummary, {\n\t\t\tfieldName: field.name,') != -1,
			'expected the compact hug, got:\n<$once>'
		);
		// The closing half separately: a shape that hugged the `{` and then gave
		// the `})` a line of its own would satisfy the anchor above.
		Assert.isTrue(once.indexOf('\n\t\t\tpos: field.pos\n\t\t});') != -1, 'expected the closer glued to the literal, got:\n<$once>');
		Assert.equals(once, write(once, CALL_ARG_EXCEEDS_OBJECT), 'one round trip must land on the fixed point');
	}

	/**
	 * The FIT pivot may NOMINATE a collection; it must never DISQUALIFY one. The
	 * scan bails on a second candidate, so admitting the fit shape inside the
	 * existing pass turned `f([ … ], { … })` — an array whose threshold pivot had
	 * the list to itself, plus a newly-visible object — into a two-candidate
	 * bail, and the array LOST a hug it had before the slice. Running the strict
	 * pass first and retrying only when it found nothing is what keeps this
	 * green; a single widened pass opens the call paren instead.
	 */
	public function testEarlierThresholdPivotCollectionKeepsItsHug(): Void {
		final src: String = 'class C {\n\tstatic function g(): Void {\n\t\tregister([alphaHandler, betaHandler, gammaHandler, '
			+ 'deltaHandler], { fieldName: field.name, producerTypeNames: names, kindOfProducer: kind });\n\t}\n}';
		final once: String = write(src, TWO_COLLECTION_ARGS);
		Assert.isTrue(once.indexOf('register([\n\t\t\talphaHandler,') != -1, 'expected the array to keep its hug, got:\n<$once>');
		Assert.isTrue(
			once.indexOf('\n\t\t], {fieldName: field.name, producerTypeNames: names, kindOfProducer: kind});') != -1,
			'expected the object literal left flat on the bracket-close line, got:\n<$once>'
		);
		Assert.equals(once, write(once, TWO_COLLECTION_ARGS), 'one round trip must land on the fixed point');
	}

	/**
	 * The FIT pivot's own must-not-fire half. A fit pivot says the renderer MAY
	 * break the collection, not that it will: when the literal's flat width fits
	 * on its own continuation line inside the opened paren, it never breaks
	 * there, and hugging it would COMMIT a break nothing decided. That is the
	 * shape the fork writes (`wrapping/issue_116_multipass`) and the one the D2
	 * chunk policy asks for; without the `IfArrowContinuationFits` gate this call
	 * hugged and both went red.
	 */
	public function testFittingCallArgObjectLiteralKeepsTheOpenParen(): Void {
		final src: String = 'class C {\n\tstatic function g(): Void {\n\t\tdeclaringFileRenameSpans(source, tree, declFrom, name, '
			+ 'shape, plugin, isDistinctive, true, { index: resolutionIndex, file: firstFile });\n\t}\n}';
		final once: String = write(src, CALL_ARG_EXCEEDS_OBJECT);
		Assert.isTrue(
			once.indexOf('true, {index: resolutionIndex, file: firstFile}\n\t\t);') != -1,
			'expected the literal left flat on its own continuation line, got:\n<$once>'
		);
		Assert.equals(once, write(once, CALL_ARG_EXCEEDS_OBJECT), 'one round trip must land on the fixed point');
	}

	/**
	 * The fit pivot nominates a collection at ANY argument index. With an argument
	 * AFTER the literal the glue's closer lands as `}, tail)` on the literal's
	 * closing line — the same shape the committed and threshold routes already
	 * produce in that position.
	 *
	 * The pivot was once restricted to the LAST argument because an unrestricted
	 * version drove a file into a two-rewrite convergence tail. What answers that is
	 * the continuation-fit gate, not the index: a fit pivot says the renderer MAY
	 * break the collection, and only hugging one that would have stayed flat makes
	 * the passes disagree. The `once == twice` assertion below is this fixture's
	 * share of holding that.
	 */
	public function testCallArgObjectLiteralBeforeAnotherArgumentHugs(): Void {
		final src: String = 'class C {\n\tstatic function g(): Void {\n\t\tDIVerifier.addProducer(diSummary, { fieldName: field.name, '
			+ 'producerTypeNames: producerTypeNames, childDITypeName: childDITypeName, kindOfProducer: kind, pos: field.pos }, '
			+ 'tail);\n\t}\n}';
		final once: String = write(src, CALL_ARG_EXCEEDS_OBJECT);
		Assert.isTrue(
			once.indexOf('DIVerifier.addProducer(diSummary, {\n\t\t\tfieldName: field.name,') != -1,
			'expected the compact hug, got:\n<$once>'
		);
		Assert.isTrue(
			once.indexOf('\n\t\t\tpos: field.pos\n\t\t}, tail);') != -1, 'expected the trailing argument on the closer line, got:\n<$once>'
		);
		Assert.equals(once, write(once, CALL_ARG_EXCEEDS_OBJECT), 'one round trip must land on the fixed point');
	}

	/**
	 * The reported site, reduced: `new Row([ … ], w, h, align)` — an ARRAY fit
	 * pivot at index 0 of four, nested one level inside itself. Both calls hug
	 * their array and carry the three scalars after it on the bracket-close line;
	 * the `new Label(` inside stays exploded, having no container among its own
	 * arguments.
	 */
	public function testCallArgArrayBeforeOtherArgumentsHugs(): Void {
		final src: String = 'class C {\n\tfunction build(): Void {\n\t\tfinal searchRow: Row = new Row([searchInput, new Row(['
			+ 'drillsSelected, new Label(t(\'({x} allowed)\', 10087).replace(\'{x}\', \'12\'), new TextFormat('
			+ 'Typography.fontNameItalic, 11, Colors.BLACK, false, true), boxWidth / 6, 30)], Std.int(boxWidth * 0.461), 30, '
			+ 'MainAxisAlignment.SPACE_AROUND)], boxWidth, 31, MainAxisAlignment.SPACE_AROUND);\n\t}\n}';
		final once: String = write(src, CALL_ARG_EXCEEDS_ARRAY);
		Assert.isTrue(
			once.indexOf('new Row([\n\t\t\tsearchInput,\n\t\t\tnew Row([\n\t\t\t\tdrillsSelected,') != -1,
			'expected both arrays hugged to their own head, got:\n<$once>'
		);
		Assert.isTrue(
			once.indexOf(
				'\n\t\t\t], Std.int(boxWidth * 0.461), 30, MainAxisAlignment.SPACE_AROUND)\n\t\t], boxWidth, 31, '
				+ 'MainAxisAlignment.SPACE_AROUND);'
			) != -1,
			'expected the trailing scalars on each bracket-close line, got:\n<$once>'
		);
		Assert.equals(once, write(once, CALL_ARG_EXCEEDS_ARRAY), 'one round trip must land on the fixed point');
	}

	/**
	 * The two files the `bgPrefix` charge closed — the part of the tail that IS a
	 * `BodyGroup` question. Both are a call whose object-literal argument breaks only at
	 * RENDER time and whose remaining arguments end in a group committed to
	 * breaking — a `{`-bodied lambda, or a ternary the cascade has already
	 * broken.
	 *
	 * The direction, read off `ast --writer-output` chained three times over
	 * Pony's `PixiXmlUi.hx` and `Bmfont.hx`:
	 * pass 1 reads a source-FLAT literal, GLUES the argument list, and the
	 * renderer then writes the literal's own newlines into the file. Pass 2
	 * reads those newlines, force-commits the literal to one-per-line — and
	 * `Renderer.flatFirstLineStep` deferred that now-committed `BodyGroup` to
	 * zero width and KEPT WALKING, so the argument list's first-line probe
	 * read a header the renderer never emits and OPENED the list. Pass 3
	 * re-settles on the opened shape, which is what `fmt` used to write.
	 *
	 * So the fix changes nothing on pass 1 — base and fixed pass-1 output are
	 * byte-equal for both files — it makes pass 2 REPRODUCE pass 1, by charging
	 * a committed group its leading `{` and ending the line, the answer
	 * `restNodeWidth` already gave.
	 *
	 * Both assertions must discriminate, so the shape is asserted on the SETTLED
	 * text: on base `twice` is the opened list, so shape and equality both flip
	 * when `Renderer.hx` alone is reverted. Asserting the shape on `once`
	 * instead does NOT discriminate — base's pass 1 is already glued, and that
	 * assertion passes with the fix reverted.
	 */
	public function testCommittedBodyGroupPrefixConvergesOnFirstPass(): Void {
		final cases: Array<{ name: String, src: String, glued: String }> = [
			{
				name: 'lambda-tailed call (Bmfont.hx)',
				glued: 'NPM.msdf_bmfont_xml(font.fullPath.first, {\n',
				src: 'class Bm {\n\tprivate function f(): Void {\n\t\tNPM.msdf_bmfont_xml(font.fullPath.first, { filename: ofn, charset: '
					+ 'charset, smartSize: true, pot: false, square: true, fontSize: size, fieldType: type, outputType: format, '
					+ 'distanceRange: distance }, function(err: Any, textures: Array<{ filename: String, texture: Dynamic }>, font: {'
					+ ' filename: String, data: String, options: Dynamic }): Void {\n\t\t\tlog(\'done\');\n\t\t});\n\t}\n}'
			},
			{
				name: 'ctor call with a leading literal (PixiXmlUi.hx)',
				glued: 'new HtmlVideoUIFS({\n',
				src: 'class Px {\n\tprivate function f(): Void {\n\t\tif (a) {\n\t\t\tif (b) {\n\t\t\t\tfinal video: '
					+ 'HtmlVideoUIFS = new HtmlVideoUIFS({ x: parseAndScale(attrs.x), y: parseAndScale(attrs.y), '
					+ 'width: parseAndScale(attrs.w), height: parseAndScale(attrs.h) }, attrs.fsborder != null ? '
					+ '(attrs.fsborder: Border<Float>) : null, fspos, attrs.css, attrs.fscss, attrs.transition, app, '
					+ 'attrs.clicktimeout, attrs.ceil.isTrue(), attrs.fixed.isTrue());\n\t\t\t}\n\t\t}\n\t}\n}'
			}
		];
		for (c in cases) {
			final once: String = write(c.src, COMMITTED_BODY_PREFIX);
			final twice: String = write(once, COMMITTED_BODY_PREFIX);
			Assert.isTrue(twice.indexOf(c.glued) != -1, '${c.name}: the SETTLED shape must keep the list glued, got:\n<$twice>');
			Assert.equals(once, twice, '${c.name}: one round trip must land on the fixed point');
		}
	}

	/**
	 * The writer shapes of the convergence tail, PINNED AS STILL DIVERGENT
	 * (ω-canonical-fixed-point). Each needs two writer rewrites under the config beside
	 * it; the tail is a property of a CONFIG, not of a file, and under this project's own
	 * `hxformat.json` it is empty.
	 *
	 * TWO root causes, not one; the discriminator is one config edit — replace the
	 * collection's cascade with a RULES-FREE one (`{"defaultWrap": "onePerLine",
	 * "rules": []}`), which answers the same mode in both fit states and therefore
	 * cannot emit a pivot at all (`testTailMechanismSplitsOnTheLiteralCascade`):
	 *  - MECHANISM A: a static measure reads a collection whose break the RENDERER
	 *    decides. The cascade carries a fit-dependent `noWrap` SHADOW over a breaking
	 *    `defaultWrap`, so a source-FLAT literal reaches its host as
	 *    `emitZeroThresholdAgree`'s `IfFirstLineExceeds` pivot while the same literal,
	 *    once the writer's own output has broken it, is force-committed by the Star
	 *    that does not reflow source newlines; the host measure answers differently
	 *    and the enclosing shape flips. Committing the cascade makes these CONVERGE.
	 *    Hosts: `BodyFit.fitLineLayout` on a `caseBody: fitLine` or `ifBody: fitLine`
	 *    host, and the value-`if` branch — the `ifBody: fitLine` host has no fixture yet.
	 *  - MECHANISM B, no pivot anywhere: `DocMeasure.flatTokenWidth` DEFERS a
	 *    `BodyGroup` to 0, so the width a CASCADE reads for an item ALREADY committed
	 *    to breaking collapses between the two passes — the class
	 *    ω-committed-objectlit-glue closed inside `shapeSingleArgGlue`'s `{`-branch,
	 *    met here through the cascade's own INPUT, and it SURVIVES a rules-free
	 *    cascade, which is what proves it is not mechanism A. Hosts: a ternary under a
	 *    sole-argument call (pinned here) and a method chain (no fixture yet).
	 *
	 * The two mechanisms STACK, and that is what a THREE-rewrite file is
	 * (`testStackedMechanismsNeedThreeRewrites`; its `rules: []` is load-bearing, since the
	 * shipped `arrayWrap` rules shadow `defaultWrap` and the file then converges).
	 * `testMultiArgFillPacksACommittedBodyOnPassTwo` is mechanism B in a third host.
	 *
	 * Of the candidate fixes only `Renderer.flatFirstLineStep` adopting `restNodeWidth`'s
	 * committed-`BodyGroup` answer for the `IfFirstLineExceeds` consumer shipped (the
	 * `bgPrefix` flag); every other candidate reformats this project's own tree, which is
	 * otherwise a fixed point — each is one line in `docs/decisions.md`. So the writer
	 * defect is left standing and reported (`apq fmt` warns), and the CONSUMER silently
	 * harmed by it — `RefactorSupport.canonicalize` — was fixed instead. When a fix does
	 * land, these become `Assert.equals` on `once` and `twice`; do not delete them.
	 */
	public function testConvergenceTailStillNeedsTwoRewrites(): Void {
		final cases: Array<{ name: String, src: String, config: String }> = [
			{
				name: 'case body (Unpack.hx, Builder.hx)',
				config: CASE_BODY_OBJECT,
				src: CASE_BODY_SRC
			},
			{
				name: 'value-if branch (DIBuilder.hx)',
				config: VALUE_IF_NESTED,
				src: VALUE_IF_SRC
			},
			{
				name: 'ternary under a sole-arg call (HasSignalBuilder.hx)',
				config: CALL_TERNARY_NESTED,
				src: CALL_TERNARY_SRC
			}
		];
		for (c in cases) {
			final once: String = write(c.src, c.config);
			final twice: String = write(once, c.config);
			Assert.notEquals(
				once, twice, '${c.name}: this writer divergence is CLOSED — flip this case to Assert.equals and re-run the Pony census'
			);
			Assert.equals(twice, write(twice, c.config), '${c.name}: the second rewrite must itself be the fixed point');
		}
	}

	/**
	 * The convergence tail's actual BITE, and the half of it this slice closes:
	 * `RefactorSupport.canonicalize` writes the writer's FIXED POINT, not one
	 * round trip.
	 *
	 * Every writer-emit mutation op finalises through `canonicalize`, and the gate
	 * the NEXT such op puts on the file it wrote is `writeRoundTrip(s) == s` after
	 * ONE pass. For a source the writer cannot settle in one, a single round trip
	 * there reported `wrote <file>` and left a file its own `fmt --list` called
	 * drifted — seen with `apq add-member --reformat` on a Pony file, after which
	 * the very next `add-member` refused with `file is not in canonical form`.
	 *
	 * `edits` is empty deliberately: the defect is in the FINALISE, not in any
	 * splice, so the smallest statement of it is "canonicalise this source and the
	 * answer must be a fixed point".
	 */
	public function testCanonicalizeWritesTheWriterFixedPoint(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		switch CanonicalEdit.canonicalize(CASE_BODY_SRC, [], true, plugin, CASE_BODY_OBJECT) {
			case Ok(text):
				Assert.equals(
					text, plugin.writeRoundTrip(text, CASE_BODY_OBJECT),
					'the op must write a file the next op\'s one-pass canonical gate accepts, got:\n<$text>'
				);
			case Err(message):
				Assert.fail('canonicalize refused: $message');
		}
	}

	/**
	 * The reporting half: the finalise now HANDS BACK the count it paid, so a
	 * mutation op can say what `fmt` says.
	 *
	 * `EditResult.Ok` grew an optional `rewrites`, and `canonicalize` fills it.
	 * Before that the loop above ran and its `FormatFixedPointResult.rewrites` went
	 * nowhere — the op wrote the file, reported `wrote <path>`, and the user never
	 * learned the writer had needed a second pass on it. `rewritesNote` is the one
	 * sentence both `fmt` and the ops print, so a reader meeting it twice can tell
	 * it is one finding.
	 */
	public function testCanonicalizeReportsTheRewriteCount(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		switch CanonicalEdit.canonicalize(CASE_BODY_SRC, [], true, plugin, CASE_BODY_OBJECT) {
			case Ok(_, rewrites):
				Assert.equals(2, rewrites, 'the divergent shape costs two rewrites and the count must reach the caller');
				Assert.notNull(FormatFixedPoint.rewritesNote(rewrites), 'a count above 1 has a note to print');
			case Err(message):
				Assert.fail('canonicalize refused: $message');
		}
	}

	/**
	 * The other half, and the reason the note is not printed off `converged`
	 * alone: an ordinary file settles on the FIRST rewrite, and saying so would
	 * make the note noise on every op.
	 */
	public function testCanonicalizeReportsNothingForAConvergingFile(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		// Deliberately NON-canonical spacing, so the first rewrite does real work rather
		// than appending a trailing newline: `rewrites` must be exactly 1, which also
		// pins that the loop RAN — a fixture the writer already agrees with takes `run`'s
		// pass-1 short-cut and answers 0, and a `<= 1` assertion would not tell them apart.
		final src: String = 'class C {\n\tfunction  f( ) :Void {\n\t\tvar p = {x:1,   y:2};\n\t}\n}\n';
		switch CanonicalEdit.canonicalize(src, [], true, plugin, null) {
			case Ok(_, rewrites):
				Assert.equals(1, rewrites, 'a normal file settles on the FIRST rewrite');
				Assert.isNull(FormatFixedPoint.rewritesNote(rewrites), 'nothing to report for the healthy counts');
			case Err(message):
				Assert.fail('canonicalize refused: $message');
		}
	}

	/**
	 * ω-committed-objectlit-glue — a sole object-literal call argument the
	 * literal's own cascade has already COMMITTED to breaking.
	 *
	 * `shapeSingleArgGlue`'s `{`-branch asked `IfArrowContinuationFits` whether
	 * the literal fits FLAT on its own continuation line, off
	 * `DocMeasure.flatTokenWidth`. For a literal carrying a forced hardline that
	 * question has no answer — the literal will not render flat anywhere — and
	 * the measure it was answered from is not even stable across passes: a
	 * source-FLAT list reaches the call through `WrapList.emit` and measures its
	 * real token width (101 columns for the source below), while the same list
	 * once the writer's own output has broken it takes the force-multi emit,
	 * arrives as `WrapBoundary(BodyGroup(…))`, and `flatTokenWidth` DEFERS a
	 * `BodyGroup` to 0. Zero then satisfies the cascade's `totalItemLength <= 100`
	 * `noWrap` rule, so the call glued on pass 2 what it had opened on pass 1.
	 *
	 * Read off `ast --writer-output` chained three times: pass 1 opens
	 * `recordResolution(` with the `{` on its own line, pass 2 glues
	 * `recordResolution({`, pass 3 reproduces pass 2 — a two-rewrite
	 * convergence, NOT an oscillation. Sweeping the literal's flat width one
	 * column at a time under this cascade gives a CONTIGUOUS two-sided band:
	 * under the `totalItemLength <= 100` rule it glues on pass 1 already, and
	 * once the continuation probe stops fitting at this indent the glued shape
	 * wins on pass 1. The source below sits inside that band.
	 *
	 * The fix answers the question the premise allows: a committed literal
	 * glues. That is also the shape `testCallArgObjectLiteralGluesOnFirstPass`
	 * and `testCallArgObjectLiteralHugsUnderAnExceedsCascade` already pin as the
	 * settled one, so pass 1 now writes what pass 2 wanted.
	 *
	 * Both assertions discriminate: with the guard reverted `once` is the opened
	 * shape, so the anchor fails, and `once != twice`, so the equality fails too.
	 */
	public function testSoleCommittedObjectLiteralArgGluesOnFirstPass(): Void {
		final src: String = 'class C {\n\tstatic function g(): Void {\n\t\trecordResolution({ ownerClass: levelClass, '
			+ 'fieldName: producer.fieldName, scopeLevel: depth, fromRootExport: exports != null });\n\t}\n}';
		final once: String = write(src, CALL_ARG_COMMITTED_OBJECT);
		Assert.isTrue(
			once.indexOf('recordResolution({\n\t\t\townerClass: levelClass,') != -1,
			'expected the glued shape the next pass produces, got:\n<$once>'
		);
		Assert.isTrue(
			once.indexOf('\n\t\t\tfromRootExport: exports != null\n\t\t});') != -1,
			'expected the closer glued to the literal, got:\n<$once>'
		);
		Assert.equals(once, write(once, CALL_ARG_COMMITTED_OBJECT), 'one round trip must land on the fixed point');
	}

	/**
	 * The must-not-fire half, and the reason the glue above is gated on the
	 * literal's COMMITMENT rather than on its being an object literal at all.
	 * Here the sole `{`-argument is short enough that its own cascade leaves it
	 * flat, so it carries no hardline, the continuation probe has a real question
	 * to answer, and the answer is the one that was already right: open the
	 * paren and leave the literal flat on its own line. Byte-identical to the
	 * pre-slice output, verified against a base-engine build.
	 */
	public function testSoleUncommittedObjectLiteralArgKeepsTheOpenParen(): Void {
		final src: String = 'class C {\n\tstatic function g(): Void {\n\t\tregisterDeferredResolutionForVerifiedProducerFields'
			+ 'OnTheCurrentLevelAndItsParentsAndEveryEnclosingScopeChainInDeclarationOrder({ x: 1, y: 2 });\n\t}\n}';
		final once: String = write(src, CALL_ARG_COMMITTED_OBJECT);
		Assert.isTrue(
			once.indexOf('InDeclarationOrder(\n\t\t\t{x: 1, y: 2}\n\t\t);') != -1,
			'expected the literal left flat on its own continuation line, got:\n<$once>'
		);
		Assert.equals(once, write(once, CALL_ARG_COMMITTED_OBJECT), 'one round trip must land on the fixed point');
	}

	/**
	 * The tail's TWO mechanisms, told apart by ONE config edit
	 * (ω-canonical-fixed-point).
	 *
	 * `testConvergenceTailStillNeedsTwoRewrites` pins these same three sources
	 * DIVERGENT under cascades that carry a fit-dependent `noWrap` shadow. Run
	 * them again with only that shadow removed — a rules-free cascade answers
	 * ONE mode in both fit states, so no `IfFirstLineExceeds` pivot can exist —
	 * and two of the three CONVERGE while the third still needs two rewrites.
	 *
	 * That split is the whole content of the mechanism claim above, and the two
	 * tests together are its mutation proof: the only variable between them is
	 * the cascade's `rules` array, and flipping it flips exactly the first two
	 * cases.
	 *
	 * Each case pins the settled SHAPE beside the rewrite count, so a writer
	 * that reformatted nothing at all would fail here rather than pass.
	 */
	public function testTailMechanismSplitsOnTheLiteralCascade(): Void {
		final cases: Array<{
			name: String,
			src: String,
			config: String,
			rewrites: Int,
			shape: String
		}> = [
			{
				name: 'case body — mechanism A, the pivot WAS the whole cause',
				src: CASE_BODY_SRC,
				config: CASE_BODY_COMMITTED,
				rewrites: 1,
				shape: 'case \'zip\': cfg.zips.push({\n'
			},
			{
				name: 'value-if branch — mechanism A',
				src: VALUE_IF_SRC,
				config: VALUE_IF_COMMITTED,
				rewrites: 1,
				shape: 'if (staticDIVar != null)\n\t\t\t{\n\t\t\t\texpr: EVars([\n'
			},
			{
				name: 'ternary under a sole-arg call — mechanism B, no pivot and still two passes',
				src: CALL_TERNARY_SRC,
				config: CALL_TERNARY_COMMITTED,
				rewrites: 2,
				shape: 'kind: FFun(setcontroll\n'
			}
		];
		for (c in cases) {
			final result: FormatFixedPointResult = FormatFixedPoint.run(s -> write(s, c.config), c.src);
			Assert.equals(
				c.rewrites, result.rewrites,
				'${c.name}: the mechanism split moved — re-run the committed-cascade sweep before editing the doc above'
			);
			final settled: Null<String> = result.text;
			Assert.isTrue(settled != null && settled.indexOf(c.shape) != -1, '${c.name}: settled on an unexpected shape:\n<$settled>');
		}
	}

	/**
	 * The two mechanisms STACKED, which is what a THREE-rewrite file is
	 * (ω-canonical-fixed-point).
	 *
	 * `tools/src/create/ides/VSCode.hx` under Pony's committed `hxformat.json`
	 * plus `arrayWrap: {"defaultWrap": "fillLine", "rules": []}` needs three
	 * writer rewrites — one deeper than any shape recorded before this. The
	 * links settle one per pass and they are one of each mechanism: pass 1 to 2
	 * packs the committed array (`} : Dynamic), ({`, mechanism B), and only the
	 * shape that leaves lets pass 2 to 3 read the enclosing literal's pivot and
	 * explode it one-per-line (mechanism A).
	 *
	 * Committing the literal cascade removes the second link and leaves exactly
	 * two, which is the assertion that proves the two are independent rather
	 * than one decision counted twice.
	 */
	public function testStackedMechanismsNeedThreeRewrites(): Void {
		final chained: FormatFixedPointResult = FormatFixedPoint.run(s -> write(s, STACKED_ARRAY_PIVOT), STACKED_SRC);
		// `converged` first: three is ONE pass under `FormatFixedPoint.MAX_REWRITES`,
		// so a chain that grew a fourth link would fail the count assertion with
		// "expected 3 got 4" and say nothing about the condition that actually broke.
		Assert.isTrue(chained.converged, 'the chain must still reach a fixed point at all: ${chained.failure}');
		Assert.equals(3, chained.rewrites, 'the deepest known chain must still take three writer rewrites');
		final settled: Null<String> = chained.text;
		Assert.isTrue(
			settled != null && settled.indexOf('} : Dynamic), ({\n') != -1,
			'the mechanism-B link must settle on the packed array:\n<$settled>'
		);
		Assert.isTrue(
			settled != null && settled.indexOf('final data = {\n\t\t\tversion: \'0.2.0\',\n') != -1,
			'the mechanism-A link must settle on the exploded literal:\n<$settled>'
		);
		Assert.equals(
			2, FormatFixedPoint.run(s -> write(s, STACKED_ARRAY_COMMITTED), STACKED_SRC).rewrites,
			'with the literal cascade committed exactly ONE link must remain'
		);
	}

	/**
	 * Mechanism B in a third host: the multi-argument fill
	 * (ω-canonical-fixed-point).
	 *
	 * `src/anyparse/query/Cli.hx`'s `limitEntries(...)` is a fixed point under
	 * this project's own `hxformat.json`, so nothing here observes it; a share
	 * of the single-knob config arms do. Under a COMMITTED literal cascade the
	 * trailing `(e, k) -> {…}` argument measures its real `DocMeasure.flatTokenWidth`
	 * on pass 1 and a deferred one on pass 2 — the `BodyGroup` deferral — so
	 * `shapeFillLineWithLeadingBreak`'s `FillBreakAfterWrap` wraps before that
	 * argument on pass 1 and packs it on pass 2.
	 *
	 * The control is the SAME cascade with its `totalItemLength <= 140` shadow
	 * put back: the literal then stays flat, nothing is committed, and one
	 * rewrite is the fixed point. It is green at base BY CONSTRUCTION, so it is
	 * not evidence on its own — its job is to show that the two-rewrite arm
	 * above is about the COMMITMENT and not about the source.
	 */
	public function testMultiArgFillPacksACommittedBodyOnPassTwo(): Void {
		final committed: FormatFixedPointResult = FormatFixedPoint.run(s -> write(s, CALL_TERNARY_COMMITTED), MULTI_ARG_FILL_SRC);
		Assert.equals(2, committed.rewrites, 'the multi-argument fill must still need two writer rewrites');
		final settled: Null<String> = committed.text;
		Assert.isTrue(
			settled != null && settled.indexOf('e -> e.hits.length, (e, k) -> {\n') != -1,
			'pass 2 must pack the committed lambda body onto the leading arguments:\n<$settled>'
		);
		final control: FormatFixedPointResult = FormatFixedPoint.run(s -> write(s, CALL_TERNARY_NESTED), MULTI_ARG_FILL_SRC);
		Assert.equals(1, control.rewrites, 'an UNcommitted literal leaves the same call a one-rewrite fixed point');
		final flat: Null<String> = control.text;
		// SPANNING assertion: the packed leading arguments AND the flat literal in
		// one string. The source line differs from it by the space before its close
		// brace, so no untransformed input can satisfy it.
		Assert.isTrue(
			flat != null && flat.indexOf('e -> e.hits.length, (e, k) -> {file: e.file, source: e.source, hits: e.hits.slice(0, k)}\n')
				!= -1,
			'the control must keep the literal flat on the packed argument line:\n<$flat>'
		);
	}

	private static function write(src: String, config: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(config);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
