package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.RemoveMember;
import utest.Assert;
import utest.Test;

/**
 * `RemoveMember.removeMember` — remove a field / method by its type and
 * name, the by-name wrapper over `RemoveElement`. The removal itself is
 * covered by `RemoveElementSliceTest`; here the focus is resolution: the
 * named member of the named type is removed (including in a `final class`),
 * the siblings survive, and an unknown type or member is refused.
 */
class RemoveMemberSliceTest extends Test {

	/** An unknown type is refused. */
	public inline function testTypeNotFound(): Void {
		assertErr('class C {\n\tvar x:Int;\n}\n', 'Nope', 'x');
	}

	/** An unknown member is refused. */
	public inline function testMemberNotFound(): Void {
		assertErr('class C {\n\tvar x:Int;\n}\n', 'C', 'nope');
	}

	/**
	 * A field of an anonymous structure written as a member's TYPE is not a member of the
	 * enclosing class. Matching it deleted the field out of the annotation and left
	 * `cfg:{}` — a silent Ok that no longer type-checks.
	 */
	public inline function testAnonStructureFieldInMemberTypeIsRefused(): Void {
		assertErr('class C {\n\tvar cfg:{ var inner:Int; } = { inner: 1 };\n}\n', 'C', 'inner');
	}

	/** Remove a method by name; the sibling member survives. */
	public function testRemoveMethod(): Void {
		final source: String = 'class C {\n\tvar keep:Int;\n\tpublic function drop():Void {}\n}\n';
		final text: String = okText(source, 'C', 'drop');
		Assert.isTrue(text.indexOf('drop') == -1);
		Assert.isTrue(text.indexOf('keep') >= 0);
	}

	/** Remove a field by name; the sibling method survives. */
	public function testRemoveVar(): Void {
		final source: String = 'class C {\n\tvar drop:Int;\n\tpublic function keep():Void {}\n}\n';
		final text: String = okText(source, 'C', 'drop');
		Assert.isTrue(text.indexOf('drop') == -1);
		Assert.isTrue(text.indexOf('keep') >= 0);
	}

	/**
	 * A member that is the ONLY declaration of its `#if` region takes the region with it. Cutting
	 * just the member left the bare `#if … #end` behind — syntax that compiles, that the writer
	 * re-emits verbatim, and that no check reports, so nothing would ever have flagged it.
	 */
	public function testSoleMemberOfRegionTakesTheRegion(): Void {
		final source: String = 'class C {\n\tvar keep:Int;\n\t#if !mobile\n\tpublic function drop():Void {}\n\t#end\n}\n';
		final text: String = okText(source, 'C', 'drop');
		Assert.isTrue(text.indexOf('drop') == -1 && text.indexOf('#if') == -1 && text.indexOf('keep') >= 0);
	}

	/**
	 * A region whose OTHER branch still declares something keeps its directives — the branches are
	 * alternatives, so the surviving one needs them.
	 */
	public function testRegionWithASurvivingBranchKeepsItsDirectives(): Void {
		final source: String =
			'class C {\n\t#if mobile\n\tpublic function drop():Void {}\n\t#else\n\tpublic function keep():Void {}\n\t#end\n}\n';
		final text: String = okText(source, 'C', 'drop');
		Assert.isTrue(text.indexOf('drop') == -1 && text.indexOf('#if mobile') >= 0 && text.indexOf('keep') >= 0);
	}

	/** A member of a `final class` resolves through the final-aware type lookup. */
	public function testRemoveFinalClassMember(): Void {
		final source: String = 'final class C {\n\tvar keep:Int;\n\tvar drop:Int;\n}\n';
		final text: String = okText(source, 'C', 'drop');
		Assert.isTrue(text.indexOf('drop') == -1);
		Assert.isTrue(text.indexOf('keep') >= 0);
	}

