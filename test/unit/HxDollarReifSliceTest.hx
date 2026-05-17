package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxType;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Slice apq-P5-L (tail): macro `$`-reification expression escapes.
 *
 * Three new `HxExpr` ctors, an expression-position mirror of the
 * `HxStringSegment` interpolation grammar plus the named-reification
 * middle form:
 *
 *  - `DollarBlockExpr` — `${expr}` (`@:lead("${") @:trail("}")`).
 *  - `DollarReifExpr` — `$name{expr}` (`$i{}`/`$v{}`/`$p{}`/`$a{}`/
 *    `$b{}`/`$e{}`), `@:lead("$") @:trail("}")` with the field
 *    `expr` carrying `@:lead("{")`.
 *  - `DollarIdentExpr` — `$ident` (`@:lead("$")`).
 *
 * Purely syntactic — no reification semantics. Asserts each shape,
 * `tryBranch` disambiguation (`$x` vs `$i{…}` vs `${…}`), that postfix
 * still applies (`$type(e)`), that `macro` nesting is unaffected, and
 * round-trip idempotency. Source strings holding a literal `$` are
 * double-quoted so Haxe does not interpolate them.
 */
class HxDollarReifSliceTest extends HxTestHelpers {

	private function initOf(source:String):HxExpr {
		final decl:HxVarDecl = parseSingleVarDecl(source);
		return switch decl.init {
			case null: throw 'expected init expr, got null';
			case e: e;
		}
	}

	private function typeOf(source:String):HxType {
		final decl:HxVarDecl = parseSingleVarDecl(source);
		return switch decl.type {
			case null: throw 'expected type annotation, got null';
			case t: t;
		}
	}

	private function identOf(e:HxExpr):String {
		return switch e {
			case IdentExpr(v): (v : String);
			case null, _: throw 'expected IdentExpr, got $e';
		}
	}

	public function testDollarIdent():Void {
		switch initOf("class C { var x = $foo; }") {
			case DollarIdentExpr(name): Assert.equals('foo', (name : String));
			case e: Assert.fail('expected DollarIdentExpr, got $e');
		}
	}

	public function testDollarBlock():Void {
		switch initOf("class C { var x = ${expr}; }") {
			case DollarBlockExpr(inner): Assert.equals('expr', identOf(inner));
			case e: Assert.fail('expected DollarBlockExpr, got $e');
		}
	}

	public function testDollarBlockComplexExpr():Void {
		switch initOf("class C { var x = ${a + b}; }") {
			case DollarBlockExpr(Add(l, r)):
				Assert.equals('a', identOf(l));
				Assert.equals('b', identOf(r));
			case e: Assert.fail('expected DollarBlockExpr(Add), got $e');
		}
	}

	public function testDollarReifAllNames():Void {
		// Single-quoted: `$$` -> literal `$`, `$n` -> the loop variable.
		for (n in ['i', 'v', 'p', 'a', 'b', 'e']) {
			switch initOf('class C { var x = $$$n{body}; }') {
				case DollarReifExpr({name: name, expr: inner}):
					Assert.equals(n, (name : String));
					Assert.equals('body', identOf(inner));
				case e: Assert.fail('expected DollarReifExpr for $$$n{...}, got $e');
			}
		}
	}

	public function testDollarReifArrayBody():Void {
		// `$a{args}` is the array-splice reification; body is any expr.
		switch initOf("class C { var x = $a{[p, q]}; }") {
			case DollarReifExpr({name: name, expr: ArrayExpr(elems)}):
				Assert.equals('a', (name : String));
				Assert.equals(2, elems.length);
			case e: Assert.fail('expected DollarReifExpr(a, ArrayExpr), got $e');
		}
	}

	public function testDollarIdentPostfixCall():Void {
		// `$type(e)` — the bare `$ident` form, then a postfix Call.
		switch initOf("class C { var x = $type(e); }") {
			case Call(DollarIdentExpr(name), args):
				Assert.equals('type', (name : String));
				Assert.equals(1, args.length);
				Assert.equals('e', identOf(args[0]));
			case e: Assert.fail('expected Call(DollarIdentExpr(type), [e]), got $e');
		}
	}

	public function testMacroNesting():Void {
		// `macro $foo` must wrap the dollar atom, not break it.
		switch initOf("class C { var x = macro $foo; }") {
			case MacroExpr(DollarIdentExpr(name)): Assert.equals('foo', (name : String));
			case e: Assert.fail('expected MacroExpr(DollarIdentExpr(foo)), got $e');
		}
	}

