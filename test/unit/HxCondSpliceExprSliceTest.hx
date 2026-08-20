package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxCondSpliceOpExpr;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnBody;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxVarSemiCondInitDecl;

/**
 * Expression-position `#if`: which regions carry NODES and which stay a
 * raw byte span.
 *
 * A census over 1646 real modules (TM `src/`, `lime/src`, `openfl/src`)
 * found ELEVEN `HxExpr.CondSpliceExpr` regions in nine files — the
 * production whose `raw` is a verbatim byte capture with no nodes inside
 * it. Three shapes, and this class pins the verdict for each:
 *
 *  - **Balanced value per branch, `;` inside the guard** (2 sites,
 *    `openfl/ui/Mouse.hx:61,66`) — `var supportsCursor(default,
 *    null):Bool = #if !mobile true; #else false; #end`. MODELLED
 *    (`HxVarSemiCondInitDecl` binds the property-accessor clause that
 *    was pushing the member out).
 *  - **Dangling infix operator** (8 sites: `+` in TM `SystemData.hx:137`
 *    and `CrashDumper.hx:307`, `||` in `openfl/geom/PerspectiveProjection
 *    .hx:116`, `openfl/display/BitmapData.hx:2229,2239`,
 *    `openfl/display3D/textures/TextureBase.hx:289`, `&&` in
 *    `lime/utils/Preloader.hx:233`, `lime/system/System.hx:590`) —
 *    MODELLED, `HxCondSpliceOpExpr`, see
 *    `testDanglingInfixOperatorRegionIsModelled`.
 *  - **Half ternary** (1 site, TM `popups/fileDialog/FileDialog.hx:91`) —
 *    RAW, and the reason is fidelity rather than parsing; see
 *    `testHalfTernaryRegionStaysRaw`.
 *
 * The dangling-operator shape was refused once, on a measurement that is
 * still true: modelling it as `{cond, expr:HxExpr, op, tail:HxExpr}`
 * needs the Pratt loop to REWIND an operator whose right operand fails to
 * parse, and `Lowering.lowerPrattLoop` emits no such path — every branch
 * is `left = HxExpr.Add(left, parseHxExpr(ctx, prec + 1))` with zero
 * `try` and zero `catch` in the whole generated loop, and 41 of its 42
 * `ctx.pos = _savedPos` writes are the min-precedence gate. What does not
 * follow is the refusal. `expr` does not have to be a full-precedence
 * expression: prefix and the whole postfix loop live in
 * `parseHxExprAtom`, so an ATOM-level operand covers everything the eight
 * sites put between their operators and stops at the operator. The
 * fragment is then a Star of `(operand, operator)` pairs, and a Star's
 * element rewind — `@:tryparse` — has shipped since
 * `HxConditionalExpr.elseifs`. The operator loop is never entered, so it
 * never needs to unwind, and `a + ;` still errors at the `+` because
 * nothing outside a `#if` region reaches the ctor. Full reasoning on
 * `HxCondSpliceOpExpr`.
 *
 * `HxCondSpliceRaw`'s verbatim capture is still what keeps the remaining
 * shapes parsing and byte-round-tripping, and `RefactorSupport`'s
 * unparsed-region guard still reads exactly those raw spans — it walks
 * the parts of an opaque node's span NO CHILD covers, so it narrowed to
 * the directive keywords and the operator slices by itself when the
 * operands became nodes.
 */
@:nullSafety(Strict)
class HxCondSpliceExprSliceTest extends HxTestHelpers {

	/**
	 * `openfl/ui/Mouse.hx:61` — a property-accessor clause in front of a
	 * per-branch-`;` conditional initializer.
	 *
	 * Before this slice the accessor clause pushed the member out of
	 * `VarSemiCondInitMember` into `HxExpr.CondSpliceExpr`, whose raw span
	 * swallowed the whole region and then bound the NEXT member's `public`
	 * modifier as its tail operand. Two consequences, both checked here:
	 * the branch values `true` / `false` carried no nodes, and `hxq fmt`
	 * rewrote the file as `…#end\n\tpublic\n\tstatic var other…` — a
	 * modifier torn off its own member.
	 */
	public function testAccessorClauseSemicolonBranchInitializerIsModelled(): Void {
		final src: String = 'class C {\n\tpublic static var supportsCursor(default, null):Bool = #if !mobile true; #else false; #end\n\n'
			+ '\tpublic static var other:Int = 1;\n}';
		final ast: HxClassDecl = HaxeParser.parse(src);
		Assert.equals(2, ast.members.length, 'the accessor-clause member must not swallow the next member');
		final decl: HxVarSemiCondInitDecl = expectVarSemiCondInitMember(ast.members[0].member);
		Assert.equals('default,null', accessorIds(decl), 'the (default, null) accessor clause is bound');
		switch decl.region {
			case Conditional(inner):
				Assert.equals('!mobile', (inner.cond: String));
				assertBoolLit(inner.expr, true, 'then-branch');
				final elseClause: Null<anyparse.grammar.haxe.HxConditionalSemiExprElse> = inner.elseClause;
				if (elseClause == null) {
					Assert.fail('expected an #else clause');
				} else {
					assertBoolLit(elseClause.expr, false, 'else-branch');
				}
		}
		Assert.equals('other', (expectVarMember(ast.members[1].member).name: String), 'the next member keeps its own name');
		triviaEquals(src, 'Mouse.supportsCursor');
	}

