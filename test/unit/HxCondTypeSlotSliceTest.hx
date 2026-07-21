package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxAbstractClause;
import anyparse.grammar.haxe.HxAbstractDecl;
import anyparse.grammar.haxe.HxAnonMember;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxConditionalAnonField;
import anyparse.grammar.haxe.HxConditionalAbstractClause;
import anyparse.grammar.haxe.HxConditionalDecl;
import anyparse.grammar.haxe.HxConditionalType;
import anyparse.grammar.haxe.HxConditionalTypeElse;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxHeritageClause;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxParamBody;
import anyparse.grammar.haxe.HxType;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Conditional-compilation regions that open in a TYPE or DECLARATION
 * slot rather than at a statement / member / parameter boundary.
 *
 * Six independent gaps, each pinned by the real module that motivated
 * it. All six were verified to FAIL on the pre-slice grammar, so every
 * assertion here is a live regression net rather than documentation:
 *
 *  - the `#if` condition atom capped paren nesting at two levels, so
 *    `#if (((a)))` and the std lib's own
 *    `sys/Http.hx` guard truncated mid-condition;
 *  - `from` / `to` clauses of an abstract could not sit inside a guard
 *    (lime `utils/ArrayBuffer.hx`, `graphics/OpenGLES2RenderContext.hx`,
 *    `_internal/backend/html5/HTML5Thread.hx`);
 *  - a field of an anonymous STRUCTURE TYPE could not
 *    (`format/bmp/Data.hx`, lime `tools/WindowData.hx`,
 *    `graphics/RenderContextAttributes.hx`);
 *  - a module-level region could not END on metadata belonging to the
 *    declaration after `#end` (lime `utils/DataPointer.hx`,
 *    `tools/HXProject.hx`);
 *  - the `#else` branch of a type-slot conditional could not carry a
 *    heritage clause (openfl `display/Tilemap.hx`);
 *  - a type-slot conditional could carry neither an initializer
 *    (openfl `display/Preloader.hx`) nor the parameters that follow it
 *    (openfl `text/_internal/ShapeCache.hx`).
 *
 * The regression half of each group pins that the unguarded form, and
 * the guarded forms that already parsed, keep their exact pre-slice
 * AST.
 */
class HxCondTypeSlotSliceTest extends HxTestHelpers {

	public function testCondAtomAcceptsThreeParenLevels(): Void {
		final cond: String = memberConditionCond('class C { #if (((a))) var x:Int; #end }');
		Assert.equals('(((a)))', cond);
	}

	public function testCondAtomAcceptsNestedOrChain(): Void {
		final cond: String = memberConditionCond('class C { #if (a || (b || (c || d))) var x:Int; #end }');
		Assert.equals('(a || (b || (c || d)))', cond);
	}

	public function testCondAtomAcceptsStdHttpGuard(): Void {
		// std/sys/Http.hx:109 - the deepest condition in the dependency
		// trees, `(macro || interp)` sitting at paren depth 4.
		final guard: String = '(!no_ssl && (hxssl || hl || cpp || (neko && !(macro || interp) || eval) || (lua && !lua_vanilla)))';
		Assert.equals(guard, memberConditionCond('class C { #if $guard var x:Int; #end }'));
	}

	public function testCondAtomStillRejectsDepthFive(): Void {
		// The cap moved from two to four, it did not disappear. Pinned so
		// a future deepening is a deliberate edit, not a silent drift.
		Assert.raises(HaxeModuleParser.parse.bind('class C { #if ((((( a ))))) var x:Int; #end }'));
	}