	public function testPlainIdentRegressionUnaffected():Void {
		// No `$` — must still be a plain IdentExpr, not a dollar form.
		switch initOf('class C { var x = foo; }') {
			case IdentExpr(v): Assert.equals('foo', (v : String));
			case e: Assert.fail('expected IdentExpr(foo), got $e');
		}
	}

	public function testDollarReifRoundTrip():Void {
		roundTrip(
			"class C { static function f() { var a = macro $i{name}; var b = macro ${x + 1}; var c = macro $foo; } }",
			'L-dollar-reif'
		);
	}

	// -------- $-reification in TYPE position (Slice apq-P5-T) --------

	public function testDollarTypeHint():Void {
		// `var x:$optionsCT = …` — the dominant WriterCodegen.hx shape
		// (`final _c:$optionsCT = cast Reflect.copy(o);`).
		switch typeOf("class C { var x:$ct = 1; }") {
			case DollarType(name): Assert.equals('ct', (name : String));
			case t: Assert.fail('expected DollarType(ct), got $t');
		}
	}

	public function testDollarTypeInParams():Void {
		// `Null<$optionsCT>` — WriterCodegen.hx:186
		// `{name: 'options', type: macro : Null<$optionsCT>, …}`.
		switch typeOf("class C { var x:Null<$ct> = null; }") {
			case Named({name: nm, params: [DollarType(p)]}):
				Assert.equals('Null', (nm : String));
				Assert.equals('ct', (p : String));
			case t: Assert.fail('expected Named(Null, [DollarType(ct)]), got $t');
		}
	}

	public function testPlainTypeRegressionUnaffected():Void {
		// No `$` — must still be a plain `Named` type-ref, not DollarType.
		switch typeOf('class C { var x:Int = 1; }') {
			case Named({name: nm}): Assert.equals('Int', (nm : String));
			case t: Assert.fail('expected Named(Int), got $t');
		}
	}

	public function testDollarTypeRoundTrip():Void {
		// Writer ripple net: `$ct` in type position flows the generic
		// single-Ref `@:lead("$")` writer path (DollarIdentExpr twin).
		roundTrip("class C {\n\tvar x:$ct = 1;\n}\n", 'dollar-type');
	}

	// -------- expression-position var/final (Slice apq-P5-U) --------

	public function testMacroVarExpr():Void {
		// `macro var y = 1` — MacroExpr operand is an HxExpr; the new
		// VarExpr atom reuses HxVarDecl verbatim (HxStatement.VarStmt twin).
		switch initOf("class C { var x = macro var y = 1; }") {
			case MacroExpr(VarExpr({name: nm, init: IntLit(v)})):
				Assert.equals('y', (nm : String));
				Assert.equals(1, (v : Int));
			case e: Assert.fail('expected MacroExpr(VarExpr(y=1)), got $e');
		}
	}

	public function testMacroFinalTypedExpr():Void {
		// The real Lowering.hx:1543 shape: `macro final _x:Int = ctx.pos`.
		switch initOf("class C { var x = macro final _x:Int = ctx.pos; }") {
			case MacroExpr(FinalExpr({name: nm, type: Named({name: tn}),
					init: FieldAccess(IdentExpr(o), f)})):
				Assert.equals('_x', (nm : String));
				Assert.equals('Int', (tn : String));
				Assert.equals('ctx', (o : String));
				Assert.equals('pos', (f : String));
			case e: Assert.fail('expected MacroExpr(FinalExpr(_x:Int=ctx.pos)), got $e');
		}
	}

	public function testMacroVarUntypedNotMisparsed():Void {
		// Pins the pre-slice silent-degrade bug as a positive contract:
		// untyped `macro var y = e` previously misparsed (the `var`
		// keyword swallowed as IdentExpr + a stray Assign). It must now
		// be a clean VarExpr.
		switch initOf("class C { var x = macro var y = e; }") {
			case MacroExpr(VarExpr({name: nm, init: IdentExpr(rhs)})):
				Assert.equals('y', (nm : String));
				Assert.equals('e', (rhs : String));
			case e: Assert.fail('expected MacroExpr(VarExpr(y=e)) [untyped not misparsed], got $e');
		}
	}

	public function testMacroVarFinalExprRoundTrip():Void {
		// Writer ripple net: VarExpr/FinalExpr emit via the generic
		// HxVarDecl path (HxStatement.VarStmt minus the trailOpt/fmt).
		roundTrip(
			"class C { static function f() { var a = macro var y = 1; var b = macro final _z:Int = p; } }",
			'macro-var-final'
		);
	}

