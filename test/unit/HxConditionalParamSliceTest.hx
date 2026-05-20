package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxConditionalParam;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxParam;
import anyparse.grammar.haxe.HxParamBody;

/**
 * Slice 18a: cond-comp `#if … #end` inside a function-parameter list.
 *
 * `HxParam` gained a `Conditional(HxConditionalParam)` ctor — the
 * fn-param-scope completion of the cond-comp arc (decl / stmt / member /
 * modifier / obj-lit scopes already shipped). `#if <cond> <params>
 * [#elseif …] [#else …] #end` now parses where whole function-parameter
 * entries are expected, unblocking three corpus fixtures:
 * `whitespace/issue_345_conditionalised_function_parameters`,
 * `whitespace/issue_397_conditionals_in_function_args`, and
 * `whitespace/issue_582_type_hints_conditionals` (the latter two carry
 * the no-comma-adjacency form).
 *
 * Reuses Slice 18's `emitStarFieldSteps:@:sep+@:tryparse-no-close`
 * Lowering branch for the body Star inside `HxConditionalParam`. No
 * new Lowering or Writer primitive is introduced: the no-comma-adjacency
 * between a `Conditional` element and its siblings in
 * `HxFnDecl.params` (a `@:trivia @:sep(',') @:trail(')')` Star) is
 * handled at runtime via the per-element `Trivial.sepAfter:Bool`
 * mechanism — `matchLit(',')` returning false propagates to
 * `triviaSepStarExpr`'s `_emitSep` gate, which suppresses the inter-
 * element comma. The mechanism was introduced for `lineends/issue_111`
 * (obj-lit fields with omitted source comma) and is reused unchanged.
 *
 * Covers: single-conditional / conditional-first-required-follows /
 * required-first-conditional-follows / multi-elem body / `#else` /
 * `#elseif` / nested / empty-body-accepted / no-cond regression /
 * trailing-sep-before-`#end`. `#else` body is tested with a SINGLE
 * param only — the optional-kw Lowering path is the same Slice 18
 * limitation as `HxConditionalObjectField.elseBody`.
 */
class HxConditionalParamSliceTest extends HxTestHelpers {

	private function paramsOf(source:String):Array<HxParam> {
		final fn:HxFnDecl = parseSingleFnDecl(source);
		return fn.params;
	}

	// -- Sole Conditional elem, single Optional inner (issue_345 surface, type simplified for structural focus) --
	public function testSingleConditionalOnly():Void {
		final params:Array<HxParam> = paramsOf('class C { function foo(#if openfl ?vector:Int #end) {} }');
		Assert.equals(1, params.length);
		final cond:HxConditionalParam = expectConditionalParam(params[0]);
		Assert.equals('openfl', (cond.cond : String));
		Assert.equals(1, cond.body.length);
		final inner:HxParamBody = expectOptionalParam(cond.body[0]);
		Assert.equals('vector', (inner.name : String));
	}

	// -- Conditional first, Required follows (comma-separated, plain-mode safe).
	//
	// The no-comma adjacency form `(#if X bar:Int #end foobar:Int)` from
	// fork fixture issue_397 is exercised by the corpus, NOT here. That
	// form requires trivia-mode parsing (the `Trivial.sepAfter` per-element
	// flag set by `matchLit(',')` failing → writer's `_emitSep` suppresses
	// the comma); the `HaxeParser` entry used by `parseSingleFnDecl` is
	// the PLAIN parser, whose `@:sep+@:trail` Star strictly requires a
	// comma between elements. Both modes accept the comma-separated form
	// below, so this slice-test stays plain-parser-friendly.
	public function testConditionalFirstRequiredFollows():Void {
		final params:Array<HxParam> = paramsOf('class C { function foo(#if false bar:Int #end, foobar:Int) {} }');
		Assert.equals(2, params.length);
		final cond:HxConditionalParam = expectConditionalParam(params[0]);
		Assert.equals('false', (cond.cond : String));
		Assert.equals(1, cond.body.length);
		Assert.equals('bar', (expectRequiredParam(cond.body[0]).name : String));
		Assert.equals('foobar', (expectRequiredParam(params[1]).name : String));
	}

	// -- Required first, Conditional follows (comma-separated, plain-mode safe; see above for no-comma rationale).
	public function testRequiredFirstConditionalFollows():Void {
		final params:Array<HxParam> = paramsOf('class C { function foo(a:Int, #if x b:Int #end) {} }');
		Assert.equals(2, params.length);
		Assert.equals('a', (expectRequiredParam(params[0]).name : String));
		final cond:HxConditionalParam = expectConditionalParam(params[1]);
		Assert.equals('x', (cond.cond : String));
		Assert.equals('b', (expectRequiredParam(cond.body[0]).name : String));
	}