	public function testConditionalAbstractClauseThenBranch(): Void {
		// lime/utils/ArrayBuffer.hx:10
		final ad: HxAbstractDecl = firstAbstract('abstract A(Bytes) from Bytes to Bytes #if doc_gen from Dynamic to Dynamic #end {}');
		Assert.equals(3, ad.clauses.length);
		final inner: HxConditionalAbstractClause = expectConditionalClause(ad.clauses[2]);
		Assert.equals('doc_gen', (inner.cond: String));
		Assert.equals(2, inner.body.length);
		switch inner.body[0] {
			case FromClause(_):
				Assert.pass();
			case _:
				Assert.fail('expected FromClause, got ${inner.body[0]}');
		}
	}

	public function testConditionalAbstractClauseElseBranchHoldsSeveralClauses(): Void {
		// lime/_internal/backend/html5/HTML5Thread.hx:645
		final ad: HxAbstractDecl = firstAbstract('abstract T(Dynamic) #if macro from Dynamic #else from A from B from C #end {}');
		Assert.equals(1, ad.clauses.length);
		final inner: HxConditionalAbstractClause = expectConditionalClause(ad.clauses[0]);
		Assert.equals(1, inner.body.length);
		final elseBody: Null<Array<HxAbstractClause>> = inner.elseBody;
		if (elseBody == null) {
			Assert.fail('expected an #else body');
			return;
		}
		Assert.equals(3, elseBody.length);
	}

	public function testConditionalAbstractClauseElseifArm(): Void {
		final ad: HxAbstractDecl = firstAbstract('abstract T(Dynamic) #if macro from Dynamic #elseif js to B #else from C #end {}');
		final inner: HxConditionalAbstractClause = expectConditionalClause(ad.clauses[0]);
		Assert.equals(1, inner.elseifs.length);
		Assert.equals('js', (inner.elseifs[0].cond: String));
		switch inner.elseifs[0].body[0] {
			case ToClause(_):
				Assert.pass();
			case _:
				Assert.fail('expected ToClause, got ${inner.elseifs[0].body[0]}');
		}
	}

	public function testPlainAbstractClausesUnaffected(): Void {
		final ad: HxAbstractDecl = firstAbstract('abstract A(Int) from Int to Int {}');
		Assert.equals(2, ad.clauses.length);
		switch ad.clauses[0] {
			case FromClause(_):
				Assert.pass();
			case _:
				Assert.fail('expected FromClause, got ${ad.clauses[0]}');
		}
		Assert.equals(0, firstAbstract('abstract A(Int) {}').clauses.length);
	}

	public function testConditionalAnonFieldBothBranches(): Void {
		// format/bmp/Data.hx:36
		final fields: Array<HxAnonMember> =
			typedefAnon('typedef D = {var a:Int; #if (haxe_ver < 4) var b:Null<Bytes>; #else var ?b:Bytes; #end}');
		Assert.equals(2, fields.length);
		final inner: HxConditionalAnonField = expectConditionalAnonField(fields[1]);
		Assert.equals('(haxe_ver < 4)', (inner.cond: String));
		Assert.equals(1, inner.body.length);
		final elseBody: Null<Array<HxAnonMember>> = inner.elseBody;
		if (elseBody == null) {
			Assert.fail('expected an #else body');
			return;
		}
		Assert.equals(1, elseBody.length);
		Assert.equals('b', (expectVarField(elseBody[0].field).name: String));
	}

	public function testConditionalAnonFieldKeepsInnerMetadata(): Void {
		// lime/tools/WindowData.hx:28 - the guarded field carries its own
		// `@:optional`, which is why the body Star holds `HxAnonMember`
		// (the metadata wrapper) and not the bare `HxAnonField` dispatch.
		final fields: Array<HxAnonMember> =
			typedefAnon('typedef W = {@:optional var t:String; #if (js && html5) @:optional var e:Element; #end}');
		Assert.equals(2, fields.length);
		final inner: HxConditionalAnonField = expectConditionalAnonField(fields[1]);
		Assert.equals(1, inner.body.length);
		Assert.equals(1, inner.body[0].meta.length);
	}

