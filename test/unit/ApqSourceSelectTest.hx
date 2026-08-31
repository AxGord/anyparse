package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.Engine;
import anyparse.query.Patch;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.ReplaceNode;
import anyparse.query.Selector;
import anyparse.query.SourceSlice;
import anyparse.query.format.Text;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The READ window for one addressed declaration, on both commands that print it: `apq source
 * --select <sel>` / `--at <line>:<col>`, which resolves a node address to the 1-based inclusive line
 * range spanning it, and `apq ast --select/--at --source|--doc`, whose byte window comes from the
 * same fold. They share `Cli.sourceWindows`, which is why the two live together here.
 *
 * `Cli.resolveNodeLineBounds` and `Cli.sourceWindows` are pure over their `content` / `source`
 * argument (they parse what is passed, not the path on disk), so both are tested directly via
 * `@:access`; the `Sys.print` rendering wiring and the CLI's own `--doc`/`--source` flag gating are
 * covered by manual e2e.
 */
@:access(anyparse.query.Cli)
@:nullSafety(Strict)
class ApqSourceSelectTest extends Test {

	private static final SRC: String = 'class C {\n\tfunction a(): Void {}\n\tfunction foo(x: Int): Int {\n\t\treturn x + 1;\n\t}\n}';

	/** `--select FnMember:foo` spans the whole multi-line function (lines 3-5). */
	public function testSelectByNameSpansFunction(): Void {
		assertBounds(SRC, 'FnMember:foo', 3, 5);
	}

	/** A single-line function resolves to one line. */
	public function testSelectSingleLineFunction(): Void {
		assertBounds(SRC, 'FnMember:a', 2, 2);
	}

	/**
	 * The window is the MODIFIER-FOLDED span — the one `replace-node` overwrites and the one
	 * `patch` searches, whose own doc already claimed "the same modifier-folded slice `apq
	 * source --select` prints". It did not: the read printed the bare node span, so a
	 * declaration whose annotation sat on its OWN line came back WITHOUT it, and feeding that
	 * text straight back to `replace-node` dropped the `@:keep` at rc 0. A one-line prefix hid
	 * the disagreement, because the window is widened to whole lines anyway.
	 */
	public function testSelectSpansALeadingAnnotationOnItsOwnLine(): Void {
		assertBounds('class C {\n\t@:keep\n\tpublic function f(): Void {}\n}', 'FnMember:f', 2, 3);
	}

	/**
	 * The same for the conditional DECL-KEYWORD prefix S41 taught `declGroupSpan` about: a
	 * replacement copied out of this read used to drop the `enum` of `enum abstract`, which is
	 * a compile-breaking silent edit rather than a lost annotation.
	 */
	public function testSelectSpansAConditionalDeclKeywordPrefix(): Void {
		assertBounds('#if (haxe_ver >= 4.2)\nenum\n#end\nabstract E(Int) {\n\tfinal A = 1;\n}', 'AbstractDecl:E', 1, 6);
	}

	/**
	 * CONTROL, green at base BY CONSTRUCTION: an ANNOTATION addressed on its OWN still prints
	 * alone. `declGroupSpan` stops at one (S36), so the read follows the ops there too — and
	 * a fold that walked forward off it would flip exactly this.
	 */
	public function testSelectOnTheAnnotationItselfStillSpansOnlyIt(): Void {
		assertBounds('class C {\n\t@:keep\n\tpublic function f(): Void {}\n}', 'Meta:@:keep', 2, 2);
	}

	/**
	 * RED at base — the window started at the `public` line — and a CONTROL in the other direction: the
	 * fold stops at the top of the modifier / annotation run and does NOT swallow the DOC block above it.
	 * The doc is trivia outside the node, `replace-node` does not overwrite it, and a read that printed
	 * it would hand back a replacement that duplicates the doc on the way in. Widening the window with
	 * `docExtendedSpan` — the obvious "print the whole element" over-fix — flips exactly this.
	 */
	public function testSelectStopsBelowTheDocBlock(): Void {
		assertBounds('class C {\n\t/**\n\t * About f.\n\t */\n\t@:keep\n\tpublic function f(): Void {}\n}', 'FnMember:f', 5, 6);
	}

