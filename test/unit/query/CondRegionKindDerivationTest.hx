package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CondRegionScan;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Meta;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * How the fail-closed gate over an UNPARSED `#if` region learns WHICH ctors carry one, and why
 * that is asked of the grammar's own DECLARATIONS rather than of anything anybody keeps.
 *
 * `RefShape.opaqueCondRegionKinds` began as an exhaustive list of ctor names, and it was stale
 * within two days of shipping: the gate landed 2026-08-18 naming ten `CondSplice*` ctors, and
 * 2026-08-20 the grammar gained three more raw-capture ctors - `CondSpliceReturnStmt`,
 * `CondSpliceReturnExpr` and `MetaCondStmt`. Nothing connects the two edits, nothing failed, and
 * for eighteen days every name-driven mutating op wrote SILENTLY over such a region - the
 * reproducer below renames a declaration and leaves its only other reference on the old name,
 * which compiles until someone builds with the flag defined.
 *
 * S167 made the field a list of ctor-name PREFIXES, which closed those three and left a narrower
 * hole of the same shape: a ctor named outside the convention. Two already were, spelled in full
 * beside the family prefix, and the coverage pin guarding the list checked the SAME convention -
 * so a third breaker would have been invisible to both.
 *
 * S175 removed the convention from the question. A conditional region can only be captured raw
 * through a TERMINAL, so the grammar marks its raw-capture terminals `@:condRegionRaw` and the
 * query-walker macro walks each ctor's own production to the terminals it reaches. A ctor's NAME
 * enters nothing.
 *
 * MEASURED, and the measurement is a probe that is NOT in the tree: renaming `HxStatement`'s
 * `CondSpliceReturnStmt` to `GuardedReturnStmt` - one token, same production, same terminal - and
 * changing nothing else. Under the prefix list the reproducer below went from the refusal quoted
 * in `testTheReturnStatementSpliceIsSeenByTheGate` to `apq rename: wrote probe/Probe.hx`, exit 0,
 * leaving `final renamed:Int = 1;` beside `return #if nodejs target;`. Under the derivation
 * `GuardedReturnStmt` appears in `HaxeQueryWalker.opaqueCondRegionKinds()` with no edit anywhere
 * and the refusal is byte-identical. The probe was reverted: a bogus ctor is not shippable
 * grammar, and the standing catch for the next real one is
 * `testTheDerivedOpaqueKindsMatchAnIndependentScanOfTheGrammar`, which recomputes the same answer
 * from the grammar SOURCE without either side reading a name.
 *
 * The two guard fixtures are the other half. Widening a fail-CLOSED gate buys refusals, and a
 * refusal on a region the model DOES resolve is pure loss: a balanced `Conditional` and a
 * `CondSpliceOpExpr` both keep their references as real nodes, every op rewrites them correctly
 * today, and both must stay invisible to this scan. The second guards the one hand-held decision
 * left - a new raw-capture terminal that arrives without its marker.
 */
@:nullSafety(Strict)
class CondRegionKindDerivationTest extends Test {

	/** The grammar package whose ctor names the gate is derived from. */
	private static inline final HAXE_GRAMMAR_DIR: String = 'src/anyparse/grammar/haxe';

	/** Grammar opt-in marking a TERMINAL whose bytes are conditional-region text no node projects. */
	private static inline final RAW_MARKER: String = '@:condRegionRaw';

	/** Grammar opt-in marking the TERMINAL a directive's condition atom is captured as. */
	private static inline final CONDITION_MARKER: String = '@:condRegionCondition';

	/** The tag every grammar rule carries - what bounds the independent scan to declarations the macro also sees. */
	private static inline final PEG_MARKER: String = '@:peg';

	/** The `Seq` opt-out of transparency; its argument is the kind such a struct projects. */
	private static inline final SPANNED_MARKER: String = '@:spanned';

	/** Below this the independent scan found nothing to compare and every assertion over it would pass vacuously. */
	private static inline final MIN_RAW_CAPTURE_KINDS: Int = 12;

