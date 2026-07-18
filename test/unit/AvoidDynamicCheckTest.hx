package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.AvoidDynamic;
import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

using StringTools;

/**
 * The `avoid-dynamic` check: a raw `Dynamic` in a declared type position — field,
 * parameter, return, generic type argument, or annotated local — is flagged
 * `Info`. `haxe.DynamicAccess` / a bare `DynamicAccess` and the sanctioned `Any`
 * top type are not flagged; a nested `Dynamic` (`Null<Dynamic>`) reports as a type
 * argument; an extern type's members are skipped. Report-only (no autofix), with
 * the span pinned to the exact `Dynamic` token for a future usage-inference pass.
 */
class AvoidDynamicCheckTest extends Test {

	public function testFieldFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tvar x:Dynamic;\n}');
		Assert.equals(1, vs.length);
		Assert.equals('avoid-dynamic', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('field'));
	}

	public function testParameterFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f(p:Dynamic):Void {}\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('parameter'));
	}

	public function testReturnFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Dynamic { return null; }\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('return'));
	}

	public function testTypeArgumentFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tvar m:Map<String, Dynamic>;\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('type argument'));
	}

	public function testNullDynamicIsTypeArgument(): Void {
		// The nested `Dynamic` inside `Null<Dynamic>` is a type argument, not a bare field type.
		final vs: Array<Violation> = violations('class C {\n\tvar n:Null<Dynamic>;\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('type argument'));
	}

	public function testLocalFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tvar x:Dynamic = null;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('local'));
	}

	public function testQualifiedDynamicAccessNotFlagged(): Void {
		// `haxe.DynamicAccess<Int>` is a typed abstraction — the whole-word match excludes it.
		Assert.equals(0, violations('class C {\n\tvar d:haxe.DynamicAccess<Int>;\n}').length);
	}

	public function testBareDynamicAccessNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tvar d:DynamicAccess<Int>;\n}').length);
	}

	public function testDynamicAccessOfDynamicFlagsInnerOnly(): Void {
		// `DynamicAccess<Dynamic>`: the outer abstraction is fine, the inner raw Dynamic is a type argument.
		final src: String = 'class C {\n\tvar d:DynamicAccess<Dynamic>;\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('type argument'));
		Assert.equals('Dynamic', slice(src, vs[0]));
	}

	public function testAnyNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tvar a:Any;\n}').length);
	}

	public function testFunctionTypeParameterFlaggedAtParameterPosition(): Void {
		// `Dynamic->Void` in a parameter position: the arrow's `Dynamic` is at depth 0, flagged as a parameter.
		final vs: Array<Violation> = violations('class C {\n\tfunction f(cb:Dynamic->Void):Void {}\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('parameter'));
	}

	public function testExternClassMembersSkipped(): Void {
		// Extern types legitimately interop through Dynamic — a built-in carve-out.
		Assert.equals(0, violations('extern class E {\n\tvar raw:Dynamic;\n\tfunction m(a:Dynamic):Dynamic;\n}').length);
	}

	public function testBoundaryLocalDistinctMessage(): Void {
		// A local initialised from a Reflect / Json boundary call gets the "narrow where consumed" message.
		final vs: Array<Violation> =
			violations('class C {\n\tfunction f():Void {\n\t\tvar x:Dynamic = Reflect.field(this, \'k\');\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('boundary'));
	}

	public function testSpanPointsAtDynamicToken(): Void {
		// The span is the exact `Dynamic` token (not the enclosing declaration) — the anchor a future D3 fix needs.
		final src: String = 'class C {\n\tvar x:Dynamic;\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('Dynamic', slice(src, vs[0]));
	}

	public function testMultiplePositionsInOneFunction(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f(p:Dynamic, q:Array<Dynamic>):Dynamic { return p; }\n}');
		// p -> parameter, q's Array<Dynamic> -> type argument, return -> return.
		Assert.equals(3, vs.length);
	}

	public function testReportOnlyNoFix(): Void {
		final src: String = 'class C {\n\tvar x:Dynamic;\n}';
		final check: AvoidDynamic = new AvoidDynamic();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testExcludePathsConfig(): Void {
		// A file whose path matches a configured `excludePaths` pattern is skipped entirely.
		final check: AvoidDynamic = new AvoidDynamic();
		check.setConfigResolver(_ -> LintConfig.parse('{"rules":{"avoid-dynamic":{"excludePaths":["interop/"]}}}'));
		final files: Array<{ file: String, source: String }> = [
			{ file: 'src/interop/Native.hx', source: 'class C {\n\tvar x:Dynamic;\n}' },
			{ file: 'src/app/Main.hx', source: 'class D {\n\tvar y:Dynamic;\n}' }
		];
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals('src/app/Main.hx', vs[0].file);
	}

	public function testExcludeMetaConfig(): Void {
		// A member carrying a configured exclusion metadata is skipped; a sibling without it is still flagged.
		final check: AvoidDynamic = new AvoidDynamic();
		check.setConfigResolver(_ -> LintConfig.parse('{"rules":{"avoid-dynamic":{"excludeMeta":["@:keep"]}}}'));
		final src: String = 'class C {\n\t@:keep var kept:Dynamic;\n\tvar plain:Dynamic;\n}';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals('plain', slicePlain(src, vs[0]));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('avoid-dynamic'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('avoid-dynamic'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testTypedefFieldFlagged(): Void {
		// A typedef / anonymous-structure field typed Dynamic is a field position too.
		final vs: Array<Violation> = violations('typedef T = {\n\tvar f:Dynamic;\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('field'));
	}

	private function slice(src: String, v: Violation): String {
		final span: Null<Span> = v.span;
		return span == null ? '' : src.substring(span.from, span.to);
	}

	private function slicePlain(src: String, v: Violation): String {
		// The name of the field two chars before the `:Dynamic` token — a crude locator for the exclusion test.
		final span: Null<Span> = v.span;
		if (span == null) return '';
		final colon: Int = src.lastIndexOf(':', span.from);
		final nameStart: Int = src.lastIndexOf(' ', colon);
		return src.substring(nameStart + 1, colon);
	}

	private function violations(src: String): Array<Violation> {
		return new AvoidDynamic().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
