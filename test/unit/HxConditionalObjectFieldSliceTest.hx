package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxConditionalObjectField;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxObjectField;
import anyparse.grammar.haxe.HxObjectFieldBody;
import anyparse.grammar.haxe.HxObjectLit;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice 18: cond-comp `#if … #end` inside an object-literal field list.
 *
 * `HxObjectField` gained a `Conditional(HxConditionalObjectField)` ctor —
 * the object-literal completion of the cond-comp arc (decl / stmt /
 * member / modifier scopes already shipped). `#if <cond> <fields>
 * [#elseif …] [#else …] #end` now parses where whole object-literal
 * field entries are expected, unblocking corpus fixtures that guard
 * object-literal fields with `#if debug` / `#if flash`.
 *
 * Drives Slice 18's new Lowering branch
 * `emitStarFieldSteps:@:sep+@:tryparse-no-close`: the body Star inside
 * `HxConditionalObjectField` is `@:sep(',') @:tryparse var
 * body:Array<HxObjectField>` with no `@:trail` — the enclosing
 * `HxObjectField.Conditional` ctor's `@:trail('#end')` consumes the
 * closing directive.
 *
 * Covers the single-branch / multi-field-body / between-plain-fields /
 * empty-body / nested / no-conditional-regression / `#elseif` clause
 * shapes. Empty body is ACCEPTED here (unlike `HxConditionalMember`)
 * because `HxObjectField` is a bare sum-type with no mandatory wrapping
 * struct that forces a throw on the terminator.
 *
 * `#else` body covered by `HxConditionalObjectField.elseBody` is
 * deliberately tested with a SINGLE field only — the optional-kw
 * Lowering path (`emitOptionalKwStarFieldSteps`) does not yet support
 * `@:sep` peek; a multi-field `#else` body is a documented Slice 18
 * limitation pending a follow-up extension of that path.
 */
class HxConditionalObjectFieldSliceTest extends HxTestHelpers {

	private function objectLitOf(source:String):HxObjectLit {
		final decl:HxVarDecl = parseSingleVarDecl(source);
		return switch decl.init {
			case ObjectLit(lit): lit;
			case _: throw 'expected ObjectLit, got ${decl.init}';
		};
	}

	// -- `#if` wrapping a single field inside an object literal --

	public function testSingleFieldConditional():Void {
		final lit:HxObjectLit = objectLitOf('class C { var x:Dynamic = { #if flash a: 1 #end }; }');
		Assert.equals(1, lit.fields.length);
		final cond:HxConditionalObjectField = expectConditionalObjectField(lit.fields[0]);
		Assert.equals('flash', (cond.cond : String));
		Assert.equals(1, cond.body.length);
		Assert.equals('a', (expectObjectFieldBody(cond.body[0]).name : String));
		Assert.equals(0, cond.elseifs.length);
		Assert.isNull(cond.elseBody);
	}

	// -- `#if` wrapping multiple comma-separated fields (the new Lowering branch) --

	public function testMultiFieldConditionalBody():Void {
		final lit:HxObjectLit = objectLitOf('class C { var x:Dynamic = { #if debug a: 1, b: 2 #end }; }');
		Assert.equals(1, lit.fields.length);
		final cond:HxConditionalObjectField = expectConditionalObjectField(lit.fields[0]);
		Assert.equals('debug', (cond.cond : String));
		Assert.equals(2, cond.body.length);
		Assert.equals('a', (expectObjectFieldBody(cond.body[0]).name : String));
		Assert.equals('b', (expectObjectFieldBody(cond.body[1]).name : String));
	}

	// -- Plain field before a conditional field --

	public function testPlainFieldThenConditional():Void {
		final lit:HxObjectLit = objectLitOf('class C { var x:Dynamic = { name: "foo", #if debug count: 1 #end }; }');
		Assert.equals(2, lit.fields.length);
		Assert.equals('name', (expectObjectFieldBody(lit.fields[0]).name : String));
		final cond:HxConditionalObjectField = expectConditionalObjectField(lit.fields[1]);
		Assert.equals('debug', (cond.cond : String));
		Assert.equals('count', (expectObjectFieldBody(cond.body[0]).name : String));
	}

	// -- Conditional field between two plain fields --

	public function testConditionalBetweenPlainFields():Void {
		final lit:HxObjectLit = objectLitOf('class C { var x:Dynamic = { a: 1, #if debug b: 2 #end, c: 3 }; }');
		Assert.equals(3, lit.fields.length);
		Assert.equals('a', (expectObjectFieldBody(lit.fields[0]).name : String));
		final cond:HxConditionalObjectField = expectConditionalObjectField(lit.fields[1]);
		Assert.equals('debug', (cond.cond : String));
		Assert.equals('b', (expectObjectFieldBody(cond.body[0]).name : String));
		Assert.equals('c', (expectObjectFieldBody(lit.fields[2]).name : String));
	}