	/** Below this the marker scan found no seed and the coverage direction below would be empty. */
	private static inline final MIN_RAW_TERMINALS: Int = 5;

	/**
	 * The reported reproducer, verbatim. `return #if nodejs target; #else 2; #end` in
	 * STATEMENT position projects a childless `CondSpliceReturnStmt`, so the only reference
	 * to `target` outside the declaration exists in bytes no scan can reach.
	 */
	private static final RETURN_STMT_SPLICE: String =
		'class Probe { function f():Int { final target:Int = 1;\n\treturn #if nodejs target; #else 2; #end } }\n';

	/**
	 * The second instance of the same defect: the EXPRESSION-position twin
	 * `CondSpliceReturnExpr`, reached through an expression body rather than a block. It is a
	 * separate grammar ctor added in the same slice, and a fix that named one and not the
	 * other would pass a pin written only against the first. Live shape:
	 * `Pony/src/pony/ui/touch/TouchableBase.hx:66`, the one site of this kind in 872 files.
	 */
	private static final RETURN_EXPR_SPLICE: String =
		'class Probe {\n\tstatic var target:Int = 1;\n\tstatic function g():Int return #if nodejs target; #else 2; #end\n}\n';

	/**
	 * The THIRD ctor the hand list missed, and the one a `CondSplice*` prefix does not reach:
	 * a metadata-prefixed statement whose whole body is a self-terminating `#if … ; #end`
	 * region. `MetaCondStmt` is named for the metadata it dispatches on, not for the
	 * `HxCondSpliceClosedRegion` it then swallows — the same raw terminal the two `return`
	 * ctors carry — so it is spelled out in the shape rather than derived, and this fixture is
	 * the only thing that would notice its absence.
	 */
	private static final META_COND_SPLICE: String = 'class Probe {\n\tvar target:Int = 1;\n\tpublic function new() {}\n'
		+ '\tfunction f():Void {\n\t\t@SuppressWarnings("x") #if nodejs target = 2; #else target = 3; #end\n\t}\n}\n';

	/** A balanced region: the guarded statement is a real child, so `target` is renamed like any other read. */
	private static final BALANCED_REGION: String =
		'class Probe {\n\tfunction f():Void {\n\t\tfinal target:Int = 1;\n\t\t#if nodejs\n\t\ttrace(target);\n\t\t#end\n\t}\n}\n';

	/**
	 * An operand-run splice. The kind IS on the gate's list, yet `target` is a projected
	 * operand - only the operators between them are dropped - so the gap scan finds no
	 * mention and the rename goes through. The pair with `RETURN_STMT_SPLICE` is what shows
	 * the list is a cheap pre-filter and the GAP analysis is the predicate.
	 */
	private static final OPERAND_RUN_SPLICE: String =
		'class Probe {\n\tfunction f(a:Int, b:Int):Int {\n\t\tfinal target:Int = 7;\n\t\treturn #if debug target + a + #end b;\n\t}\n}\n';

	/**
	 * The statement-position reproducer: the gate SEES the region, so every op that consults
	 * it refuses instead of half-rewriting.
	 */
	@:pin('control')
	@:killer('M-OPAQUE-REGION-HAND-LIST')
	public function testTheReturnStatementSpliceIsSeenByTheGate(): Void {
		Assert.equals('CondSpliceReturnStmt', regionKinds(RETURN_STMT_SPLICE).join(','), 'the fixture projects the reported ctor');
		Assert.notNull(mentionOf(RETURN_STMT_SPLICE, 'target'), 'and the gate finds "target" in the bytes it captured raw');
		Assert.equals(
			'rename of "target" is unsafe: the unparsed conditional-compilation region at 2:2 spells "target" in bytes the'
			+ ' parser captured raw (return #if nodejs target; #else 2; #end), so no scan can see that occurrence and the'
			+ ' rewrite would leave it on the old name - restructure the region into a balanced #if first',
			diagnosticOf(RETURN_STMT_SPLICE, 'target')
		);
	}