	/** No match → null (the CLI maps this to a non-zero exit). */
	public function testSelectNoMatchReturnsNull(): Void {
		Assert.isNull(Cli.resolveNodeLineBounds('t.hx', SRC, 'haxe', 'FnMember:nope', null));
	}

	/** An ambiguous selector (two functions) → null. */
	public function testSelectAmbiguousReturnsNull(): Void {
		Assert.isNull(Cli.resolveNodeLineBounds('t.hx', SRC, 'haxe', 'FnMember', null));
	}

	/** `--at` resolves the innermost node at the 1-based position. */
	public function testAtPositionResolvesNode(): Void {
		// 2:11 is the `a` name token on line 2.
		final b: Null<{ from: Int, to: Int }> = Cli.resolveNodeLineBounds('t.hx', SRC, 'haxe', null, '2:11');
		Assert.notNull(b);
		if (b != null) Assert.equals(2, b.from);
	}

	/** A malformed position → null. */
	public function testAtMalformedReturnsNull(): Void {
		Assert.isNull(Cli.resolveNodeLineBounds('t.hx', SRC, 'haxe', null, 'nope'));
	}

	/** A malformed selector → null (caught, not an uncaught throw). */
	public function testSelectMalformedReturnsNull(): Void {
		Assert.isNull(Cli.resolveNodeLineBounds('t.hx', SRC, 'haxe', 'A>', null));
	}

	/**
	 * `ast --select --source` cut the BARE node span while this same address, through
	 * `apq source --select`, printed the modifier-folded one and `replace-node` overwrote it —
	 * so two reads of ONE declaration disagreed. `@:keep` and `public` were absent, and feeding
	 * that text straight back to `replace-node` dropped both at rc 0.
	 */
	public function testAstSourceWindowCarriesTheModifierRun(): Void {
		final src: String = 'class C {\n\t@:keep\n\tpublic function f(): Void {}\n}';
		Assert.equals('@:keep\n\tpublic function f(): Void {}', astWindowText(src, 'FnMember:f'));
	}

	/** The conditional decl-keyword prefix: what is dropped here is the `enum` of `enum abstract`. */
	public function testAstSourceWindowCarriesAConditionalDeclKeywordPrefix(): Void {
		final src: String = '#if (haxe_ver >= 4.2)\nenum\n#end\nabstract E(Int) {\n\tfinal A = 1;\n}';
		Assert.equals(src, astWindowText(src, 'AbstractDecl:E'));
	}

	/**
	 * The HOLE the two flags left between them: `--doc` walks BACK over the annotation lines to
	 * reach the comment and `--source` started BELOW them, so with both flags on the `@:keep`
	 * between the two blocks was printed by NEITHER. Asserted through `Text.renderMatches`, so the
	 * renderer's use of the window array is covered and not only the span arithmetic; the CLI's own
	 * flag gating and raw-vs-reshaped ordering stay manual e2e, as the class header says.
	 */
	public function testAstDocAndSourceTogetherLeaveNoGap(): Void {
		final src: String = 'class C {\n\t/** About f. */\n\t@:keep\n\tpublic function f(): Void {}\n}';
		final rendered: String = astRender(src, 'FnMember:f');
		Assert.isTrue(rendered.indexOf('About f.') >= 0, 'the doc block is missing: $rendered');
		Assert.isTrue(rendered.indexOf('@:keep') >= 0, 'the annotation is printed by neither block: $rendered');
		Assert.isTrue(rendered.indexOf('public function f') >= 0, 'the modifier is missing: $rendered');
	}

	/**
	 * CONTROL, green at base: an ANNOTATION addressed on its own still prints only itself, since
	 * `declGroupSpan` stops at one (S36). Removing that stop makes this window the whole
	 * `[@:keep public function f]` group and flips exactly this.
	 */
	public function testAstSourceOnTheAnnotationItselfPrintsOnlyIt(): Void {
		Assert.equals('@:keep', astWindowText('class C {\n\t@:keep\n\tpublic function f(): Void {}\n}', 'Meta:@:keep'));
	}

