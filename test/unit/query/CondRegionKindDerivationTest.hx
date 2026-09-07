package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CondRegionScan;
import anyparse.query.GrammarPlugin.RefShape;
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
 * How the fail-closed gate over an UNPARSED `#if` region learns WHICH ctors carry one, and
 * why that is asked of the grammar rather than of a list somebody keeps.
 *
 * `RefShape.opaqueCondRegionKindPrefixes` used to be an exhaustive list of ctor names, and it was
 * stale within two days of shipping: the gate landed 2026-08-18 naming ten `CondSplice*` ctors,
 * and 2026-08-20 the grammar gained three more raw-capture ctors - `CondSpliceReturnStmt`,
 * `CondSpliceReturnExpr` and `MetaCondStmt`. Nothing connects the two edits, nothing failed, and
 * for eighteen days every name-driven mutating op wrote SILENTLY over such a region - the
 * reproducer below renames a declaration and leaves its only other reference on the old
 * name, which compiles until someone builds with the flag defined.
 *
 * So the field is read as PREFIXES. The family is `CondSplice`, the two ctors outside that convention are spelled
 * in full, and a ctor added to the family lands in the gate with no edit here - which is the property the coverage
 * test asserts against the grammar's own source. What it cannot assert is a ctor named outside every convention so
 * far used; `MetaCondStmt` is one, it is pinned by fixture rather than derived, and T796 carries the gap.
 *
 * The guard fixture is the other half. Widening a fail-CLOSED gate buys refusals, and a
 * refusal on a region the model DOES resolve is pure loss: a balanced `Conditional` and a
 * `CondSpliceOpExpr` both keep their references as real nodes, every op rewrites them
 * correctly today, and both must stay invisible to this scan.
 */
@:nullSafety(Strict)
class CondRegionKindDerivationTest extends Test {

	/** The grammar package whose ctor names the gate is derived from. */
	private static inline final HAXE_GRAMMAR_DIR: String = 'src/anyparse/grammar/haxe';

	/**
	 * The raw-capture family's name, spelled HERE rather than read from the shape under test.
	 *
	 * That is the whole discipline of the check below: filtering the grammar scan by the
	 * shape's own entries and then asserting the shape covers what came back is a tautology -
	 * every ctor found by a prefix is trivially covered by that prefix. The test states the
	 * grammar's naming convention independently, so a family member the shape does NOT name
	 * still reaches the assertion.
	 */
	private static inline final SPLICE_CTOR_PREFIX: String = 'CondSplice';

	/** Below this the ctor scan found nothing to compare and every assertion over it would pass vacuously. */
	private static inline final MIN_SPLICE_CTORS: Int = 12;

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
	 * The derivation, checked against the grammar it is derived FROM - the assertion that
	 * makes the historical desync unrepeatable.
	 *
	 * Every conditional-splice ctor the Haxe grammar declares must be covered by the shape,
	 * and every entry of the shape must cover at least one declared ctor. The first direction
	 * is the defect this class exists for; the second catches an entry left behind by a ctor
	 * rename, which would leave the gate looking configured while matching nothing.
	 */
	@:pin('control')
	@:killer('M-OPAQUE-REGION-HAND-LIST')
	public function testEverySpliceCtorTheGrammarDeclaresIsCoveredByTheShape(): Void {
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		final family: Array<String> = grammarCtorsNamed(SPLICE_CTOR_PREFIX);
		Assert.isTrue(
			family.length >= MIN_SPLICE_CTORS,
			'the scan of $HAXE_GRAMMAR_DIR found ${family.length} ctor(s) named $SPLICE_CTOR_PREFIX* - '
			+ 'below $MIN_SPLICE_CTORS the comparisons below would pass vacuously'
		);
		for (ctor in family)
			Assert.isTrue(
				CondRegionScan.isOpaqueCondRegionKind(ctor, shape),
				'the grammar declares $ctor and no opaqueCondRegionKindPrefixes entry covers it - a name-driven op would '
				+ 'rewrite around such a region in silence; extend the prefixes in HaxeQueryPlugin.refShape'
			);
		for (prefix in shape.opaqueCondRegionKindPrefixes ?? [])
			Assert.isTrue(
				grammarCtorsNamed(prefix).length > 0,
				'opaqueCondRegionKindPrefixes carries "$prefix" and no ctor under $HAXE_GRAMMAR_DIR starts with it - '
				+ 'the entry is stale, most likely left behind by a ctor rename'
			);
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
	 * Every enum ctor declared under `HAXE_GRAMMAR_DIR` whose name starts with `prefix`, read out of the grammar with the
	 * grammar's own parser. `prefix` comes from this class, never from the shape under test - see `SPLICE_CTOR_PREFIX` for why.
	 *
	 * Only files whose TEXT mentions it are parsed: the package is 262 modules, 37 of them mention `CondSplice` and five DECLARE a member
	 * of that family, while a module that gains one necessarily gains the text too. A ctor projects a node whose kind IS its name, so the
	 * scan reads `ParamCtor` / `SimpleCtor` names and needs no knowledge of enum shape.
	 */
	private static function grammarCtorsNamed(prefix: String): Array<String> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final out: Array<String> = [];
		function collect(node: QueryNode): Void {
			final name: Null<String> = node.name;
			if (name != null && (node.kind == 'ParamCtor' || node.kind == 'SimpleCtor') && name.startsWith(prefix) && !out.contains(name))
				out.push(name);
			for (child in node.children) collect(child);
		}
		for (path in grammarSources('${CliFixture.repoRoot()}/$HAXE_GRAMMAR_DIR')) {
			final source: String = File.getContent(path);
			if (source.indexOf(prefix) == -1) continue;
			collect(plugin.parseFile(source));
		}
		out.sort(Reflect.compare);
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