	/** The expression-position twin, which a fix naming one ctor by hand would have missed. */
	@:pin('control')
	@:killer('M-OPAQUE-REGION-HAND-LIST')
	public function testTheReturnExpressionSpliceIsSeenByTheGate(): Void {
		Assert.equals('CondSpliceReturnExpr', regionKinds(RETURN_EXPR_SPLICE).join(','), 'the fixture projects the expression twin');
		Assert.notNull(mentionOf(RETURN_EXPR_SPLICE, 'target'), 'and the gate finds "target" in it too');
	}

	/**
	 * The metadata-prefixed region, whose ctor no prefix reaches. It is the standing evidence
	 * that the family convention is not the whole story: `MetaCondStmt` was added in the same
	 * 2026-08-20 series as the two `return` ctors, carries the same raw terminal, and a fix
	 * that only widened the `CondSplice` prefix would have left it fail-OPEN.
	 */
	@:pin('control')
	@:killer('M-OPAQUE-REGION-HAND-LIST')
	public function testTheMetadataPrefixedSpliceIsSeenByTheGate(): Void {
		Assert.equals('MetaCondStmt', regionKinds(META_COND_SPLICE).join(','), 'the fixture projects the metadata-prefixed ctor');
		Assert.notNull(mentionOf(META_COND_SPLICE, 'target'), 'and the gate finds "target" in the bytes it captured raw');
	}

	/**
	 * The vacuity guard. Both regions mention `target` in their SOURCE and neither is
	 * something the gate may report: a balanced `Conditional` keeps the read as a child, and
	 * an operand-run splice keeps every operand as one. A widening that catches either turns
	 * a correct rewrite into a refusal, which no message can undo.
	 */
	@:pin('guard')
	public function testAModelledRegionStaysInvisibleToTheGate(): Void {
		Assert.isTrue(BALANCED_REGION.indexOf('trace(target)') != -1, 'the balanced fixture does mention the name');
		Assert.equals(0, regionKinds(BALANCED_REGION).length, 'a balanced Conditional is not an opaque region');
		Assert.isNull(mentionOf(BALANCED_REGION, 'target'), 'so the gate says nothing about it');
		Assert.equals('CondSpliceOpExpr', regionKinds(OPERAND_RUN_SPLICE).join(','), 'the operand run IS an opaque kind');
		Assert.isNull(mentionOf(OPERAND_RUN_SPLICE, 'target'), 'yet its operand is a projected node, so the gap scan sees no mention');
	}

	/**
	 * The derivation, checked against a SECOND one computed here - the assertion that makes
	 * the historical desync unrepeatable, and the one thing a naming convention could not
	 * give.
	 *
	 * Both sides answer "which projected kind captures conditional-region bytes raw", and
	 * neither reads the other. The shipped side is the macro's, over `haxe.macro.Type` at
	 * compile time. The side below is over the grammar's own SOURCE, parsed with the grammar's
	 * own parser: it reads the `@:condRegionRaw` markers off the terminals, closes over the
	 * `@:peg` structs that hold one, and reports the enum ctors that reach the closure. A
	 * ctor's NAME never enters either computation, which is why a ctor named outside every
	 * convention the grammar has so far used - two already are - lands in both or in neither.
	 *
	 * The two directions catch opposite failures. A kind the source finds and the shape does
	 * not is the eighteen-day hole itself: a name-driven op rewrites around such a region in
	 * silence. A kind the shape carries and the source cannot find means the derivation has
	 * drifted from the declarations it claims to read, which would leave the gate looking
	 * configured while resting on nothing.
	 */
	@:pin('control')
	@:killer('M-COND-KIND-NAME-CONVENTION')
	@:killer('M-OPAQUE-REGION-HAND-LIST')
	public function testTheDerivedOpaqueKindsMatchAnIndependentScanOfTheGrammar(): Void {
		final derived: Array<String> = (new HaxeQueryPlugin().refShape().opaqueCondRegionKinds ?? []).copy();
		derived.sort(Reflect.compare);
		final scanned: Array<String> = rawCaptureKindsFromGrammarSource();
		Assert.isTrue(
			scanned.length >= MIN_RAW_CAPTURE_KINDS,
			'the independent scan of $HAXE_GRAMMAR_DIR found ${scanned.length} raw-capture kind(s) - '
			+ 'below $MIN_RAW_CAPTURE_KINDS the comparisons below would pass vacuously'
		);
		Assert.equals(
			scanned.join(','), derived.join(','),
			'the macro derivation and an independent scan of the grammar source disagree about which ctors capture a conditional region '
			+ 'raw; a kind the SCAN has and the shape lacks is a fail-OPEN gate (every name-driven op rewrites around such a region in '
			+ 'silence), one the SHAPE has and the scan lacks means the derivation no longer reads the declarations it claims to'
		);
	}