	/**
	 * The `#elseif` spelling of the same shape and a `#else`-less one:
	 * both reach the structured production, not the raw splice.
	 */
	public function testAccessorClauseSemicolonBranchVariants(): Void {
		for (src in [
			'class C {\n\tpublic var a(get, never):Int = #if js 1; #elseif cpp 2; #else 3; #end\n}',
			'class C {\n\tpublic var b(default, null):Int = #if js 1; #end\n}',
			'class C {\n\tpublic var c(get, set):Int = #if js 1; #else 2; #end\n}'
		]) {
			Assert.notNull(expectVarSemiCondInitMember(singleMember(src)).access, 'accessor clause bound: $src');
			triviaEquals(src, src);
		}
	}

	/**
	 * The accessor clause must not become a wedge: every spelling that
	 * already reached `VarMember` still has to, because
	 * `VarSemiCondInitMember` is tried FIRST and an over-eager match would
	 * consume the name and accessors and leave `= …;` to break the
	 * enclosing member Star.
	 */
	public function testOrdinaryAccessorMembersUnaffected(): Void {
		for (src in [
			'class C {\n\tpublic var a(get, set):Int;\n}',
			'class C {\n\tpublic var b(default, null):Int = 1;\n}',
			'class C {\n\tpublic var c(get, never):Int = #if js 1 #else 2 #end;\n}',
			'class C {\n\tpublic var d(get, set):Int = f(1);\n}'
		]) {
			Assert.notNull(expectVarMember(singleMember(src)).access, 'accessor clause still bound on the ordinary path: $src');
			triviaEquals(src, src);
		}
	}

	/**
	 * TM `src/crashdumper/SystemData.hx:137`, reduced and canonicalised.
	 * The fragment ends on a DANGLING `+` whose right operand lives after
	 * `#end`.
	 *
	 * MODELLED as a run of `(atom, operator)` terms: every operand is a
	 * real node, so `refs` / `rename` / lint / `fmt` see inside the region.
	 */
	public function testDanglingInfixOperatorRegionIsModelled(): Void {
		final src: String = 'class C {\n\tpublic function toString():String {\n\t\treturn "os: "\n\t\t\t+ os\n'
			+ '\t\t\t+ #if flash "  playerType: " + playerType + "\\n" + "  playerVersion: " + playerVersion\n'
			+ '\t\t\t+ "\\n" + #end\n\t\t\t"  totalMemory: " + totalMemory;\n\t}\n}';
		final canonical: String = 'class C {\n\tpublic function toString():String {\n\t\treturn "os: " + os + #if flash '
			+ '"  playerType: " + playerType + "\\n" + "  playerVersion: " + playerVersion + "\\n" + #end '
			+ '"  totalMemory: " + totalMemory;\n\t}\n}';
		switch soleReturnExpr(src) {
			case Add(_, CondSpliceOpExpr(inner)):
				Assert.equals('flash', (inner.cond: String));
				Assert.equals('+ + + + + +', spliceOps(inner), 'six dangling-`+` terms');
				assertStringLeaf(inner.terms[0].operand, '"  playerType: "', 'first operand');
				assertIdent(inner.terms[1].operand, 'playerType', 'second operand');
				assertIdent(inner.terms[4].operand, 'playerVersion', 'the name refs used to miss');
			case other:
				Assert.fail('expected Add(_, CondSpliceOpExpr), got $other');
		}
		// NOT a byte fixed point any more, and that is the point of
		// `@:fmt(fillParts)`: the source's internal line breaks no longer
		// reach the output, so this spelling and the canonical one below both
		// land on the same bytes. Under the default config the whole chain
		// fits on one line, so that is where it goes.
		Assert.equals(canonical, HxWriteFixture.triviaWrite(src, '{}'), 'SystemData.toString reflows');
		Assert.equals(canonical, HxWriteFixture.triviaWrite(canonical, '{}'), 'SystemData.toString canonical is a fixed point');
	}