	/** `--with-doc` removes the member's leading doc comment with it (no orphan). */
	public function testRemoveMemberWithDoc(): Void {
		final source: String = 'class C {\n\t/** doc */\n\tpublic function drop():Void {}\n\tvar keep:Int;\n}\n';
		switch RemoveMember.removeMember(source, 'C', 'drop', true, new HaxeQueryPlugin(), true) {
			case Ok(text):
				Assert.isTrue(text.indexOf('doc') == -1);
				Assert.isTrue(text.indexOf('drop') == -1);
				Assert.isTrue(text.indexOf('keep') >= 0);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * A doc whose TEXT contains a backticked block-comment opener is still ONE comment
	 * token, so the whole doc goes with the member and the neighbour's doc is untouched.
	 * The lexical `lastIndexOf('/*')` this used to do cut the doc at that literal.
	 */
	public function testRemoveMemberWithDocContainingBlockOpener(): Void {
		final source: String = docFixture('`//` or `/*`');
		switch RemoveMember.removeMember(source, 'A', 'victim', true, new HaxeQueryPlugin(), true) {
			case Ok(text):
				Assert.isTrue(text.indexOf('victim') == -1, text);
				Assert.isTrue(text.indexOf('Whether the gap') == -1, text);
				Assert.isTrue(text.indexOf("The next member's own doc.") >= 0, text);
				Assert.isTrue(text.indexOf('neighbor') >= 0, text);
				assertBalancedComments(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/** Same defect shape with a backticked DOC opener in the text. */
	public function testRemoveMemberWithDocContainingDocOpener(): Void {
		final source: String = docFixture('a nested `/**` marker');
		switch RemoveMember.removeMember(source, 'A', 'victim', true, new HaxeQueryPlugin(), true) {
			case Ok(text):
				Assert.isTrue(text.indexOf('Whether the gap') == -1, text);
				Assert.isTrue(text.indexOf("The next member's own doc.") >= 0, text);
				assertBalancedComments(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * A literal `*` followed by `/` CLOSES a Haxe block comment, so a doc claiming to
	 * contain one never parses in the first place — the op refuses the source outright
	 * rather than mangling it. Locks in that the fix does not try to be clever about a
	 * sequence the language itself cannot express.
	 */
	public function testDocWithLiteralCloserIsUnparseable(): Void {
		assertErr(docFixture('a literal `*/` closer and no'), 'A', 'victim');
	}

	/**
	 * The same doc on the LAST member of the class. The lexical scan produced an
	 * unterminated fragment here too, but the reparse guard caught it and the op refused
	 * with "result does not parse" — an incidental refusal, not a gate. It now succeeds.
	 */
	public function testRemoveLastMemberWithDocContainingBlockOpener(): Void {
		final source: String = 'class A {\n\n\tvar keep:Int;\n\n\t/**\n\t * Whether the gap holds a `//` or `/*` opener.\n\t */\n'
			+ '\tprivate function victim():Bool {\n\t\treturn true;\n\t}\n\n}\n';
		switch RemoveMember.removeMember(source, 'A', 'victim', true, new HaxeQueryPlugin(), true) {
			case Ok(text):
				Assert.isTrue(text.indexOf('victim') == -1, text);
				Assert.isTrue(text.indexOf('Whether the gap') == -1, text);
				Assert.isTrue(text.indexOf('keep') >= 0, text);
				assertBalancedComments(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/** Control: a typedef's own fields ARE its members and stay removable. */
	public function testTypedefFieldIsRemovable(): Void {
		final text: String = okText('typedef Td = {\n\tvar x:Int;\n\tvar y:String;\n}\n', 'Td', 'x');

		Assert.isTrue(text.indexOf('x') == -1, text);
		Assert.isTrue(text.indexOf('y') >= 0, text);
	}

	/**
	 * A name declared once per branch of one region is ONE logical member: both declarations go,
	 * and the region — now holding nothing — goes with them. The assertion spans both halves in
	 * one string, so it cannot pass on a run that removed only the first declaration.
	 */
	public function testBranchPairRemovesBothDeclarationsAndTheRegion(): Void {
		final source: String = 'class C {\n\t#if mobile\n\tpublic function drop():Void {}\n\t#else\n'
			+ '\tpublic function drop():Int return 1;\n\t#end\n\tvar keep:Int;\n}\n';
		final text: String = okText(source, 'C', 'drop');
		Assert.equals('class C {\n\tvar keep:Int;\n}\n', text);
	}

	/** Three branches, one name in each — all three go, and so does the region. */
	public function testThreeBranchNameRemovesEveryDeclaration(): Void {
		final source: String =
			'class C {\n\t#if a\n\tvar drop:Int;\n\t#elseif b\n\tvar drop:String;\n\t#else\n\tvar drop:Bool;\n\t#end\n\tvar keep:Int;\n}\n';
		final text: String = okText(source, 'C', 'drop');
		Assert.equals('class C {\n\tvar keep:Int;\n}\n', text);
	}

	/**
	 * A region that still holds another member keeps its directives, even though the removed name
	 * appeared in two of its branches — the region-emptied rule counts what SURVIVES, not how many
	 * declarations this call takes.
	 */
	public function testRegionKeepingAnotherMemberSurvivesABranchPairRemoval(): Void {
		final source: String = 'class C {\n\t#if mobile\n\tvar drop:Int;\n\n\tvar stay:Int;\n\t#else\n\tvar drop:Bool;\n\t#end\n}\n';
		final text: String = okText(source, 'C', 'drop');
		Assert.isTrue(
			text.indexOf('drop') == -1 && text.indexOf('#if mobile') >= 0 && text.indexOf('stay') >= 0,
			'the surviving member must keep its region: $text'
		);
	}

	/**
	 * A region NESTED inside one that is also emptied is left to the outer removal. Splicing both
	 * would delete the code that follows the outer region, because the two spans nest and the inner
	 * splice shifts the coordinates the outer one was measured in — silently, since the wreckage
	 * still parses. The trailing members are what such a run destroys, so they carry the assertion.
	 */
	public function testNestedEmptiedRegionIsRemovedOnceNotTwice(): Void {
		final source: String = 'class C {\n\t#if a\n\tvar drop:Int;\n\n\t#if b\n\tvar drop:String;\n\t#end\n\t#end\n\tvar first:Int;\n\n'
			+ '\tvar second:Int;\n}\n';
		final text: String = okText(source, 'C', 'drop');
		Assert.equals('class C {\n\tvar first:Int;\n\n\tvar second:Int;\n}\n', text);
	}

	/**
	 * A member of an INNER region is a member of the outer one too, so emptying the inner empties
	 * both. Counting only the region's DIRECT children stopped at the inner one and left the outer
	 * `#if a … #end` behind as a husk guarding nothing — visible only once the parser learned to
	 * accept an emptied member-position region, which it now does. `MemberBranchScan.regionMembers`
	 * is the shared count that reaches through the nesting; the walk climbs while it stays empty.
	 */
	public function testNestedSoleMemberTakesTheOuterRegionToo(): Void {
		final source: String = 'class C {\n\t#if a\n\t#if b\n\tvar drop:Int;\n\t#end\n\t#end\n\tvar keep:Int;\n}\n';
		Assert.equals('class C {\n\tvar keep:Int;\n}\n', okText(source, 'C', 'drop'));
	}

	/** The same nesting in LAST position, where the husk would have had no member after it. */
	public function testNestedSoleMemberInLastPositionTakesTheOuterRegionToo(): Void {
		final source: String = 'class C {\n\tvar keep:Int;\n\t#if a\n\t#if b\n\tvar drop:Int;\n\t#end\n\t#end\n}\n';
		Assert.equals('class C {\n\tvar keep:Int;\n}\n', okText(source, 'C', 'drop'));
	}

	/**
	 * Repeating a name OUTSIDE a conditional region is not legal Haxe, so the source is already
	 * rejected by the compiler — removing both would launder that, and the refusal names it.
	 */
	public function testUnguardedDuplicateNameIsRefused(): Void {
		final source: String = 'class C {\n\tvar drop:Int;\n\n\tvar drop:String;\n}\n';
		assertErr(source, 'C', 'drop');
	}

	/** One conditional declaration and one unguarded: the pair cannot compile, so it is refused too. */
	public function testMixedGuardedAndUnguardedDuplicateIsRefused(): Void {
		final source: String = 'class C {\n\t#if a\n\tvar drop:Int;\n\t#end\n\tvar drop:String;\n}\n';
		assertErr(source, 'C', 'drop');
	}

	/**
	 * The shared multi-node delete keeps only the OUTERMOST of nesting targets. `remove-member`
	 * hands it exactly that shape from nested regions, and splicing both would run the second on
	 * coordinates the first already shifted — deleting whatever follows the outer node while the
	 * wreckage still parses, so nothing downstream would notice. The surviving member carries the
	 * assertion, since it is what such a run destroys.
	 */
	public function testDeleteNodesKeepsOnlyTheOutermostOfNestingTargets(): Void {
		final source: String = 'class C {\n\t#if a\n\tvar drop:Int;\n\t#end\n\tvar keep:Int;\n}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		var region: Null<QueryNode> = null;
		var member: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			if (node.kind == 'Conditional') region = node;
			if (node.kind == 'VarMember' && node.name == 'drop') member = node;
			for (child in node.children) walk(child);
		}
		walk(tree);
		final regionNN: QueryNode = region ?? throw 'the fixture must hold a conditional region';
		final memberNN: QueryNode = member ?? throw 'the fixture must hold the guarded member';
		final targets: Array<{ node: QueryNode, parent: Null<QueryNode> }> = [
			{ node: regionNN, parent: tree },
			{ node: memberNN, parent: regionNN }
		];
		switch RefactorSupport.deleteNodes(source, targets, true, plugin) {
			case Ok(text):
				Assert.equals('class C {\n\tvar keep:Int;\n}\n', text);
			case Err(message):
				Assert.fail('nesting targets must collapse to the outer one, got Err: $message');
		}
	}

	/** The round-2 repro: a doc'd `victim` whose text carries `marker`, followed by a doc'd `neighbor`. */
	private function docFixture(marker: String): String {
		return 'class A {\n\n\t/**\n\t * Whether the gap holds $marker comment opener.\n\t */\n\tprivate function victim():Bool {\n'
			+ '\t\treturn true;\n\t}\n\n\t/**\n\t * The next member\'s own doc.\n\t */\n\tprivate function neighbor():Bool {\n'
			+ '\t\treturn false;\n\t}\n\n}\n';
	}

	/** Every block-comment opener in `text` is matched by a closer — the orphan-doc signature. */
	private function assertBalancedComments(text: String): Void {
		var opens: Int = 0;
		var closes: Int = 0;
		for (i in 0...text.length - 1) {
			if (text.charAt(i) == '/' && text.charAt(i + 1) == '*') opens++;
			if (text.charAt(i) == '*' && text.charAt(i + 1) == '/') closes++;
		}
		Assert.equals(closes, opens, text);
	}

	private function okText(source: String, typeName: String, memberName: String): String {
		switch RemoveMember.removeMember(source, typeName, memberName, true, new HaxeQueryPlugin()) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

	private function assertErr(source: String, typeName: String, memberName: String): Void {
		switch RemoveMember.removeMember(source, typeName, memberName, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.fail('expected Err, got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

}
