package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxConditionalStmt;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxSwitchStmt;
import anyparse.grammar.haxe.HxFnDecl;

/**
 * Slice D -- conditional-compilation splices in STATEMENT and CASE scope.
 *
 * Three mechanisms, each pinned by a byte-fidelity round-trip on the
 * shape of the real source that motivated it plus a structural assert
 * where the AST shape (not just parse survival) is the contract:
 *
 *  - `HxStatement.OrphanElseStmt` -- an `else` clause cut off from its
 *    `if` head by a preprocessor boundary. Covers the COND-ELSE-SLOT
 *    family (a balanced `#if` region holding the whole else branch) and
 *    the `else` trailing a `CondSpliceStmt` whose raw fragment carried
 *    parallel braceless `if` heads.
 *  - `HxSwitchCase.CondSpliceCase` -- a `#if` region holding whole `case`
 *    LABELS (including the `:`) with the body shared after `#end`.
 *  - `HxCondSpliceRaw`'s nesting-aware regex branch -- a splice fragment
 *    that itself contains a balanced `#if ... #end`.
 *
 * Plus the two `stmtNoSemi` delegation arms that let a splice or an
 * orphan-else be FOLLOWED by another statement.
 */
@:nullSafety(Strict)
class HxCondSpliceScopeSliceTest extends HxTestHelpers {