	/**
	 * TM `src/popups/fileDialog/FileDialog.hx:91`, reduced: `#if c cond ?
	 * a : #end b` — the region carries the head of a ternary whose
	 * else-operand is the tail. STAYS RAW, and the refusal is a fidelity
	 * decision rather than a parsing one: adding `?` and `:` to
	 * `HxCondSpliceOpLit` makes this region parse as two terms and every
	 * operand a node, but a FLAT term run has one indent level to give and
	 * the site is hand-indented on the ternary's two-level convention, so
	 * `hxq fmt` starts rewriting a file it left alone. Measured, recorded
	 * on `HxCondSpliceOpLit`, and reversible in one token.
	 */
	public function testHalfTernaryRegionStaysRaw(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\t_p = #if FEATURE_SHARE\n\t\t\tshare\n\t\t\t\t? new A(1)\n'
			+ '\t\t\t\t:\n\t\t\t#end\n\t\tnew B(2);\n\t}\n}';
		switch soleStatement(src) {
			case ExprStmt(Assign(_, right)):
				assertCondSplice(right, 'half ternary');
			case other:
				Assert.fail('expected ExprStmt(Assign(_, CondSpliceExpr)), got $other');
		}
		triviaEquals(src, 'FileDialog._pathPanel');
	}

	/**
	 * The remaining census shape: a dangling BOOLEAN operator, once inside
	 * an `if` condition (`openfl/geom/PerspectiveProjection.hx:116`) and
	 * once in a local initializer (`lime/utils/Preloader.hx:233`).
	 */
	public function testDanglingBoolOperatorRegionIsModelled(): Void {
		final ifSrc: String =
			'class C {\n\tfunction f():Void {\n\t\tif (#if neko __f == null || #end center == null)\n\t\t\treturn;\n\t}\n}';
		switch soleStatement(ifSrc) {
			case IfStmt(stmt):
				final inner: HxCondSpliceOpExpr = expectCondSpliceOp(stmt.cond, 'dangling || in an if condition');
				Assert.equals('== ||', spliceOps(inner), 'the comparison and the dangling ||');
				assertIdent(inner.terms[0].operand, '__f', 'the compared name');
			case other:
				Assert.fail('expected IfStmt whose cond is a CondSpliceOpExpr, got $other');
		}
		triviaEquals(ifSrc, 'PerspectiveProjection.toMatrix3D');

		final varSrc: String = 'class C {\n\tfunction f():Void {\n\t\tvar b = #if flash loadedStage && #end ready;\n\t}\n}';
		switch soleStatement(varSrc) {
			case VarStmt(decl):
				final inner: HxCondSpliceOpExpr = expectCondSpliceOp(decl.init, 'dangling && in a local initializer');
				Assert.equals('&&', spliceOps(inner));
				assertIdent(inner.terms[0].operand, 'loadedStage', 'the guarded operand');
			case other:
				Assert.fail('expected VarStmt, got $other');
		}
		triviaEquals(varSrc, 'Preloader.update');
	}

