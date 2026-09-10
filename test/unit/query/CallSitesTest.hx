package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CallSites;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * `CallSites` — the completeness PROOF the signature-rewriting operations rest on, pinned
 * against the grammar vocabulary that decides it.
 *
 * The proof's failure mode is silent by construction: a call the collector does not see keeps
 * the old argument shape against the new parameters, at rc 0, in a file that still parses. So
 * every question here is asked in the direction it is allowed to fail in — a name that MIGHT be
 * ambiguous must refuse, a slot that might not be positionally rewritable must not be offered,
 * and a grammar that declares none of the shapes a call is recognised by must refuse rather
 * than prove an empty set complete.
 *
 * Each fixture supplies its own discriminating half by handing `collect` a MODIFIED shape: the
 * same source, the same call, one vocabulary field emptied. That is what separates "the rule is
 * right" from "the rule reads the grammar" — and, in the first fixture, it is also the measured
 * wrong answer the seventeen-name hand list used to give.
 */
@:nullSafety(Strict)
class CallSitesTest extends Test {

	/** The Haxe grammar's own vocabulary — the declaration under test. */
	private static final SHAPE: RefShape = new HaxeQueryPlugin().refShape();

	/**
	 * Two local functions named `helper` in sibling methods, one plain and one `inline`, each
	 * called once. Legal Haxe: the two bindings never meet, so nothing here is a duplicate
	 * declaration and no compiler complains — which is exactly why the ambiguity has to be
	 * caught by the collector.
	 */
	private static final AMBIGUOUS_LOCAL_FNS: String = 'class C {\n'
		+ '\tfunction a():Void {\n\t\tfunction helper(x:Int):Void {}\n\t\thelper(1);\n\t}\n\n'
		+ '\tfunction b():Void {\n\t\tinline function helper(x:Int):Void {}\n\t\thelper(2);\n\t}\n}\n';

	/**
	 * A second local function of the same name makes every bare call ambiguous, whichever
	 * spelling declares it.
	 *
	 * `Refs` does not index local functions, so this collector proves completeness from the
	 * NAME being unique across the file's declarations — and the vocabulary it asks that of used
	 * to be a seventeen-name hand list missing `LocalInlineFnStmt`. The second half of this
	 * fixture is that measurement rather than a description of it: handed a shape declaring no
	 * inline local-function kind, the same file reads as unique and BOTH calls come back as
	 * sites of the FIRST `helper` — the set `change-sig` reorders and `remove-param` deletes
	 * from, applied to a function whose signature is not theirs.
	 *
	 * CONTROL for the ambiguity vocabulary. KILLED by arm `M-NAME-CLASH-KINDS-NO-BINDERS`,
	 * which drops the binder half and restores the false proof for every binder spelling at once.
	 */
	@:pin('control')
	@:killer('M-NAME-CLASH-KINDS-NO-BINDERS')
	public function testASecondLocalFunctionOfTheSameNameRefusesTheProof(): Void {
		final source: String = AMBIGUOUS_LOCAL_FNS;
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		final decl: QueryNode = localFnDecl(tree);
		final from: Int = declFrom(decl);
		switch CallSites.collect(decl, tree, source, 'helper', from, SHAPE) {
			case CErr(message):
				Assert.stringContains('another declaration named "helper"', message);
			case COk(sites):
				Assert.fail('the ambiguous name was proven unique — ${sites.length} call site(s) collected as one function\'s');
		}
		final blind: RefShape = new HaxeQueryPlugin().refShape();
		blind.inlineFunctionKinds = [];
		switch CallSites.collect(decl, tree, source, 'helper', from, blind) {
			case COk(sites):
				Assert.equals(2, sites.length, 'the blind vocabulary collects both calls as one function\'s');
			case CErr(message):
				Assert.fail('the blind vocabulary should still have proven the set complete: $message');
		}
	}

	/**
	 * A variadic tail is not a positional parameter slot.
	 *
	 * `leadingParams` feeds the operations that PERMUTE or DELETE a parameter by index, and a
	 * rest parameter is neither reorderable (the language requires it last) nor deletable by
	 * argument position (it consumes zero or more arguments at each call). The exclusion was
	 * previously spelled by a two-name list stopping at everything else; it is now
	 * `paramKinds` minus `restParamKind`, and the second assertion is what makes that a real
	 * subtraction rather than a kind the vocabulary never carried.
	 */
	public function testLeadingParamsStopsAtTheVariadicTail(): Void {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile('class C {\n\tfunction m(a:Int, ?b:Int, ...r:Int):Void {}\n}\n');
		final decl: Null<QueryNode> = firstOfKind(tree, 'FnMember');
		if (decl == null) throw 'the fixture must declare a method';
		final names: Array<String> = [for (p in CallSites.leadingParams(decl, SHAPE)) p.name ?? '?'];
		Assert.same(['a', 'b'], names, 'a variadic tail is not a positional slot: $names');
		final rest: Null<String> = SHAPE.restParamKind;
		Assert.notNull(rest, 'the Haxe grammar declares a rest parameter spelling');
		if (rest != null)
			Assert.isTrue(
				(SHAPE.paramKinds ?? []).contains(rest), 'and it IS one of the declared parameter slots, so dropping it is a subtraction'
			);
	}

	/**
	 * A grammar declaring none of the shapes a call site is recognised by REFUSES, rather than
	 * proving an empty set complete.
	 *
	 * The fail-open direction of every optional vocabulary field, and the one that matters most
	 * here: with no call kind the walk matches nothing, reports zero sites and zero diagnostics,
	 * and every consumer reads that as "this function has no callers to keep in step".
	 */
	public function testAGrammarWithNoCallShapeRefusesInsteadOfProvingAnEmptySet(): Void {
		final source: String = AMBIGUOUS_LOCAL_FNS;
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		final decl: QueryNode = localFnDecl(tree);
		final from: Int = declFrom(decl);
		for (field in ['call kind', 'field-access kind', 'self-reference text']) {
			final blind: RefShape = new HaxeQueryPlugin().refShape();
			switch field {
				case 'call kind':
					blind.callKind = null;
				case 'field-access kind':
					blind.fieldAccessKind = null;
				case _:
					blind.selfReferenceText = null;
			}
			switch CallSites.collect(decl, tree, source, 'helper', from, blind) {
				case CErr(message):
					Assert.stringContains('declares no $field', message);
				case COk(sites):
					Assert.fail('a grammar with no $field proved ${sites.length} site(s) complete');
			}
		}
	}

	/** The single local function declaration of the fixture tree. */
	private static function localFnDecl(tree: QueryNode): QueryNode {
		final decl: Null<QueryNode> = firstOfKind(tree, 'LocalFnStmt');
		if (decl == null) throw 'the fixture must declare a local function';
		return decl;
	}

	/** The `from` offset of a declaration node, which every collector takes as its binding. */
	private static function declFrom(decl: QueryNode): Int {
		final span: Null<Span> = decl.span;
		if (span == null) throw 'the declaration must carry a span';
		return span.from;
	}

	/** The first node of `kind` in pre-order, or null. */
	private static function firstOfKind(node: QueryNode, kind: String): Null<QueryNode> {
		if (node.kind == kind) return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = firstOfKind(c, kind);
			if (hit != null) return hit;
		}
		return null;
	}

}
