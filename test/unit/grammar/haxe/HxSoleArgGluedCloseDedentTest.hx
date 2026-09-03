package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * omega-glued-close-opener-line: a run of close delimiters at the start of a
 * line may only be glued together when the delimiters they close were opened
 * on the SAME line.
 *
 * The defect this closes: `WrapList.shapeSingleArgGlue` built its glued shape
 * as `open + arg + close`, appending the call's own closer wherever the sole
 * argument's last rendered line left the pen. For an object / array literal or
 * a nested call that is the argument's own base indent — they emit their close
 * delimiter OUTSIDE their content `Nest` — and the glue is right. A ternary or
 * value-`if` closes its last branch INSIDE its `? :` continuation nest, one
 * level deeper, so the call's `)` landed one indent BELOW its own `(`:
 *
 * ```
 * kind: FFun(setcontroll        <- `(` opens at 6 tabs
 *     ? { ... }
 *     : {                       <- `{` opens at 7 tabs
 *         ...
 *     })                        <- `}` right at 7; `)` one level too deep
 * ```
 *
 * Found on a real formatter run over a 153-file tree, where two sites regressed
 * against what the same tree held before the run and one more had carried the
 * shape by hand.
 *
 * SCOPE — sole-argument lists, which is all this shaper is ever reached for. A
 * MULTI-argument list closing on a trailing lambda or object hug
 * (`f(a, e -> {\n\t...\n})`, `if (c && f(x ->\n\t...\n))`) glues a closer below its
 * opener too, and there that shape is WANTED: nine corpus fixtures pin it. A
 * renderer-wide reading of the same invariant, tried first, broke every one of
 * them, which is why the rule lives at this one shape decision instead.
 *
 * MEASURE — `DocMeasure.breakTailCloseNest` reports the `Nest` depth of the
 * argument's broken-tail closing line, or `-1` when the tail is not a closing
 * line at all. It is structural, never a width probe, so no render-time
 * decision can move a call's shape. Whether such a construct breaks at its
 * `? :` at all IS a width decision though, so the walk necessarily reads a slot
 * the output may not take, so the rule is bounded to closing lines opened by a
 * BRACE and the bracket fixture below is that bound's discriminator.
 *
 * The bound is asked twice, and only one half is pinned. `breakTailCloseNest`
 * tests it INSIDE its own walk (authoritative — same slot as the depth), while
 * `DocMeasure.endsWithCloseBrace` runs in front of it purely to skip that walk
 * cheaply, resolving `If*` to the flat slot. Removing BOTH turns the bracket
 * fixture red; removing only the in-walk one turns NOTHING red, because no
 * shape in the corpus, this tree or the Pony tree closes on different
 * delimiters in its two slots. That half is therefore carried on argument, not
 * on evidence — said here so the next reader does not mistake it for tested.
 *
 * The fixtures are `+`-split across lines to stay inside the line limit, which
 * `fold-adjacent-string-literals` reports three times (info severity, hidden
 * without `--all`). Merging them is what the limit forbids, so they stay — the
 * same trade `HxCallParamOuterFirstWrapSliceTest` documents for its own ~130.
 */
@:nullSafety(Strict)
final class HxSoleArgGluedCloseDedentTest extends Test {

	/**
	 * Reduced from the real project config by removing every section that leaves
	 * the four fixtures byte-identical: what is left is what the decision reads —
	 * `maxLineLength`, the `callParameter` cascade that selects
	 * `fillLineWithLeadingBreak`, the `objectLiteral` explode rule, and the brace
	 * spacing the expectations are written in.
	 */
	private static final CFG: String = '{"indentation": {}, "emptyLines": {"classEmptyLines": {"beginType": 1, "endType": 1}}, '
		+ '"wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", '
		+ '"rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {'
		+ '"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": '
		+ '100}], "type": "noWrap"}]}, "objectLiteral": {"defaultWrap": "ignore", "rules": [{"conditions": ['
		+ '{"cond": "exceedsMaxLineLength", "value": 1}], "type": "onePerLine"}]}}, "whitespace": {'
		+ '"bracesConfig": {"objectLiteralBraces": {"openingPolicy": "after", "closingPolicy": "before"}, '
		+ '"anonTypeBraces": {"openingPolicy": "after", "closingPolicy": "before"}, "typedefBraces": {'
		+ '"openingPolicy": "after", "closingPolicy": "before"}, "blockBraces": {'
		+ '"openingPolicy": "around", "closingPolicy": "before"}, "unknownBraces": {"openingPolic'
		+ 'y": "after", "closingPolicy": "before"}}}}';

