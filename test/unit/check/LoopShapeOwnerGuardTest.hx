package unit.check;

import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import sys.io.File;
import unit.cli.CliFixture;

using Lambda;
using StringTools;

/**
 * Which child of an `if` / ternary / `while` / `for` node is its condition, branch, body or head is answered once, by
 * `BranchChain` and `LoopScan`. A rule of `anyparse.check` that declares its own child-count or slot-index constant for
 * one of those shapes holds a second copy of that answer, and two copies drift apart. The guard reads every declaration
 * of a name of that family outside the two owners; the generic child counts of other node shapes are a different family
 * and are not named here.
 */
@:nullSafety(Strict)
class LoopShapeOwnerGuardTest extends Test {

	/** The layer the guard reads, relative to the repository root. */
	private static inline final LAYER: String = 'src/anyparse/check';

	/** The two files that own the slot constants, relative to the repository root. */
	private static final OWNERS: Array<String> = ['$LAYER/common/control/BranchChain.hx', '$LAYER/scan/LoopScan.hx'];

	/** The declaration kinds that introduce a named constant or local. */
	private static final DECLARATION_KINDS: Array<String> = ['FinalMember', 'VarMember', 'FinalStmt', 'VarStmt'];

	/** The shapes whose slot constants the owners keep. */
	private static final SHAPE_PREFIXES: Array<String> = ['IF_', 'WHILE_', 'FOR_', 'TERNARY_'];

	/** The spellings a slot constant of those shapes takes. */
	private static final SLOT_SUFFIXES: Array<String> = ['_CHILD_COUNT', '_CHILDREN', '_INDEX'];

	@:pin('control') @:killer('M-LOOP-SHAPE-COUNT-REDECLARED')
	public function testNoRuleDeclaresItsOwnBranchOrLoopSlotConstant(): Void {
		final root: String = CliFixture.repoRoot();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final found: Array<String> = [];
		for (path in SourceTree.collect('$root/$LAYER').map(p -> p.substr(root.length + 1))) if (!OWNERS.contains(path)) {
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, File.getContent('$root/$path'));
			if (tree == null) continue;
			for (name in slotConstants(tree)) found.push('$path declares \'$name\'');
		}
		Assert.equals('', found.join('\n'), 'ask BranchChain / LoopScan which child is the condition, branch, body or head');
	}

	@:pin('guard')
	public function testAMemberSlotConstantIsReportedAndAGenericCountIsNot(): Void {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(
			new HaxeQueryPlugin(),
			'class C { private static inline final WHILE_CHILD_COUNT: Int = 2; private static inline final BINARY_CHILD_COUNT: Int = 2; }'
		);
		Assert.notNull(tree);
		if (tree != null) Assert.same(['WHILE_CHILD_COUNT'], slotConstants(tree));
	}

	/** The names of the slot constants `tree` declares. */
	private static function slotConstants(tree: QueryNode): Array<String> {
		final out: Array<String> = [];
		function visit(node: QueryNode): Void {
			final name: Null<String> = node.name;
			if (name != null && DECLARATION_KINDS.contains(node.kind) && isSlotConstant(name)) out.push(name);
			for (child in node.children) visit(child);
		}
		visit(tree);
		return out;
	}

	private static function isSlotConstant(name: String): Bool {
		return name == 'ELSE_SLOT_INDEX'
			|| name == 'COND_INDEX'
			|| name.endsWith('_BRANCH_INDEX')
			|| name.startsWith('RETURN_VALUE_')
			|| (SHAPE_PREFIXES.exists(p -> name.startsWith(p)) && SLOT_SUFFIXES.exists(x -> name.endsWith(x)));
	}

}