	/**
	 * A bare MODIFIER addressed on its own prints the DECLARATION it precedes, not its own five
	 * bytes: the cursor convention makes a modifier keyword the first token of the declaration it
	 * modifies, which is what every op already answers for that address (`declGroupSpan` walks
	 * FORWARD off it, and only off an annotation does it refuse to). RED at base, where the read
	 * handed back `public` alone while `replace-node` on the same address overwrote the whole
	 * member.
	 */
	public function testAstSourceOnAModifierPrintsTheDeclarationItPrecedes(): Void {
		final src: String = 'class C {\n\tpublic function f(): Void {}\n}';
		Assert.equals('public function f(): Void {}', astWindowText(src, 'Public'));
	}

	/**
	 * CONTROL, green at base: the window stops BELOW the doc block, exactly as
	 * `apq source --select` does — a read that swallowed the doc hands back a replacement that
	 * duplicates it. Widening `sourceWindows` with `docExtendedSpan`, the obvious "print the
	 * whole element" over-fix, flips this.
	 */
	public function testAstSourceStopsBelowTheDocBlock(): Void {
		final src: String = 'class C {\n\t/** About f. */\n\t@:keep\n\tpublic function f(): Void {}\n}';
		Assert.isFalse(astWindowText(src, 'FnMember:f').indexOf('About f.') >= 0);
	}

	/**
	 * A `@:trailOpt` declaration written WITHOUT its terminator parses with a span that runs on
	 * PAST its own closing brace — over the blank line and the NEXT declaration's doc comment,
	 * which the parser re-stashes as that neighbour's leading trivia (the 816bb666 family). The
	 * window is `trailingTrimmedSpan`-ed for that reason, in `Patch`'s own order; without the
	 * trim the read hands back a fragment carrying a neighbour's documentation and
	 * `replace-node` writes it straight back in.
	 */
	public function testAstSourceWindowStopsAtTheDeclarationsOwnEnd(): Void {
		final src: String = 'typedef A = {\n\tvar x:Int;\n}\n\n/** About B. */\ntypedef B = {\n\tvar y:Int;\n}\n';
		Assert.equals('typedef A = {\n\tvar x:Int;\n}', astWindowText(src, 'TypedefDecl:A'));
	}

	/**
	 * The fold repairs `--doc` as well, and for a shape where the base printed NOTHING: the
	 * backward walk that finds the comment crosses blank and `@…` lines only, so starting it below
	 * a `#if (haxe_ver >= 4.2) enum #end` prefix it hit the `#end` — neither blank nor an
	 * annotation — and gave up. Started at the `#if`, it reaches the block. RED at base with an
	 * EMPTY doc, which reads as "this declaration has none".
	 */
	public function testAstDocReachesPastAConditionalDeclKeywordPrefix(): Void {
		final src: String = '/**\n * About E.\n */\n#if (haxe_ver >= 4.2)\nenum\n#end\nabstract E(Int) {\n\tfinal X = 1;\n}\n';
		Assert.isTrue(astRender(src, 'AbstractDecl:E').indexOf('About E.') >= 0, 'the doc block was not found');
	}

	/**
	 * The trailing trim is skipped when the span's last byte cannot start a trim — the cheap guard
	 * that keeps the whole-file comment lex off a per-match caller. Two bytes CAN: whitespace, and
	 * the `/` closing a block comment the span swallowed. A guard narrowed to the newline alone
	 * passes every other pin in this suite and breaks both of these.
	 */
	public function testAstSourceWindowTrimsATrailingBlockCommentAndTrailingSpaces(): Void {
		Assert.equals('typedef A = {\n\tvar x:Int;\n}', astWindowText('typedef A = {\n\tvar x:Int;\n}\n\n/* note */', 'TypedefDecl:A'));
		Assert.equals('typedef A = {\n\tvar x:Int;\n}', astWindowText('typedef A = {\n\tvar x:Int;\n}   ', 'TypedefDecl:A'));
	}