	public function testPlainAnonFieldsUnaffected(): Void {
		Assert.equals(2, typedefAnon('typedef D = {a:Int, b:String}').length);
		Assert.equals(2, typedefAnon('typedef D = {var a:Int; var b:String;}').length);
	}

	public function testConditionalDeclRegionEndingOnDanglingMetadata(): Void {
		// lime/utils/DataPointer.hx:11 - the `@:access` tag applies to the
		// abstract AFTER `#end`, but is written inside the guard.
		final ast: HxModule = HaxeModuleParser.parse('#if x\nimport a.B;\n@:access(a.B)\n#end\nclass C {}');
		final region: HxConditionalDecl = expectConditionalDecl(ast.decls[0].decl);
		Assert.equals(1, region.body.length);
		Assert.equals(1, region.trailingMeta.length);
		Assert.equals(2, ast.decls.length);
	}

	public function testImportOnlyRegionKeepsEmptyTrailingMetadata(): Void {
		// The slot is strictly additive: the shape that already parsed
		// must keep routing through `HxDecl.Conditional` with nothing in
		// the new Star.
		final ast: HxModule = HaxeModuleParser.parse('#if x\nimport a.B;\n#end\nclass C {}');
		final region: HxConditionalDecl = expectConditionalDecl(ast.decls[0].decl);
		Assert.equals(1, region.body.length);
		Assert.equals(0, region.trailingMeta.length);
	}

	public function testMetaOnlyRegionStillRidesTheMetadataStar(): Void {
		// A metadata-only region is claimed by `HxTopLevelDecl.meta`
		// BEFORE the decl dispatch - it must not become a
		// `HxDecl.Conditional` with a trailing-metadata Star.
		final ast: HxModule = HaxeModuleParser.parse('#if x\n@:access(a.B)\n#end\nclass C {}');
		Assert.equals(1, ast.decls.length);
		Assert.equals(1, ast.decls[0].meta.length);
	}

	public function testCondTypeElseBranchCarriesHeritage(): Void {
		// openfl/display/Tilemap.hx:40
		final c: HxClassDecl = firstClass('class T extends #if !flash DisplayObject #else Bitmap implements IDO #end implements ITC {}');
		Assert.equals(2, c.heritage.length);
		final elseClause: Null<HxConditionalTypeElse> = extendsConditional(c.heritage[0]).elseClause;
		if (elseClause == null) {
			Assert.fail('expected an #else clause');
			return;
		}
		Assert.equals(1, elseClause.heritage.length);
		switch elseClause.heritage[0] {
			case ImplementsClause(_):
				Assert.pass();
			case _:
				Assert.fail('expected ImplementsClause, got ${elseClause.heritage[0]}');
		}
	}

	public function testCondTypeWithoutHeritageKeepsEmptyStar(): Void {
		final c: HxClassDecl = firstClass('class T extends #if x A #else B #end {}');
		final elseClause: Null<HxConditionalTypeElse> = extendsConditional(c.heritage[0]).elseClause;
		if (elseClause == null) {
			Assert.fail('expected an #else clause');
			return;
		}
		Assert.equals(0, elseClause.heritage.length);
	}

	public function testCondTypeCarriesInitializer(): Void {
		// openfl/display/Preloader.hx:20 - the `=` lives INSIDE the guard
		// because the guard opened in the type slot. Mirror image of
		// `HxVarDecl.condInit`, where the guard opens where the `=` would.
		final c: HxClassDecl = firstClass(
			'class P {var onComplete:#if lime Event<Void->Void> = new Event<Void->Void>() #else Dynamic #end;}'
		);
		final decl: HxVarDecl = expectVarMember(c.members[0].member);
		Assert.isNull(decl.init);
		Assert.notNull(expectConditionalType(decl.type).init);
	}

	public function testCondTypeWithoutInitializerKeepsNullSlot(): Void {
		final c: HxClassDecl = firstClass('class P {var v:#if lime A #else B #end;}');
		Assert.isNull(expectConditionalType(expectVarMember(c.members[0].member).type).init);
	}