	/**
	 * `pony/net/SocketClientBase.hx:93` -- the whole `else if` branch
	 * lives inside a balanced `#if` region after a complete `if`.
	 */
	public function testCondElseSlotRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction tryAgain() {\n\t\tclose();\n\t\tif (reconnectDelay == 0) {\n\t\t\treopen();\n\t\t}\n'
			+ '\t\t#if ((!dox && HUGS) || nodejs || flash)\n\t\telse if (reconnectDelay > 0) {\n\t\t\tTimer.delay(reopen, reconnectDelay);\n'
			+ '\t\t}\n\t\t#end\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * The region stays STRUCTURED: `HxStatement.Conditional` parses it
	 * and its body Star holds a single `OrphanElseStmt`, so neither
	 * compilation variant degrades to a raw byte blob.
	 */
	public function testCondElseSlotParsesAsStructuredConditional(): Void {
		final body: Array<HxStatement> =
			parseBody('class C { function f():Void { if (a == 0) { g(); } #if X else if (a > 0) { h(); } #end } }');
		Assert.equals(2, body.length);
		final cond: HxConditionalStmt = expectConditionalStmt(body[1]);
		Assert.equals(1, cond.body.length);
		switch cond.body[0] {
			case OrphanElseStmt(stmt):
				switch stmt {
					case IfStmt(_):
						Assert.pass();
					case null, _:
						Assert.fail('expected OrphanElseStmt(IfStmt)');
				}
			case null, _:
				Assert.fail('expected OrphanElseStmt');
		}
	}

	/**
	 * `haxe/format/JsonParser.hx:227` and `lime/system/ThreadPool.hx:463`
	 * -- a SECOND, unguarded `else if` follows the `#end`, so the orphan
	 * ctor must also fire at block scope.
	 */
	public function testCondElseSlotWithTrailingElseIfRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction f(c) {\n\t\tif (c == 92) {\n\t\t\tg();\n\t\t}\n\t\t#if !(target.unicode)\n'
			+ '\t\telse if (c >= 128) {\n\t\t\th();\n\t\t}\n\t\t#end\n\t\telse if (isEof(c))\n\t\t\tthrow "Unclosed string";\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * `swf/exporters/swflite/DynamicTextSymbol.hx:139` -- ordinary
	 * statements follow the `#end`. Pins the `;`-elision verdict for a
	 * `Conditional` whose body is an orphan else.
	 */
	public function testCondElseSlotFollowedByStatementsRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tif (found) {\n\t\t\tembedFonts = true;\n\t\t}\n\t\t#if (lime && !flash)\n'
			+ '\t\telse if (!warned.exists(font)) {\n\t\t\twarn(font);\n\t\t}\n\t\t#end\n\t\tif (align != null) {\n\t\t\tapply(align);\n'
			+ '\t\t}\n\t\tdone();\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * `pony/heaps/HeapsAssets.hx:311` -- `#if` holds whole case labels of
	 * DIFFERING arity; the body after `#end` is shared by both variants.
	 */
	public function testCaseLabelSpliceSharedBodyRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction texture(asset:String):Tile {\n\t\treturn switch ext(asset) {\n\t\t\t#if hxbitmini\n'
			+ '\t\t\tcase ATLAS, BINATLAS:\n\t\t\t#else\n\t\t\tcase ATLAS:\n\t\t\t#end\n\t\t\tif (name == null) throw ERROR;\n'
			+ '\t\t\tvar p:Atlas = atlases[asset];\n\t\t\tp.get(name);\n\t\t\tcase PNG: tiles[asset];\n\t\t\tcase _: throw ERROR;\n\t\t};\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * `pony/magic/builder/InBuilder.hx:31` -- same shape inside a macro
	 * expression switch.
	 */
	public function testCaseLabelSpliceDifferingArityRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction repl(e:Expr):Expr {\n\t\treturn switch e.expr {\n\t\t\t#if (haxe_ver >= "4.0.0")\n'
			+ '\t\t\tcase EBinop(OpIn, e1, e2):\n\t\t\t#else\n\t\t\tcase EIn(e1, e2):\n\t\t\t#end\n'
			+ '\t\t\tmacro $$e2.indexOf($$e1) != -1;\n\t\t\tcase EFor(_, _): e;\n\t\t\tcase _: map(e, repl);\n\t\t};\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * The shared body binds to the splice element, not to the enclosing
	 * case list: `tail` takes the first statement and `rest` the others.
	 */
	public function testCaseLabelSpliceOwnsTheSharedBody(): Void {
		final sw: HxSwitchStmt = parseSwitch(
			'class C { function f():Void { switch (x) { #if A case P, Q: #else case P: #end g(); h(); case R: i(); } } }'
		);
		Assert.equals(2, sw.cases.length);
		switch sw.cases[0] {
			case CondSpliceCase(inner):
				Assert.equals(1, inner.rest.length);
			case null, _:
				Assert.fail('expected CondSpliceCase');
		}
		switch sw.cases[1] {
			case CaseBranch(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected CaseBranch');
		}
	}

	/**
	 * REGRESSION GUARD for the case scope: a `#if` region holding WHOLE
	 * clauses (label AND body) must keep its structured
	 * `HxConditionalCase` representation -- `CondSpliceCase` is tried
	 * first and has to fail-rewind on it.
	 */
	public function testWholeClauseConditionalStaysStructured(): Void {
		final sw: HxSwitchStmt = parseSwitch(
			'class C { function f():Void { switch (x) { case A: a(); #if false case B: b(); #end case D: d(); } } }'
		);
		Assert.equals(3, sw.cases.length);
		switch sw.cases[1] {
			case Conditional(inner):
				Assert.equals(1, inner.body.length);
			case null, _:
				Assert.fail('expected structured Conditional');
		}
	}

	public function testWholeClauseConditionalRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction f(x) {\n\t\tswitch (x) {\n\t\t\tcase A:\n\t\t\t\tg();\n\t\t\t#if false\n\t\t\tcase B:\n'
			+ '\t\t\t\th();\n\t\t\t#end\n\t\t\tcase D:\n\t\t\t\ti();\n\t\t}\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * REGRESSION GUARD: the pre-existing INSIDE-the-pattern form
	 * (`case #if A "x" #else "y" #end:`) is a different production and
	 * must not be captured by the new case-scope splice.
	 */
	public function testInsidePatternConditionalStillRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction f(x) {\n\t\tswitch (x) {\n\t\t\tcase #if flag "a" #else "b" #end:\n\t\t\t\tg();\n\t\t}\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * The std `haxe/ds/*Map.remove` idiom: a `CondSpliceStmt` whose tail
	 * is a brace-terminated block, followed by more statements. The byte
	 * check at `_prevEndPos - 1` sees `}` (not `;`), so the `stmtNoSemi`
	 * delegation into the splice's `tail` is the only thing that lets the
	 * block Star continue.
	 */
	public function testMapRemoveSpliceWithBraceTerminalTailRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction remove(key:Int):Bool {\n\t\tvar idx = -1;\n\t\t#if !no_map_cache\n'
			+ '\t\tif (!(cachedKey == key && ((idx = cachedIndex) != -1)))\n\t\t#end\n\t\t{\n\t\t\tidx = lookup(key);\n\t\t}\n'
			+ '\t\tif (idx == -1) {\n\t\t\treturn false;\n\t\t}\n\t\treturn true;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * `pony/ui/xml/HeapsXmlUi.hx:222` -- parallel braceless `if` heads in
	 * a splice fragment, a shared then-branch, AND a trailing `else`.
	 */
	public function testParallelIfHeadsWithTrailingElseRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction f(obj, v) {\n\t\t#if (haxe_ver >= 4.10)\n\t\tif (Std.isOfType(obj, NodeBitmap))\n'
			+ '\t\t#else\n\t\tif (Std.is(obj, NodeBitmap))\n\t\t#end\n\t\tcast(obj, NodeBitmap).tint = v;\n'
			+ '\t\telse cast(obj, Drawable).color = v;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * REGRESSION GUARD, the other direction: the SAME shape without a
	 * trailing `else` parsed before `OrphanElseStmt` existed (as a plain
	 * `CondSpliceStmt`) and must keep parsing identically.
	 */
	public function testParallelIfHeadsWithoutElseStillRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction f(obj, v) {\n\t\t#if (haxe_ver >= 4.10)\n\t\tif (Std.isOfType(obj, Drawable))\n'
			+ '\t\t#else\n\t\tif (Std.is(obj, Drawable))\n\t\t#end\n\t\taddFilters(obj, v);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * `motion/actuators/SimpleActuator.hx:232` -- the splice fragment
	 * carries a complete nested `#if ... #end` inside the `if` condition,
	 * so the raw terminal must skip the BALANCED inner region instead of
	 * stopping at its `#end`.
	 */
	public function testNestedRegionInsideStatementSpliceRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction f(target, i) {\n\t\t#if (!neko && !hl)\n'
			+ '\t\tif (hasField(target, i) #if flash && !untyped (target).has("set_" + i) #end) {\n\t\t\tstart = field(target, i);\n'
			+ '\t\t} else\n\t\t#end\n\t\t{\n\t\t\tisField = false;\n\t\t\tstart = getProperty(target, i);\n\t\t}\n\t\tnext();\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * `lime/system/ThreadPool.hx:829` -- same nesting in a postfix
	 * `CondSpliceTail` operand splice.
	 */
	public function testNestedRegionInsidePostfixSpliceRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction f() {\n'
			+ '\t\tif (activeJobs #if lime_threads + queuedExit #if lime_threads_deque + queuedWork #end #end <= 0) {\n'
			+ '\t\t\tstop();\n\t\t}\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * REGRESSION GUARD for the raw terminal's fallback branch: the
	 * original dangling-else dogfood shape has no nesting and must match
	 * exactly as before the alternation was introduced.
	 */
	public function testDanglingElseSpliceRoundTrips(): Void {
		final src: String = 'class C {\n\tfunction f(file) {\n\t\t#if share\n\t\tif (file != null) upload(file); else\n\t\t#end\n\t\tsendForm();\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * `lime/system/ThreadPool.hx:463` in plain mode: the orphan `else if`
	 * block is followed by more statements, so its `;`-elision verdict
	 * has to come from the payload statement (`stmtNoSemi` recursion).
	 * Trivia mode tolerates the missing separator by itself; the plain
	 * parse is the one `self-status` runs.
	 */
	public function testOrphanElsePlainParseKeepsFollowingStatements(): Void {
		final body: Array<HxStatement> = parseBody(
			'class C { function f():Void { if (a) { g(); } #if X else if (b) { h(); } #end '
			+ 'else if (c) { i(); } switch (e) { case A: j(); } } }'
		);
		Assert.equals(4, body.length);
		switch body[2] {
			case OrphanElseStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected OrphanElseStmt');
		}
	}

	/**
	 * Plain-mode twin of the map-remove round-trip. The trivia Star
	 * tolerates the missing separator on its own, so ONLY a plain parse
	 * exercises the `stmtNoSemi` delegation into the splice's `tail` --
	 * and the plain parse is the one `self-status` (and therefore
	 * `SymbolIndex`) runs.
	 */
	public function testMapRemoveSplicePlainParseKeepsFollowingStatements(): Void {
		final body: Array<HxStatement> = parseBody(
			'class C { function remove(key:Int):Bool { var idx = -1; '
			+ '#if !no_map_cache if (!(cachedKey == key)) #end { idx = lookup(key); } if (idx == -1) { return false; } return true; } }'
		);
		Assert.equals(4, body.length);
		switch body[1] {
			case CondSpliceStmt(_):
				Assert.pass();
			case null, _:
				Assert.fail('expected CondSpliceStmt');
		}
	}

	private function parseBody(source: String): Array<HxStatement> {
		return fnBodyStmts(parseSingleFnDecl(source));
	}

	private function parseSwitch(source: String): HxSwitchStmt {
		final body: Array<HxStatement> = parseBody(source);
		Assert.equals(1, body.length);
		return switch body[0] {
			case SwitchStmt(stmt): stmt;
			case null, _: throw 'expected SwitchStmt';
		};
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
