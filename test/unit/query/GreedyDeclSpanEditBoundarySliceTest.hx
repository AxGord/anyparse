package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ElementSpan;
import anyparse.query.Engine;
import anyparse.query.Patch;
import anyparse.query.QueryNode;
import anyparse.query.ReplaceNode;
import anyparse.query.Selector;
import anyparse.query.SourceSlice;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * A MODULE-level declaration's raw span reaches to the start of the next declaration, so it
 * owns the bytes between them — including the next declaration's own doc comment. Census over
 * this tree: 1013 of 14 055 module-level declarations (7.2%) have a span longer than their own
 * last token, 5062 lines / 239 001 bytes in total, worst single 140 lines
 * (`TypedefDecl` in `src/anyparse/check/PreferMapType.hx`); 668 of them are `FinalDecl`, 345
 * `TypedefDecl`, and no other kind. Member spans are tight, which is why the asymmetry keeps
 * being rediscovered as a bug in the READING commands.
 *
 * It is not one, and that is what this suite pins: every op addressed at such a declaration
 * goes through `ElementSpan.declEditSpan`, whose `trailingTrimmedSpan` walks the swallowed
 * whitespace and comments back off before anything reads or writes them. The report that
 * started the slice measured a 2648-line `--select 'TypedefDecl:RefShape'` window and read it
 * as the greedy span; `RefShape` is a genuinely 2648-line declaration, and the window was
 * exactly its own bytes.
 *
 * `testAGreedyModuleDeclSpanIsTrimmedToItsOwnLastToken` is the control: the other two are about
 * ops behaving, and both pass trivially against a fixture whose raw span is not greedy in the
 * first place — so the control asserts the greediness itself before asserting the trim.
 */
class GreedyDeclSpanEditBoundarySliceTest extends Test {

	/**
	 * `A`'s raw span runs to `B`'s first byte, so it holds `B`'s doc comment; `A`'s own last
	 * token is the `}` three lines earlier. Written without the optional `;` after the closing
	 * brace, which is what makes the span greedy — the terminated spelling ends tight.
	 */
	private static final GREEDY: String = 'typedef A = {\n\tvar x:Int;\n}\n\n/**\n * Doc of B.\n */\ntypedef B = {\n\tvar y:Int;\n}\n';

	/**
	 * KILLED by arm `M-DECL-EDIT-SPAN-UNTRIMMED`, which hands the raw span back untouched —
	 * every op addressed at `A` then owns `B`'s doc for reading and for writing alike.
	 */
	@:pin('control')
	@:killer('M-DECL-EDIT-SPAN-UNTRIMMED')
	public function testAGreedyModuleDeclSpanIsTrimmedToItsOwnLastToken(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(GREEDY);
		final node: Null<QueryNode> = Engine.select(tree, Selector.parse('TypedefDecl:A'), plugin.selectKindEquivalence())[0];
		Assert.notNull(node);
		if (node == null) return;
		final span: Null<Span> = node.span;
		Assert.notNull(span);
		if (span == null) return;
		// The fixture is worth nothing unless the RAW span really does swallow the neighbour,
		// so that half is asserted rather than assumed: a grammar change that made module
		// spans tight would otherwise leave this suite green and meaningless.
		Assert.isTrue(GREEDY.substring(span.from, span.to).indexOf('Doc of B') >= 0, 'the raw span no longer reaches the neighbour');
		Assert.equals(
			'typedef A = {\n\tvar x:Int;\n}',
			SourceSlice.slice(GREEDY, ElementSpan.declEditSpan(GREEDY, tree, node, span, plugin.lexicalRegions.bind(GREEDY)))
		);
	}

	/**
	 * `patch` searches inside the SAME folded slice, so a fragment that exists only in the
	 * swallowed bytes is absent — the refusal is the op declining to edit a neighbour it was
	 * never addressed at.
	 */
	public function testPatchAddressedAtTheGreedyDeclCannotReachTheNeighboursDoc(): Void {
		switch Patch.patchNode(GREEDY, ReplaceTarget.BySelector('TypedefDecl:A'), 'Doc of B', 'HIJACKED', true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.fail('the patch reached past the declaration it addressed:\n$text');
			case Err(message):
				Assert.stringContains('does not occur in the resolved', message);
		}
	}

	/**
	 * `replace-node` overwrites the same folded slice. The whole result carries the assertion:
	 * the added field only a successful replace produces, and `B` with its doc intact, in one
	 * string — so neither a no-op nor a run that ate the neighbour can satisfy it.
	 */
	public function testReplaceNodeOnTheGreedyDeclLeavesTheNeighbourWhole(): Void {
		final replacement: String = 'typedef A = {\n\tvar x:Int;\n\tvar z:Int;\n}';
		switch ReplaceNode.replaceNode(GREEDY, ReplaceTarget.BySelector('TypedefDecl:A'), replacement, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals(
					'typedef A = {\n\tvar x:Int;\n\tvar z:Int;\n}\n\n/**\n * Doc of B.\n */\ntypedef B = {\n\tvar y:Int;\n}\n', text
				);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

}