	// -- Multi-element body inside `#if … #end` (drives Slice 18 Lowering branch via comma sep) --
	public function testMultiElementBody():Void {
		final params:Array<HxParam> = paramsOf('class C { function foo(#if x a:Int, b:Int #end) {} }');
		Assert.equals(1, params.length);
		final cond:HxConditionalParam = expectConditionalParam(params[0]);
		Assert.equals(2, cond.body.length);
		Assert.equals('a', (expectRequiredParam(cond.body[0]).name : String));
		Assert.equals('b', (expectRequiredParam(cond.body[1]).name : String));
	}

	// -- `#if … #else …` — single-element bodies (elseBody no-sep limitation) --
	public function testConditionalElseSingleField():Void {
		final params:Array<HxParam> = paramsOf('class C { function foo(#if x a:Int #else b:Int #end) {} }');
		Assert.equals(1, params.length);
		final cond:HxConditionalParam = expectConditionalParam(params[0]);
		Assert.equals('x', (cond.cond : String));
		Assert.equals('a', (expectRequiredParam(cond.body[0]).name : String));
		final elseBody:Null<Array<HxParam>> = cond.elseBody;
		Assert.notNull(elseBody);
		if (elseBody != null) {
			Assert.equals(1, elseBody.length);
			Assert.equals('b', (expectRequiredParam(elseBody[0]).name : String));
		}
	}

	// -- `#elseif` chained clause, single-elem bodies --
	public function testConditionalElseifSingleField():Void {
		final params:Array<HxParam> = paramsOf('class C { function foo(#if x a:Int #elseif y b:Int #else c:Int #end) {} }');
		Assert.equals(1, params.length);
		final cond:HxConditionalParam = expectConditionalParam(params[0]);
		Assert.equals('x', (cond.cond : String));
		Assert.equals('a', (expectRequiredParam(cond.body[0]).name : String));
		Assert.equals(1, cond.elseifs.length);
		Assert.equals('y', (cond.elseifs[0].cond : String));
		Assert.equals('b', (expectRequiredParam(cond.elseifs[0].body[0]).name : String));
		final elseBody:Null<Array<HxParam>> = cond.elseBody;
		Assert.notNull(elseBody);
		if (elseBody != null) Assert.equals('c', (expectRequiredParam(elseBody[0]).name : String));
	}

	// -- Nested `#if` inside the body --
	public function testNestedConditional():Void {
		final params:Array<HxParam> = paramsOf('class C { function foo(#if outer #if inner a:Int #end #end) {} }');
		Assert.equals(1, params.length);
		final outer:HxConditionalParam = expectConditionalParam(params[0]);
		Assert.equals('outer', (outer.cond : String));
		Assert.equals(1, outer.body.length);
		final inner:HxConditionalParam = expectConditionalParam(outer.body[0]);
		Assert.equals('inner', (inner.cond : String));
		Assert.equals('a', (expectRequiredParam(inner.body[0]).name : String));
	}

	// -- Empty body `#if X #end` accepted (HxParam is bare sum-type, like HxObjectField) --
	public function testEmptyConditionalBodyAccepted():Void {
		final params:Array<HxParam> = paramsOf('class C { function foo(#if x #end) {} }');
		Assert.equals(1, params.length);
		final cond:HxConditionalParam = expectConditionalParam(params[0]);
		Assert.equals('x', (cond.cond : String));
		Assert.equals(0, cond.body.length);
	}

	// -- Regression: a normal fn with NO `#if` parses unchanged --
	public function testNoConditionalRegression():Void {
		final params:Array<HxParam> = paramsOf('class C { function foo(a:Int, b:String, ?c:Bool) {} }');
		Assert.equals(3, params.length);
		Assert.equals('a', (expectRequiredParam(params[0]).name : String));
		Assert.equals('b', (expectRequiredParam(params[1]).name : String));
		Assert.equals('c', (expectOptionalParam(params[2]).name : String));
	}

	// -- Trailing comma BEFORE the closing `#end` tolerated by Slice 18's Lowering branch --
	public function testTrailingSepBeforeEnd():Void {
		final params:Array<HxParam> = paramsOf('class C { function foo(#if x a:Int, b:Int, #end) {} }');
		Assert.equals(1, params.length);
		final cond:HxConditionalParam = expectConditionalParam(params[0]);
		Assert.equals(2, cond.body.length);
		Assert.equals('a', (expectRequiredParam(cond.body[0]).name : String));
		Assert.equals('b', (expectRequiredParam(cond.body[1]).name : String));
	}
}