	/**
	 * Every terminal that captures conditional-region bytes carries its marker - the ONE
	 * hand-held decision the derivation still rests on, and therefore the one worth guarding.
	 *
	 * Deriving the ctor list from the terminals moved the failure point rather than removing
	 * it: a ctor can no longer fall out of the gate by being named unconventionally, but a new
	 * raw-capture TERMINAL added without `@:condRegionRaw` would take every ctor built on it
	 * out with it. Terminals are the far smaller and far more stable set - nine against the
	 * fourteen ctors that reuse them - and they are recognisable from their own pattern: a
	 * capture that walks over a conditional-compilation directive must SPELL one.
	 *
	 * So the fixture reads every `@:re` under the grammar package, keeps the ones whose
	 * pattern mentions the `#if` / `#end` directives the shape itself declares, and asks that
	 * each carries one of the two markers. Pinned as a guard rather than as a killable fixture:
	 * it states a property of the grammar's own DECLARATIONS, which no cut of the engine can flip.
	 */
	@:pin('guard')
	public function testEveryDirectiveAwareTerminalCarriesItsMarker(): Void {
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		final directives: Array<String> = [shape.conditionalIfKeyword ?? '#if', shape.conditionalEndKeyword ?? '#end'];
		final marked: Array<String> = markedTypes(RAW_MARKER).concat(markedTypes(CONDITION_MARKER));
		Assert.isTrue(
			marked.length >= MIN_RAW_TERMINALS,
			'the marker scan found ${marked.length} tagged terminal(s) - below $MIN_RAW_TERMINALS the assertion below is vacuous'
		);
		final unmarked: Array<String> = [
			for (terminal => pattern in terminalPatterns()) if (!marked.contains(terminal) && directives.exists(directive ->
				pattern.indexOf(directive) != -1
			))
				terminal
		];
		Assert.equals(
			'', unmarked.join(','),
			'these terminals match over a conditional-compilation directive and carry neither $RAW_MARKER nor '
			+ '$CONDITION_MARKER, so every ctor built on one is invisible to the fail-closed gate'
		);
	}

	/**
	 * The region vocabulary is the raw-capture one WIDENED, not a second list beside it.
	 *
	 * `isConditionalKind` answers a question a dozen checks and rewrites ask before they
	 * descend, collect a span or call a statement complete, and until S175 it answered from
	 * three Haxe spellings hard-coded in the grammar-agnostic core - `Conditional`,
	 * `ConditionalExpr` and a `CondSplice` prefix. That was two sources of truth for one
	 * family, and the hand-written one was also INCOMPLETE: the same grammar declares
	 * `ConditionalArgs`, `ConditionalType`, `CondBody`, `CondSharedBodyDecl` and
	 * `MetaCondStmt`, every one of them a `#if` region and none of them matched.
	 */
	@:pin('control')
	@:killer('M-COND-REGION-KINDS-HARDCODED')
	public function testTheConditionalVocabularyIsTheRawCaptureOneWidened(): Void {
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		final missed: Array<String> = [
			for (kind in shape.opaqueCondRegionKinds ?? []) if (!CondRegionScan.isConditionalKind(kind, shape)) kind
		];
		Assert.equals('', missed.join(','), 'every raw-capture kind IS a conditional region; these were not reported as one');
		for (kind in [
			'Conditional',
			'ConditionalExpr',
			'ConditionalArgs',
			'ConditionalType',
			'CondBody'
		])
			Assert.isTrue(
				CondRegionScan.isConditionalKind(kind, shape),
				'the grammar declares $kind as a #if region and isConditionalKind does not report it - a check would '
				+ 'descend into branches that are alternatives, not siblings'
			);
		Assert.isFalse(CondRegionScan.isConditionalKind('IfStmt', shape), 'an ordinary if is not a conditional-compilation region');
	}

