package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxConditionalType;
import anyparse.grammar.haxe.HxConditionalTypeElse;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxTypedefDecl;

/**
 * Slice ω-cond-comp-type: preprocessor-guarded conditional compilation
 * at type position — `typedef X = #if cond T1; [#else T2;] #end`.
 *
 * `HxType` gained a `@:kw('#if') @:trail('#end') ConditionalType` ctor
 * (twin of `HxExpr.ConditionalExpr` on the expression Pratt enum) with
 * an `HxConditionalType` body. The `#else` branch is wrapped in
 * `HxConditionalTypeElse` so its `@:trailOpt(';')` sits on a
 * non-optional field (trailOpt is dropped on optional fields).
 *
 * The corpus driver is `whitespace/issue_531_conditional_typedef*` — a
 * conditional `typedef` whose two branches are competing function-type
 * signatures, each terminated by `;` before `#else` / `#end`. Covers:
 * the isolated ctor (bare-ident cond, `#else` present / absent),
 * parenthesised condition, the verbatim corpus form, and idempotency.
 * The per-branch `;` is consume-not-store (deferred-byte-reemit
 * caveat) so re-emit normalises rather than byte-preserves — the
 * fixture parses (skip → fail) until a follow-up adds `;` preservation.
 */
class HxConditionalTypeSliceTest extends HxTestHelpers {

	// -- Isolated ctor: bare-ident cond, both branches present --

	public function testConditionalTypedefIfElse(): Void {
		final module: HxModule = HaxeModuleParser.parse('typedef X = #if js String; #else Int; #end');
		Assert.equals(1, module.decls.length);
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('X', (td.name: String));
		final cond: HxConditionalType = expectConditionalType(td.type);
		Assert.equals('js', (cond.cond: String));
		Assert.equals('String', (expectNamedType(cond.type).name: String));
		final elseClause: Null<HxConditionalTypeElse> = cond.elseClause;
		Assert.notNull(elseClause);
		if (elseClause != null) Assert.equals('Int', (expectNamedType(elseClause.type).name: String));
	}

	// -- Isolated ctor: no `#else` clause (elseClause stays null) --

	public function testConditionalTypedefNoElse(): Void {
		final module: HxModule = HaxeModuleParser.parse('typedef X = #if js String; #end');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		final cond: HxConditionalType = expectConditionalType(td.type);
		Assert.equals('js', (cond.cond: String));
		Assert.equals('String', (expectNamedType(cond.type).name: String));
		Assert.isNull(cond.elseClause);
	}

	// -- Parenthesised condition (the corpus `(haxe_ver >= 4)` shape) --

	public function testConditionalTypedefParenCond(): Void {
		final module: HxModule = HaxeModuleParser.parse('typedef X = #if (haxe_ver >= 4) String; #else Int; #end');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		final cond: HxConditionalType = expectConditionalType(td.type);
		final elseClause: Null<HxConditionalTypeElse> = cond.elseClause;
		Assert.notNull(elseClause);
		if (elseClause != null) Assert.equals('Int', (expectNamedType(elseClause.type).name: String));
	}

	// -- Verbatim corpus form: whitespace/issue_531_conditional_typedef --

	public function testConditionalTypedefCorpusForm(): Void {
		final module: HxModule = HaxeModuleParser.parse(
			'typedef ChildProcessExecCallback = #if (haxe_ver >= 4) (error : Null<ChildProcessExecError>, stdout : EitherType<Buffer, String>, \nstderr : EitherType<Buffer, String>) -> Void; #else Null<ChildProcessExecError>->EitherType<Buffer, String>->EitherType<Buffer, String>->Void; #end'
		);
		Assert.equals(1, module.decls.length);
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('ChildProcessExecCallback', (td.name: String));
		final cond: HxConditionalType = expectConditionalType(td.type);
		Assert.notNull(cond.elseClause);
	}

	// -- Idempotency on the corpus form --

	public function testConditionalTypedefRoundTrip(): Void {
		roundTrip(
			'typedef ChildProcessExecCallback = #if (haxe_ver >= 4) (error : Null<ChildProcessExecError>, stdout : EitherType<Buffer, String>, \nstderr : EitherType<Buffer, String>) -> Void; #else Null<ChildProcessExecError>->EitherType<Buffer, String>->EitherType<Buffer, String>->Void; #end'
		);
	}

	// -- Regression: a plain typedef is unaffected by the new ctor --

	public function testNoConditionalTypeRegression(): Void {
		final module: HxModule = HaxeModuleParser.parse('typedef Y = Array<Int>;');
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('Array', (expectNamedType(td.type).name: String));
	}

}
