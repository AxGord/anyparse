package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxCondNameFnDecl;
import anyparse.grammar.haxe.HxConditionalFnBody;
import anyparse.grammar.haxe.HxConditionalFnName;
import anyparse.grammar.haxe.HxFnBody;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxVarSemiCondInitDecl;

/**
 * Slice C - conditional-compilation regions occupying whole MEMBER
 * slots. Four shapes, each from a real dependency-tree module that
 * failed to parse before this slice:
 *
 *  - C1 `HxFnBody.CondBody` - the `#if` owns the entire function body
 *    (`std/flash/_std/haxe/Json.hx`, `std/js/_std/haxe/Json.hx`,
 *    `std/haxe/Int32.hx`).
 *  - C2 `HxClassMember.CondNameFnMember` - the `#if` owns the function
 *    NAME (`haxelib format/format/tools/MemoryInput.hx:46`).
 *  - C3 `HxExpr.ConditionalSemiExpr` - each branch terminates its value
 *    with `;` INSIDE the guard, so the region supplies the field's
 *    initializer AND its terminator (`Pony/pony/net/http/HttpTools.hx:24`).
 *  - C5 `HxClassMember.CondSpliceMember` - parallel member SIGNATURES
 *    inside the guard with the shared body after `#end`
 *    (`Pony/pony/Tools.hx:492`).
 *
 * Every case pairs the parse assertion with a byte-exact writer check:
 * the campaign's requirement is that BOTH branches of a region survive
 * a rewrite, which a parse-only assertion cannot show.
 */
class HxCondMemberSlotSliceTest extends HxTestHelpers {