	/**
	 * A prefix-operator operand (`openfl/display/BitmapData.hx:2239`) and a
	 * postfix chain one (TM `CrashDumper.hx:307`) both bind INSIDE a term,
	 * which is the whole reason no Pratt rewind is needed: prefix and
	 * postfix live in `parseHxExprAtom`, the function a term's operand
	 * references.
	 */
	public function testTermOperandsCarryPrefixAndPostfix(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (#if two !img.powerOfTwo || #end (w != h))\n\t\t\treturn;\n\t}\n}';
		switch soleStatement(src) {
			case IfStmt(stmt):
				final inner: HxCondSpliceOpExpr = expectCondSpliceOp(stmt.cond, 'prefix ! over a field access');
				Assert.equals('||', spliceOps(inner));
				switch inner.terms[0].operand {
					case Not(FieldAccess(IdentExpr(recv), field)):
						Assert.equals('img', (recv: String));
						Assert.equals('powerOfTwo', (field: String));
					case other:
						Assert.fail('expected Not(FieldAccess(img, powerOfTwo)), got $other');
				}
			case other:
				Assert.fail('expected IfStmt, got $other');
		}
		triviaEquals(src, 'BitmapData.__fromImage');
	}

	/**
	 * The fallback is still there and still reached. A fragment that is NOT
	 * a run of `(atom, operator)` pairs — here one carrying its own `#else`
	 * — keeps `HxCondSpliceRaw`'s verbatim capture, so the ordered choice
	 * degrades exactly where the new production does not apply.
	 */
	public function testNonPairFragmentStillRaw(): Void {
		final src: String = 'class C {\n\tfunction f():String {\n\t\treturn "a" + #if flash "b" + #else "c" + #end "d";\n\t}\n}';
		switch soleReturnExpr(src) {
			case Add(_, right):
				assertCondSplice(right, '#else inside the fragment');
			case other:
				Assert.fail('expected Add(_, CondSpliceExpr), got $other');
		}
		triviaEquals(src, 'raw fallback');
	}

	/**
	 * The balanced expression-scope region — `HxExpr.ConditionalExpr` —
	 * already carries both branch values as nodes, and the splice
	 * production is only ever reached when it fail-rewinds. Pinned because
	 * this slice's dispatch sits next to it.
	 */
	public function testBalancedConditionalExprKeepsItsNodes(): Void {
		final src: String = 'class C {\n\tfunction f():String {\n\t\treturn "a" + #if flash "b" #else "c" #end + "d";\n\t}\n}';
		switch soleReturnExpr(src) {
			case Add(Add(_, ConditionalExpr(inner)), _):
				Assert.equals('flash', (inner.cond: String));
				assertStringLeaf(inner.expr, '"b"', 'then-branch');
				final elseExpr: Null<HxExpr> = inner.elseExpr;
				if (elseExpr == null) {
					Assert.fail('expected an #else branch');
				} else {
					assertStringLeaf(elseExpr, '"c"', 'else-branch');
				}
			case other:
				Assert.fail('expected Add(Add(_, ConditionalExpr), _), got $other');
		}
		triviaEquals(src, 'balanced ConditionalExpr');
	}

	private function expectCondSpliceOp(expr: Null<HxExpr>, label: String): HxCondSpliceOpExpr {
		return switch expr {
			case CondSpliceOpExpr(inner): inner;
			case null, _: throw 'expected CondSpliceOpExpr for $label, got $expr';
		};
	}

	private function spliceOps(inner: HxCondSpliceOpExpr): String {
		return inner.terms.map(t -> (t.op: String)).join(' ');
	}

	private function assertIdent(expr: HxExpr, expected: String, label: String): Void {
		switch expr {
			case IdentExpr(v):
				Assert.equals(expected, (v: String), label);
			case _:
				Assert.fail('expected IdentExpr in $label, got $expr');
		}
	}

	private function assertCondSplice(expr: Null<HxExpr>, label: String): Void {
		switch expr {
			case CondSpliceExpr(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected CondSpliceExpr for $label, got $expr');
		}
	}

	private function assertBoolLit(expr: HxExpr, expected: Bool, label: String): Void {
		switch expr {
			case BoolLit(v):
				Assert.equals(expected, (v: Bool), label);
			case _:
				Assert.fail('expected BoolLit in $label, got $expr');
		}
	}

	private function assertStringLeaf(expr: HxExpr, expected: String, label: String): Void {
		switch expr {
			case DoubleStringExpr(v):
				Assert.equals(expected, (v: String), label);
			case _:
				Assert.fail('expected DoubleStringExpr in $label, got $expr');
		}
	}

	private function accessorIds(decl: HxVarSemiCondInitDecl): String {
		final access: Null<anyparse.grammar.haxe.HxAccessClause> = decl.access;
		return access == null ? '<none>' : access.ids.map(id -> (id: String)).join(',');
	}

	private function soleReturnExpr(source: String): HxExpr {
		return switch soleStatement(source) {
			case ReturnStmt(expr): expr;
			case other: throw 'expected ReturnStmt, got $other';
		};
	}

	private function soleStatement(source: String): HxStatement {
		final body: HxFnBody = switch singleMember(source) {
			case FnMember(decl): decl.body;
			case other: throw 'expected FnMember, got $other';
		};
		final stmts: Array<HxStatement> = switch body {
			case BlockBody(block): block.stmts;
			case other: throw 'expected BlockBody, got $other';
		};
		Assert.equals(1, stmts.length);
		return stmts[0];
	}

	/**
	 * Byte-exact trivia round-trip under the writer DEFAULTS. Defaults
	 * rather than a pinned config because every fixture here is about
	 * whether a region carries nodes, and a knob that reflows an unrelated
	 * `if` body would turn a layout preference into a slice failure.
	 */
	private function triviaEquals(source: String, label: String): Void {
		Assert.equals(source, HxWriteFixture.triviaWrite(source, '{}'), label);
	}

}