	/** The kinds `CondRegionScan` reports as opaque regions of `source`, in document order. */
	private static function regionKinds(source: String): Array<String> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return [
			for (region in CondRegionScan.opaqueCondRegions(plugin.parseFile(source), source, plugin.refShape())) region.kind
		];
	}

	/** The gap the fail-closed gate reports for `name`, or null when it reports none. */
	private static function mentionOf(source: String, name: String): Null<Span> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return CondRegionScan.opaqueCondRegionMentioning(plugin.parseFile(source), source, name, plugin.refShape());
	}

	/** The shared refusal every mutating op prints, spelled as `rename` spells its subject. */
	private static function diagnosticOf(source: String, name: String): Null<String> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return CondRegionScan.opaqueCondRegionDiagnostic(source, plugin.parseFile(source), name, plugin.refShape(), 'rename of "$name"');
	}

	/**
	 * The projected kinds whose own production reaches a `@:condRegionRaw` terminal, computed
	 * from the grammar's SOURCE and sorted - the independent twin of what the macro emits.
	 *
	 * Same rule as the macro's, arrived at by different machinery. A `@:peg` STRUCT that holds
	 * a marked terminal (directly or through another such struct) is tainted; an ENUM never is,
	 * because it is a dispatch point whose ctors each project their own node and each get their
	 * own verdict. So the answer is every enum ctor whose argument types reach the taint, plus
	 * the kind of any tainted struct that opted out of transparency with `@:spanned`.
	 */
	private static function rawCaptureKindsFromGrammarSource(): Array<String> {
		final refs: Map<String, Array<String>> = [];
		final ctors: Map<String, Array<String>> = [];
		final spanned: Map<String, String> = [];
		collectGrammarReferences(refs, ctors, spanned);
		final tainted: Array<String> = markedTypes(RAW_MARKER);
		var grew: Bool = true;
		while (grew) {
			grew = false;
			for (holder => referenced in refs) if (!tainted.contains(holder) && referenced.exists(name -> tainted.contains(name))) {
				tainted.push(holder);
				grew = true;
			}
		}
		final out: Array<String> = [];
		for (ctor => referenced in ctors) if (referenced.exists(name -> tainted.contains(name)) && !out.contains(ctor)) out.push(ctor);
		for (holder => kind in spanned) if (tainted.contains(holder) && !out.contains(kind)) out.push(kind);
		out.sort(Reflect.compare);
		return out;
	}

	/**
	 * One pass over the grammar package filling the three maps the closure above walks: a
	 * `@:peg` STRUCT's own field types (`refs`), an enum CTOR's argument types keyed by the
	 * ctor name (`ctors`), and the kind a `@:spanned` struct projects (`spanned`).
	 *
	 * Type positions are read from `parseFileTypeRefs`, the projection that exists precisely
	 * because the default tree drops them; a type reference nests (`Array<T>` reports both
	 * names), which is what makes a `Star` field's element type visible without any knowledge
	 * of collection shapes. A ctor's own types are the ones inside its span, so the walk keeps
	 * the enclosing ctor rather than matching on a name.
	 */
	private static function collectGrammarReferences(
		refs: Map<String, Array<String>>, ctors: Map<String, Array<String>>, spanned: Map<String, String>
	): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final typeKinds: Array<String> = plugin.typeRefShape().typeRefKinds;
		function typesUnder(node: QueryNode, into: Array<String>): Void {
			final name: Null<String> = node.name;
			if (name != null && typeKinds.contains(node.kind) && !into.contains(name)) into.push(name);
			for (child in node.children) typesUnder(child, into);
		}
		for (path in grammarSources('${CliFixture.repoRoot()}/$HAXE_GRAMMAR_DIR')) {
			final source: String = File.getContent(path);
			if (source.indexOf(PEG_MARKER) == -1) continue;
			final tree: QueryNode = plugin.parseFileTypeRefs(source);
			for (hit in Meta.find(tree, plugin.metaShape(), source)) {
				final owner: Null<String> = hit.declName;
				if (owner == null) continue;
				if (hit.annotation == SPANNED_MARKER && hit.args.length == 1) spanned[owner] = hit.args[0];
				// An ENUM is a dispatch point, not a container: its ctors are classified one by one
				// below, and taking its own name into the closure is the over-wide walk S167 rejected.
				if (hit.annotation != PEG_MARKER || hit.declKind == 'EnumDecl') continue;
				final into: Array<String> = [];
				for (node in nodesNamed(tree, owner)) typesUnder(node, into);
				refs[owner] = into;
			}
			collectCtorTypes(tree, ctors, typesUnder);
		}
	}

	/** Every enum ctor under `tree`, with the type names inside its own span - the per-ctor half of the scan. */
	private static function collectCtorTypes(
		tree: QueryNode, ctors: Map<String, Array<String>>, typesUnder: (QueryNode, Array<String>) -> Void
	): Void {
		function walk(node: QueryNode): Void {
			if (node.kind == 'ParamCtor' || node.kind == 'SimpleCtor') {
				final name: Null<String> = node.name;
				if (name != null) {
					final into: Array<String> = ctors[name] ?? [];
					typesUnder(node, into);
					ctors[name] = into;
				}
			}
			for (child in node.children) walk(child);
		}
		walk(tree);
	}

	/** Every node under `tree` whose display name is `name` - how a declaration's own subtree is reached from a `Meta` hit. */
	private static function nodesNamed(tree: QueryNode, name: String): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		function walk(node: QueryNode): Void {
			if (node.name == name) out.push(node);
			for (child in node.children) walk(child);
		}
		walk(tree);
		return out;
	}

	/** The type names carrying `marker` anywhere under the grammar package, read with the grammar's own parser. */
	private static function markedTypes(marker: String): Array<String> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final out: Array<String> = [];
		for (path in grammarSources('${CliFixture.repoRoot()}/$HAXE_GRAMMAR_DIR')) {
			final source: String = File.getContent(path);
			if (source.indexOf(marker) == -1) continue;
			for (hit in Meta.find(plugin.parseFile(source), plugin.metaShape(), source)) {
				final owner: Null<String> = hit.declName;
				if (owner != null && hit.annotation == marker && !out.contains(owner)) out.push(owner);
			}
		}
		out.sort(Reflect.compare);
		return out;
	}

	/** Every `@:re` terminal under the grammar package, mapped to the pattern it matches. */
	private static function terminalPatterns(): Map<String, String> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final out: Map<String, String> = [];
		for (path in grammarSources('${CliFixture.repoRoot()}/$HAXE_GRAMMAR_DIR')) {
			final source: String = File.getContent(path);
			if (source.indexOf('@:re') == -1) continue;
			for (hit in Meta.find(plugin.parseFile(source), plugin.metaShape(), source)) {
				final owner: Null<String> = hit.declName;
				if (owner != null && hit.annotation == '@:re' && hit.args.length == 1) out[owner] = hit.args[0];
			}
		}
		return out;
	}

	/** Every `.hx` under `dir`, recursively - the package has subdirectories and a new ctor may land in one. */
	private static function grammarSources(dir: String): Array<String> {
		final out: Array<String> = [];
		for (entry in FileSystem.readDirectory(dir)) {
			final path: String = '$dir/$entry';
			if (FileSystem.isDirectory(path))
				for (nested in grammarSources(path)) out.push(nested);
			else if (entry.endsWith('.hx'))
				out.push(path);
		}
		return out;
	}

}