	// -- Empty body `#if X #end` accepted (diverges from HxConditionalMember) --
	//
	// HxObjectField has no mandatory wrapping struct that would throw on
	// the terminator — the tryparse Star simply rolls back to zero
	// elements and the enclosing `@:trail('#end')` consumes `#end`. This
	// is doc'd on `HxConditionalObjectField` and is the deliberate
	// divergence from member/decl-scope, not a regression.

	public function testEmptyConditionalBodyAccepted():Void {
		final lit:HxObjectLit = objectLitOf('class C { var x:Dynamic = { #if flash #end }; }');
		Assert.equals(1, lit.fields.length);
		final cond:HxConditionalObjectField = expectConditionalObjectField(lit.fields[0]);
		Assert.equals('flash', (cond.cond : String));
		Assert.equals(0, cond.body.length);
	}

	// -- `#if … #else …` — single-field bodies (elseBody no-sep limitation) --

	public function testConditionalElseSingleField():Void {
		final lit:HxObjectLit = objectLitOf('class C { var x:Dynamic = { #if js a: 1 #else a: 2 #end }; }');
		Assert.equals(1, lit.fields.length);
		final cond:HxConditionalObjectField = expectConditionalObjectField(lit.fields[0]);
		Assert.equals('js', (cond.cond : String));
		Assert.equals('a', (expectObjectFieldBody(cond.body[0]).name : String));
		final elseBody:Null<Array<HxObjectField>> = cond.elseBody;
		Assert.notNull(elseBody);
		if (elseBody != null) {
			Assert.equals(1, elseBody.length);
			Assert.equals('a', (expectObjectFieldBody(elseBody[0]).name : String));
		}
	}

	// -- `#elseif` chained clause, body single-field (matches elseifs' new branch) --

	public function testConditionalElseifSingleField():Void {
		final lit:HxObjectLit = objectLitOf(
			'class C { var x:Dynamic = { #if js a: 1 #elseif sys a: 2 #else a: 3 #end }; }'
		);
		Assert.equals(1, lit.fields.length);
		final cond:HxConditionalObjectField = expectConditionalObjectField(lit.fields[0]);
		Assert.equals('js', (cond.cond : String));
		Assert.equals('a', (expectObjectFieldBody(cond.body[0]).name : String));
		Assert.equals(1, cond.elseifs.length);
		Assert.equals('sys', (cond.elseifs[0].cond : String));
		Assert.equals('a', (expectObjectFieldBody(cond.elseifs[0].body[0]).name : String));
		final elseBody:Null<Array<HxObjectField>> = cond.elseBody;
		Assert.notNull(elseBody);
		if (elseBody != null) Assert.equals('a', (expectObjectFieldBody(elseBody[0]).name : String));
	}

	// -- Nested `#if` inside the body --

	public function testNestedConditional():Void {
		final lit:HxObjectLit = objectLitOf(
			'class C { var x:Dynamic = { #if outer #if inner a: 1 #end #end }; }'
		);
		Assert.equals(1, lit.fields.length);
		final outer:HxConditionalObjectField = expectConditionalObjectField(lit.fields[0]);
		Assert.equals('outer', (outer.cond : String));
		Assert.equals(1, outer.body.length);
		final inner:HxConditionalObjectField = expectConditionalObjectField(outer.body[0]);
		Assert.equals('inner', (inner.cond : String));
		Assert.equals('a', (expectObjectFieldBody(inner.body[0]).name : String));
	}

	// -- Regression: an object literal with NO `#if` is unaffected --

	public function testNoConditionalRegression():Void {
		final lit:HxObjectLit = objectLitOf('class C { var x:Dynamic = { a: 1, b: 2 }; }');
		Assert.equals(2, lit.fields.length);
		Assert.equals('a', (expectObjectFieldBody(lit.fields[0]).name : String));
		Assert.equals('b', (expectObjectFieldBody(lit.fields[1]).name : String));
	}

	// -- Trailing comma BEFORE the closing `#end` tolerated by the new branch --

	public function testTrailingSepBeforeEnd():Void {
		final lit:HxObjectLit = objectLitOf('class C { var x:Dynamic = { #if debug a: 1, b: 2, #end }; }');
		Assert.equals(1, lit.fields.length);
		final cond:HxConditionalObjectField = expectConditionalObjectField(lit.fields[0]);
		Assert.equals(2, cond.body.length);
		Assert.equals('a', (expectObjectFieldBody(cond.body[0]).name : String));
		Assert.equals('b', (expectObjectFieldBody(cond.body[1]).name : String));
	}
}