	public function testCondTypeCarriesFurtherParameters(): Void {
		// openfl/text/_internal/ShapeCache.hx:37 - the guard opens inside
		// `getPositions`'s type and closes two parameters later, so the
		// trailing parameter rides the type-position region.
		final fn: HxFnDecl = parseSingleFnDecl(
			'class S {function f(getPositions:#if (js && html5) Void->Array<Float>, wordKey:String = null #else TextLayout #end):Int {return 1;}}'
		);
		Assert.equals(1, fn.params.length);
		final body: HxParamBody = paramBody(fn.params[0]);
		final region: HxConditionalType = expectConditionalType(body.type);
		Assert.equals(1, region.moreParams.length);
		Assert.equals('wordKey', (paramBody(region.moreParams[0].param).name: String));
	}

	public function testPlainConditionalTypeKeepsEmptyParamStar(): Void {
		final fn: HxFnDecl = parseSingleFnDecl('class S {function f(a:#if js Int #else String #end, b:Int):Void {}}');
		Assert.equals(2, fn.params.length);
		Assert.equals(0, expectConditionalType(paramBody(fn.params[0]).type).moreParams.length);
	}

	public function testEveryNewShapeWritesVerbatim(): Void {
		for (src in [
			'abstract A(Bytes) from Bytes to Bytes #if doc_gen from Dynamic to Dynamic #end {}',
			'abstract T(Dynamic) #if macro from Dynamic #else from A from B from C #end {}',
			'typedef D = {var a:Int; #if x var b:Int; #else var ?b:String; #end}',
			'class T extends #if !flash DisplayObject #else Bitmap implements IDO #end implements ITC {}'
		]) triviaRoundTrip('package p;\n\n$src');
		triviaRoundTrip(
			'package p;\n\nclass P {\n\tvar onComplete:#if lime Event<Void->Void> = new Event<Void->Void>() #else Dynamic #end;\n}'
		);
		triviaRoundTrip('package p;\n\nclass C {\n\t#if (a || (b || (c || d)))\n\tvar x:Int;\n\t#end\n}');
		triviaRoundTrip(
			'package p;\n\nclass S {\n\tfunction f(getPositions:#if (js && html5) Void->Array<Float>, wordKey:String = null #else TextLayout #end):Int {\n\t\treturn 1;\n\t}\n}'
		);
	}

	private function memberConditionCond(source: String): String {
		final c: HxClassDecl = firstClass(source);
		return (expectConditionalMember(c.members[0].member).cond: String);
	}

	private function firstClass(source: String): HxClassDecl {
		return expectClassDecl(HaxeModuleParser.parse(source).decls[0]);
	}

	private function firstAbstract(source: String): HxAbstractDecl {
		return expectAbstractDecl(HaxeModuleParser.parse(source).decls[0]);
	}

	private function typedefAnon(source: String): Array<HxAnonMember> {
		return expectAnonMembers(expectTypedefDecl(HaxeModuleParser.parse(source).decls[0]).type);
	}

	private function expectConditionalClause(clause: HxAbstractClause): HxConditionalAbstractClause {
		return switch clause {
			case Conditional(inner): inner;
			case _: throw 'expected HxAbstractClause.Conditional, got $clause';
		};
	}

	private function expectConditionalAnonField(member: HxAnonMember): HxConditionalAnonField {
		return switch member.field {
			case Conditional(inner): inner;
			case _: throw 'expected HxAnonField.Conditional, got ${member.field}';
		};
	}

	private function extendsConditional(clause: HxHeritageClause): HxConditionalType {
		return switch clause {
			case ExtendsClause(type): expectConditionalType(type);
			case _: throw 'expected HxHeritageClause.ExtendsClause, got $clause';
		};
	}

	private function triviaRoundTrip(source: String): Void {
		Assert.equals('$source\n', HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source)));
	}

}