	public function new(): Void {
		super();
	}

	/**
	 * The motivating shape. The sole argument is a ternary whose branches are
	 * brace-delimited object literals, the last of them holding a block that
	 * forces the break. The `}` closing that branch belongs at the branch's own
	 * continuation indent; the call's `)` belongs one level back, at the indent of
	 * the line its `(` sits on. Reverting the slice glues them into `})`.
	 */
	public function testSoleTernaryArgWithBraceBranchesClosesAtItsOpenerIndent(): Void {
		final src: String = 'class P {\n\tfunction f() {\n\t\tfields.push({\n\t\t\tname: \'set_\' + n,\n\t\t\taccess: ast.concat('
			+ '[AInline, setterAccess]),\n\t\t\tmeta: null,\n\t\t\tpos: f.pos,\n\t\t\tkind: FFun(setcontroll ? { ar'
			+ 'gs: [{ name: \'v\', type: null }], ret: null, expr: macro return aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
			+ 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa } : { args: [{ name: \'v\', type: null }],'
			+ ' ret: null, expr: macro {\n\t\t\t\tif (v != prev) {\n\t\t\t\t\tvar q = prev;\n\t\t\t\t\tdispatchWith'
			+ 'Flag(prev = v, q, true);\n\t\t\t\t}\n\t\t\t\treturn prev;\n\t\t\t} })\n\t\t});\n\t}\n}';
		final expected: String = 'class P {\n\n\tfunction f() {\n\t\tfields.push({\n\t\t\tname: \'set_\' + n,\n\t\t\taccess: ast.conca'
			+ 't([AInline, setterAccess]),\n\t\t\tmeta: null,\n\t\t\tpos: f.pos,\n\t\t\tkind: FFun(setcontroll\n\t\t\t\t? {\n'
			+ '\t\t\t\t\targs: [{ name: \'v\', type: null }],\n\t\t\t\t\tret: null,\n\t\t\t\t\texpr: mac'
			+ 'ro return aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n\t\t\t\t}\n'
			+ '\t\t\t\t: {\n\t\t\t\t\targs: [{ name: \'v\', type: null }],\n\t\t\t\t\tret: null,\n\t\t\t\t\texpr: macro {\n'
			+ '\t\t\t\t\t\tif (v != prev) {\n\t\t\t\t\t\t\tvar q = prev;\n\t\t\t\t\t\t\tdispatchWithFlag(prev = v, q, true);\n'
			+ '\t\t\t\t\t\t}\n\t\t\t\t\t\treturn prev;\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t)\n\t\t});\n\t}\n\n}';
		assertWrite(expected, src);
	}

	/**
	 * The discriminator for the brace bound. The same sole-argument ternary shape,
	 * but its last branch is a bracket collection. A bracket-delimited collection
	 * owns its own multi-line layout — its `[` IS the wrap point, so the head line
	 * hugs it and the `]` comes back to the CALL's indent, where the glued `)` was
	 * already right. Dropping `endsWithCloseBrace` from the predicate splits this
	 * `]);` into `]` + `);` for nothing.
	 */
	public function testSoleTernaryArgWithBracketBranchKeepsTheGluedClose(): Void {
		final src: String = 'class BracketBranch {\n\tfunction f() {\n\t\tblock(descend(node.children[0], ident(\'_e0\'), \'into'
			+ '\', TYPE_OUT_PARAM, 0).length == 0 ? [] : [macro for (_e0 in v) $$e{block(descend(node.children[0], '
			+ 'ident(\'_e0\'), \'into\', TYPE_OUT_PARAM, 0))}]);\n\t}\n}';
		final expected: String = 'class BracketBranch {\n\n\tfunction f() {\n\t\tblock(descend(node.children[0], ident(\'_e0\'), \'int'
			+ 'o\', TYPE_OUT_PARAM, 0).length == 0 ? [] : [\n\t\t\tmacro for (_e0 in v) $$e{block(descend(node.chil'
			+ 'dren[0], ident(\'_e0\'), \'into\', TYPE_OUT_PARAM, 0))}\n\t\t]);\n\t}\n\n}';
		assertWrite(expected, src);
	}

	/**
	 * A sole value-`if` argument whose last branch is a call, so the argument's
	 * last line ends on CONTENT rather than on a run of closers. There is no
	 * line-leading closer group for the invariant to speak about.
	 *
	 * ROUND-TRIP PIN ONLY, and stated as such rather than claimed as coverage: it
	 * does not flip under any single-clause reversion of the predicate, and for TWO
	 * independent reasons, so naming only one would mislead. The brace bound
	 * rejects the `)`-tailed argument; and even with every brace test removed the
	 * tail scan reaches the `1` of `fromDays(1)` before any closer run and answers
	 * `TailOther` on its own. It records the shape an earlier revision of this
	 * slice did break — that probe read the trailing call's broken slot
	 * unconditionally — so a future widening of the tail walk has something to go
	 * red on.
	 */
	public function testSoleArgClosingOnContentKeepsTheGluedClose(): Void {
		final src: String = 'class ContentTail {\n\tfunction f() {\n\t\treturn MathTools.cabs(if (ms != 0) {\n\t\t\tif (ms % 10 != 0) 1;\n'
			+ '\t\t\telse if (ms % 100 != 0) 10;\n\t\t\telse 100;\n\t\t} else if (seconds != 0) fromSecond'
			+ 's(1); else if (minutes != 0) fromMinutes(1); else if (hours != 0) fromHours(1); else fromDays(1));\n\t}\n}';
		final expected: String = 'class ContentTail {\n\n\tfunction f() {\n\t\treturn MathTools.cabs(if (ms != 0) {\n\t\t\tif (ms % 10'
			+ ' != 0) 1; else if (ms % 100 != 0) 10; else 100;\n\t\t} else if (seconds != 0) fromSeconds(1); else i'
			+ 'f (minutes != 0) fromMinutes(1); else if (hours != 0) fromHours(1); else fromDays(1));\n\t}\n\n}';
		assertWrite(expected, src);
	}

	/**
	 * Round-trip pin for the shape's precondition: the own-line close is a forced
	 * hardline, so it may only be built for an argument that can never be laid out
	 * flat. A ternary the enclosing `Group` can still collapse must come back
	 * untouched.
	 *
	 * It does not flip on REMOVING the `flatLength(items[0]) < 0` clause — a flat
	 * argument has no hardline on any resolved spine, so the tail walk answers `-1`
	 * and the clause is implied (it is kept as a cost guard, not a filter). It IS
	 * the only fixture that flips on the opposite mutation: force `closeOnOwnLine`
	 * true and this shape gets a hardline the `Group` can no longer collapse.
	 */
	public function testFlatSoleTernaryArgStaysOnOneLine(): Void {
		final src: String = 'class FlatTernary {\n\tfunction f() {\n\t\temit(flag ? left : right);\n\t}\n}';
		final expected: String = 'class FlatTernary {\n\n\tfunction f() {\n\t\temit(flag ? left : right);\n\t}\n\n}';
		assertWrite(expected, src);
	}

	private function assertWrite(expected: String, src: String): Void {
		final out: String = HxWriteFixture.triviaWrite(src, CFG);
		Assert.equals(expected, out);
		Assert.equals(out, HxWriteFixture.triviaWrite(out, CFG));
	}

}