	// -------- expression-position throw (Slice apq-P5-W) --------

	public function testMacroThrowExpr():Void {
		// `macro throw e` — MacroExpr operand is an HxExpr; the new
		// ThrowExpr atom (HxStatement.ThrowStmt twin / ReturnExpr analog)
		// carries a single value:HxExpr. Pre-slice this hard-failed.
		switch initOf("class C { var x = macro throw e; }") {
			case MacroExpr(ThrowExpr(IdentExpr(v))): Assert.equals('e', (v : String));
			case e: Assert.fail('expected MacroExpr(ThrowExpr(IdentExpr(e))), got $e');
		}
	}

	public function testMacroThrowNewExpr():Void {
		// The real Lowering.hx:3516 driver shape:
		// `macro throw new anyparse.runtime.ParseError(...)`.
		switch initOf('class C { var x = macro throw new E("boom"); }') {
			case MacroExpr(ThrowExpr(NewExpr(_))): Assert.pass();
			case e: Assert.fail('expected MacroExpr(ThrowExpr(NewExpr)), got $e');
		}
	}

	public function testThrowExprPositionDirect():Void {
		// Pure expression position, no macro — the direct ReturnExpr
		// analog. `throw` is bottom-typed so it is a valid init expr;
		// `decl.init` is an HxExpr, reached without the MacroExpr operand.
		switch initOf("class C { var x = throw e; }") {
			case ThrowExpr(IdentExpr(v)): Assert.equals('e', (v : String));
			case e: Assert.fail('expected ThrowExpr(IdentExpr(e)), got $e');
		}
	}

	public function testMacroThrowRoundTrip():Void {
		// Writer ripple net: ThrowExpr emits via the generic single-Ref
		// value:HxExpr path (ReturnExpr/CastExpr/MacroExpr precedent).
		roundTrip(
			'class C { static function f() { var a = macro throw e; var b = macro throw new E("x"); } }',
			'macro-throw'
		);
	}

	// -------- $-reification in var/final NAME position (Slice apq-P5-X1) --------

	public function testDollarVarName():Void {
		// `var $x = 1` — the binding-name slot accepts a macro-reification
		// `$ident`. Pre-slice the `$` made the name terminal fail to match.
		final decl:HxVarDecl = parseSingleVarDecl("class C { var $x = 1; }");
		Assert.equals("$x", (decl.name : String));
	}

	public function testDollarFinalNameMacroSite():Void {
		// The exact WriterLowering.hx:1620 site shape:
		// `final $localName:$fieldCT = $fieldAccess;`. The `$`-name is this
		// slice; `:$fieldCT` is Slice T (DollarType); `= $fieldAccess` is
		// DollarIdentExpr — all three compose in one HxVarDecl.
		switch initOf("class C { var x = macro final $localName:$fieldCT = $fieldAccess; }") {
			case MacroExpr(FinalExpr({name: nm, type: DollarType(tn),
					init: DollarIdentExpr(rhs)})):
				Assert.equals("$localName", (nm : String));
				Assert.equals('fieldCT', (tn : String));
				Assert.equals('fieldAccess', (rhs : String));
			case e: Assert.fail('expected MacroExpr(FinalExpr(localName:fieldCT=fieldAccess)), got $e');
		}
	}

	public function testPlainVarNameRegressionUnaffected():Void {
		// No `$` — plain identifier names are unchanged by the widened
		// name terminal (the HxIdentLit -> HxVarNameLit swap is transparent).
		final decl:HxVarDecl = parseSingleVarDecl('class C { var x = 1; }');
		Assert.equals('x', (decl.name : String));
	}

	public function testDollarVarNameRoundTrip():Void {
		// Writer net: the `@:rawString` name terminal emits the matched
		// slice (with the `$`) verbatim via the generic terminal path.
		roundTrip(
			"class C { static function f() { var $x = 1; } }",
			'dollar-var-name'
		);
	}

	public function testDollarBraceVarNameDeferredLimitation():Void {
		// Pinned limitation: the `${expr}` brace-form binding name is
		// deliberately NOT matched (no source site uses it; minimal-first).
		// The widened terminal stops at `$` + ident, so `${e}` fails the
		// name match and the parse is rejected. Exit criterion: add a
		// brace production for the name slot when a real `var ${e} = …`
		// site appears.
		Assert.raises(() -> HaxeParser.parse("class C { var ${e} = 1; }"), ParseError);
	}
}