	/**
	 * The promise this slice rests on, asserted rather than written down: for ONE addressed
	 * declaration, the span `replace-node` overwrites, the region `patch` searches inside, and the
	 * window `ast --select --source` prints are the same bytes. Four hand-copies of
	 * `trailingTrimmedSpan(declGroupSpan(...))` used to make that a prose claim, and a fifth site
	 * read the bare node span instead — which is how a replacement copied out of one read dropped
	 * the declaration's `@:keep` at rc 0. They share `RefactorSupport.declEditSpan` now.
	 */
	public function testEveryOpAddressingOneDeclarationSeesTheSameBytes(): Void {
		// Canonical under the compiled DEFAULT write options, so `replace-node`'s whole-file
		// canonicalisation cannot be what makes the round trip a no-op.
		final src: String = 'class C {\n\t@:keep\n\tpublic function f():Void {}\n}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(src);
		final node: Null<QueryNode> = Engine.select(tree, Selector.parse('FnMember:f'), plugin.selectKindEquivalence())[0];
		Assert.notNull(node);
		if (node == null) return;
		final span: Null<Span> = node.span;
		Assert.notNull(span);
		if (span == null) return;
		final window: String = SourceSlice.slice(src, RefactorSupport.declEditSpan(src, tree, node, span));
		Assert.equals('@:keep\n\tpublic function f():Void {}', window);
		// `patch` finds a fragment only inside the region it searches, so a fragment that exists
		// ONLY in the folded part proves the two regions are one.
		switch Patch.patchNode(src, ReplaceTarget.BySelector('FnMember:f'), '@:keep', '@:keep @:noCompletion', true, plugin) {
			case Ok(text):
				Assert.isTrue(text.indexOf('@:noCompletion') >= 0, text);
			case Err(message):
				Assert.fail('patch did not search the folded region: $message');
		}
		// `replace-node` overwrites the same region, so resending the window verbatim is a no-op.
		switch ReplaceNode.replaceNode(src, ReplaceTarget.BySelector('FnMember:f'), window, true, plugin) {
			case Ok(text):
				Assert.equals(src, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * Assert the resolved window for `selector` over `src` is exactly lines `from`..`to`.
	 *
	 * The null re-check is not defensive: `resolveNodeLineBounds` answers `Null<…>` for every
	 * refusal path, and Strict will not narrow the local across the assertion.
	 */
	private function assertBounds(src: String, selector: String, from: Int, to: Int): Void {
		final bounds: Null<{ from: Int, to: Int }> = Cli.resolveNodeLineBounds('t.hx', src, 'haxe', selector, null);
		Assert.notNull(bounds);
		if (bounds == null) return;
		Assert.equals(from, bounds.from);
		Assert.equals(to, bounds.to);
	}

	/** The `--source` window text `ast --select` prints for the sole match of `selector`. */
	private function astWindowText(src: String, selector: String): String {
		final resolved: AstSelection = astSelect(src, selector);
		Assert.equals(1, resolved.matches.length, 'selector "$selector" did not resolve to exactly one node');
		return resolved.matches.length == 1 ? SourceSlice.slice(src, Cli.sourceWindows(resolved.tree, resolved.matches, src)[0]) : '';
	}

	/** `ast --select --doc --source` rendered exactly as the text formatter emits it. */
	private function astRender(src: String, selector: String): String {
		final resolved: AstSelection = astSelect(src, selector);
		return Text.renderMatches(resolved.matches, src, Cli.sourceWindows(resolved.tree, resolved.matches, src), true, true);
	}

	/** Parse `src` and resolve `selector` against it — what `ast --select` does before it renders. */
	private function astSelect(src: String, selector: String): AstSelection {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(src);
		return { tree: tree, matches: Engine.select(tree, Selector.parse(selector), plugin.selectKindEquivalence()) };
	}

}

/** A parsed source and the nodes one selector resolved against it. */
private typedef AstSelection = {
	final tree: QueryNode;
	final matches: Array<QueryNode>;
};