	private static final TRIVIA_CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}}';

	public function testCondFnBodySemicolonVersusBlock(): Void {
		// std/flash/_std/haxe/Json.hx: `;` in one branch, `{ ... }` in the other.
		final src: String = 'class C {\n\tpublic static function parse(t:String):Dynamic #if flash11 ; #else {\n\t\treturn 1;\n\t} #end\n}';
		final inner: HxConditionalFnBody = expectCondBody(parseSingleFn(src).body);
		Assert.equals('flash11', (inner.cond: String));
		switch inner.body {
			case NoBody:
			case _:
				Assert.fail('expected NoBody in the then-branch, got ${inner.body}');
		}
		switch inner.elseBody {
			case BlockBody(_):
			case _:
				Assert.fail('expected BlockBody in the else-branch, got ${inner.elseBody}');
		}
		triviaEquals(src, 'Json.parse');
	}

	public function testCondFnBodyStatementPerBranchWritesVerbatim(): Void {
		// std/haxe/Int32.hx:175 - a whole `return ...;` statement per branch.
		final src: String = 'class C {\n\tfunction complement(a:Int):Int #if lua return lua.Boot.clamp(a); #else return clamp(a); #end\n}';
		triviaEquals(src, 'Int32 complement');
		roundTrip(src, 'Int32 complement');
	}

	public function testCondFnBodyElseifChain(): Void {
		final src: String = 'class C {\n\tfunction f():Int #if a return 1; #elseif b return 2; #else return 3; #end\n}';
		final inner: HxConditionalFnBody = expectCondBody(parseSingleFn(src).body);
		Assert.equals(1, inner.elseifs.length);
		triviaEquals(src, 'cond fn body elseif');
	}

	/**
	 * Regression guard for the `CondBody`-is-LAST dispatch rule: a region
	 * whose branches are single EXPRESSIONS parsed through
	 * `HxFnBody.ExprBody` -> `HxExpr.ConditionalExpr` before this slice and
	 * must keep doing so. Moving `CondBody` earlier in the enum silently
	 * re-routes it.
	 */
	public function testBalancedBlockBranchesStayExpressionScoped(): Void {
		final src: String = 'class C {\n\tfunction f():Int #if lua { return 1; } #else { return 2; } #end\n}';
		switch parseSingleFn(src).body {
			case ExprBody(_):
			case _:
				Assert.fail('expected ExprBody (ConditionalExpr), got a re-routed body');
		}
	}

	public function testPlainFnBodiesUnaffected(): Void {
		for (src in [
			'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}',
			'class C {\n\tfunction f():Int;\n}'
		]) {
			triviaEquals(src, src);
		}
		// A bare expression body is re-laid-out by the `functionBody` policy
		// (`Next`), so only idempotency is assertable byte-wise.
		roundTrip('class C {\n\tfunction f():Int return 1;\n}', 'expression body');
	}

	public function testCondFnNameWritesVerbatim(): Void {
		// haxelib format/format/tools/MemoryInput.hx:46.
		final src: String = 'class C {\n\toverride function #if (haxe_211 || haxe3) set_bigEndian #else setEndian #end(b) {\n\t\treturn b;\n\t}\n}';
		final decl: HxCondNameFnDecl = expectCondNameFnMember(singleMember(src));
		final inner: HxConditionalFnName = switch decl.region {
			case Conditional(v): v;
		};
		Assert.equals('(haxe_211 || haxe3)', (inner.cond: String));
		Assert.equals('set_bigEndian', (inner.name: String));
		Assert.equals('setEndian', (inner.elseName: String));
		triviaEquals(src, 'MemoryInput setter');
	}

	public function testCondFnNameElseifChainWritesVerbatim(): Void {
		final src: String = 'class C {\n\tfunction #if a foo #elseif b bar #else baz #end(x:Int):Void {}\n}';
		triviaEquals(src, 'cond fn name elseif');
	}

	public function testCondSemiExprSuppliesInitializerAndTerminator(): Void {
		// Pony/pony/net/http/HttpTools.hx:24 - `=` outside the guard, `;` inside it.
		final src: String = 'class C {\n\tpublic static var get:String = #if nodejs A.get; #else null; #end\n}';
		final decl: HxVarSemiCondInitDecl = expectVarSemiCondInitMember(singleMember(src));
		switch decl.region {
			case Conditional(inner):
				Assert.equals('nodejs', (inner.cond: String));
				Assert.notNull(inner.elseClause);
		}
		triviaEquals(src, 'HttpTools get');
	}

	public function testCondSemiExprElseifChain(): Void {
		final src: String = 'class C {\n\tpublic static var g:String = #if nodejs A.g; #elseif js B.g; #else null; #end\n}';
		triviaEquals(src, 'HttpTools getJson');
	}

	/**
	 * The bare-value spelling reaches `HxVarDecl.init` -> `HxConditionalExpr`
	 * and must stay there: `VarSemiCondInitMember` is tried before
	 * `VarMember`, so its region has to fail-rewind on every ordinary field.
	 */
	public function testBareValueConditionalInitializerUnaffected(): Void {
		for (src in [
			'class C {\n\tpublic static var g:Int = #if nodejs 1 #else 2 #end;\n}',
			'class C {\n\tvar x:Int = 1;\n}',
			'class C {\n\tvar x:Int;\n}'
		]) {
			expectVarMember(singleMember(src));
			triviaEquals(src, src);
		}
	}

	/**
	 * The statement-scope shape an `HxExpr`-level version of
	 * `HxConditionalSemiExpr` regressed (openfl `WebSocket.hx:987`, Pony
	 * `Logable.hx:228`): a metadata annotation routes the following `#if`
	 * region through `HxExpr.MetaExpr`, where only `HxCondSpliceExpr` can
	 * claim it. Scoping the new production to member position is what keeps
	 * this parsing.
	 */
	public function testMetaPrefixedStatementRegionStaysSpliced(): Void {
		final src: String = 'class C {\n\tfunction g():Void {\n\t\t@:privateAccess\n\t\t#if cpp\n\t\tvar r:Int = 1;\n\t\t#else\n\t\tvar r = 2;\n\t\t#end\n\t\tuse(r);\n\t}\n}';
		Assert.equals(1, HaxeModuleParser.parse(src).decls.length);
		roundTrip(src, 'meta-prefixed statement region');
	}

	public function testCondSharedBodyMemberKeepsTailAndBothSignatures(): Void {
		// Pony/pony/Tools.hx:492 - two signatures guarded, one shared body.
		final src: String = 'class C {\n#if (haxe_ver >= 3.300)\npublic static inline function sget<A, B:Constructible<Void -> Void>>(m:Map<A, B>, key:A):B\n#else\npublic static inline function sget<A, B: { function new():Void; }>(m:Map<A, B>, key:A):B\n#end\n\treturn m.exists(key) ? m[key] : m[key] = new B();\n}';
		final written: String = writeModule(src);
		Assert.isTrue(written.indexOf('Constructible<Void -> Void>') != -1, 'then-branch signature survives');
		Assert.isTrue(written.indexOf('{ function new():Void; }') != -1, 'else-branch signature survives');
		Assert.isTrue(written.indexOf('return m.exists(key)') != -1, 'shared body survives');
		roundTrip(src, 'Tools.sget');
	}

	/**
	 * `CondSpliceMember` is tried AFTER `Conditional`, so an ordinary
	 * guarded member keeps its structured representation. Without the
	 * ordering the raw swallow would consume the region and read the NEXT
	 * member's first identifier as the "shared body".
	 */
	public function testOrdinaryGuardedMemberStaysStructured(): Void {
		final src: String = 'class C {\n\t#if a\n\tvar x:Int;\n\t#end\n\tpublic function f():Void {}\n}';
		final ast: HxClassDecl = HaxeParser.parse(src);
		Assert.equals(2, ast.members.length);
		switch ast.members[0].member {
			case Conditional(_):
			case _:
				Assert.fail('expected a structured Conditional member, got ${ast.members[0].member}');
		}
	}

	/**
	 * Byte-exact check through the TRIVIA writer - the pipeline `hxq fmt`
	 * runs. `HxModuleWriter.write` normalises the per-branch `;` out of a
	 * conditional region (documented consume-not-store caveat), so it
	 * cannot show that both branches survive verbatim.
	 */
	private function triviaEquals(source: String, label: String): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(TRIVIA_CONFIG);
		opts.finalNewline = false;
		Assert.equals(source, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts), label);
	}

	private function parseSingleFn(source: String): HxFnDecl {
		return switch singleMember(source) {
			case FnMember(decl): decl;
			case _: throw 'expected FnMember';
		};
	}

	private function singleMember(source: String): HxClassMember {
		final ast: HxClassDecl = HaxeParser.parse(source);
		Assert.equals(1, ast.members.length);
		return ast.members[0].member;
	}

	private function expectCondBody(body: HxFnBody): HxConditionalFnBody {
		return switch body {
			case CondBody(inner): inner;
			case _: throw 'expected CondBody, got $body';
		};
	}

	private function expectCondNameFnMember(member: HxClassMember): HxCondNameFnDecl {
		return switch member {
			case CondNameFnMember(decl): decl;
			case _: throw 'expected CondNameFnMember, got $member';
		};
	}

	private function expectVarSemiCondInitMember(member: HxClassMember): HxVarSemiCondInitDecl {
		return switch member {
			case VarSemiCondInitMember(decl): decl;
			case _: throw 'expected VarSemiCondInitMember, got $member';
		};
	}

	private function writeModule(source: String): String {
		return anyparse.grammar.haxe.HxModuleWriter.write(HaxeModuleParser.parse(source));
	}

}
