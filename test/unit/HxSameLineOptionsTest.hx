package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.SameLinePolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * τ₁ + ω-expression-try — runtime-switchable `sameLine` policies for
 * `else`, `catch`, the trailing `while` of `do … while (…)`, and the
 * expression-position `try ... catch` separator.
 *
 * Four independent `SameLinePolicy` knobs on `HxModuleWriteOptions`
 * control whether the follow-up keyword sits on the same line as the
 * preceding `}` (or body, for the expression-form try) — default
 * matches haxe-formatter's `sameLine` defaults — or is moved to the
 * next line at the current indent level. The declarative
 * `@:fmt(sameLine("flagName"))` knob on the relevant grammar fields
 * wires each knob to one specific emission site in `WriterLowering`.
 *
 * Each test round-trips a source through the parser, writes it with
 * each flag forced, and asserts the separator appears in the expected
 * shape — tolerant to surrounding formatting so the assertions stay
 * robust against unrelated layout tweaks.
 */
@:nullSafety(Strict)
class HxSameLineOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testSameLineElseTrue():Void {
		final out:String = writeWith(
			'class F { function f():Void { if (x) {} else {} } }',
			true, true, true
		);
		Assert.isTrue(out.indexOf('} else ') != -1, 'expected `} else ` in: <$out>');
		Assert.isTrue(out.indexOf('}\nelse') == -1 && out.indexOf('}\n\telse') == -1, 'did not expect next-line `else` in: <$out>');
	}

	public function testSameLineElseFalse():Void {
		final out:String = writeWith(
			'class F { function f():Void { if (x) {} else {} } }',
			false, true, true
		);
		Assert.isTrue(out.indexOf('} else ') == -1, 'did not expect `} else ` in: <$out>');
		Assert.isTrue(out.indexOf('else') != -1, 'expected `else` keyword in: <$out>');
	}

	public function testSameLineCatchTrue():Void {
		final out:String = writeWith(
			'class F { function f():Void { try {} catch (e:E) {} } }',
			true, true, true
		);
		Assert.isTrue(out.indexOf('} catch ') != -1, 'expected `} catch ` in: <$out>');
	}

	public function testSameLineCatchFalse():Void {
		final out:String = writeWith(
			'class F { function f():Void { try {} catch (e:E) {} } }',
			true, false, true
		);
		Assert.isTrue(out.indexOf('} catch ') == -1, 'did not expect `} catch ` in: <$out>');
		Assert.isTrue(out.indexOf('catch ') != -1, 'expected `catch ` keyword in: <$out>');
	}

	public function testSameLineCatchAppliesToEveryCatch():Void {
		final out:String = writeWith(
			'class F { function f():Void { try {} catch (a:E) {} catch (b:E) {} } }',
			true, false, true
		);
		// Both catches must break — neither sits on the same line as the preceding `}`.
		Assert.isTrue(out.indexOf('} catch ') == -1, 'no `} catch ` expected in: <$out>');
		final firstAt:Int = out.indexOf('catch (a');
		final secondAt:Int = out.indexOf('catch (b');
		Assert.isTrue(firstAt >= 0 && secondAt > firstAt, 'both catches expected in: <$out>');
	}

	public function testSameLineDoWhileTrue():Void {
		final out:String = writeWith(
			'class F { function f():Void { do {} while (x); } }',
			true, true, true
		);
		Assert.isTrue(out.indexOf('} while ') != -1, 'expected `} while ` in: <$out>');
	}

	public function testSameLineDoWhileFalse():Void {
		final out:String = writeWith(
			'class F { function f():Void { do {} while (x); } }',
			true, true, false
		);
		Assert.isTrue(out.indexOf('} while ') == -1, 'did not expect `} while ` in: <$out>');
		Assert.isTrue(out.indexOf('while (x)') != -1, 'expected `while (x)` in: <$out>');
	}

	public function testAllFlagsFalseStillRoundTrips():Void {
		final src:String = 'class F { function f():Void { if (x) {} else {} try {} catch (e:E) {} do {} while (x); } }';
		final opts:HxModuleWriteOptions = makeOpts(false, false, false);
		final ast1:HxModule = HaxeModuleParser.parse(src);
		final out1:String = HxModuleWriter.write(ast1, opts);
		final out2:String = HxModuleWriter.write(HaxeModuleParser.parse(out1), opts);
		Assert.equals(out1, out2);
	}

	public function testFlagsAreIndependent():Void {
		// Flip only sameLineCatch → else and while still same-line.
		final out:String = writeWith(
			'class F { function f():Void { if (x) {} else {} try {} catch (e:E) {} do {} while (x); } }',
			true, false, true
		);
		Assert.isTrue(out.indexOf('} else ') != -1, 'else should stay same-line in: <$out>');
		Assert.isTrue(out.indexOf('} while ') != -1, 'while should stay same-line in: <$out>');
		Assert.isTrue(out.indexOf('} catch ') == -1, 'catch should break in: <$out>');
	}

	public function testDefaultsMatchHaxeFormatter():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(SameLinePolicy.Same, defaults.sameLineElse);
		Assert.equals(SameLinePolicy.Same, defaults.sameLineCatch);
		Assert.equals(SameLinePolicy.Same, defaults.sameLineDoWhile);
		Assert.equals(SameLinePolicy.Same, defaults.expressionTry);
	}

	public function testExpressionTrySameKeepsOneLiner():Void {
		// expressionTry=Same → `try foo() catch (_:Any) null` stays inline.
		final out:String = writeWithExpressionTry(
			'class F { function f():Void { var x = try foo() catch (_:Any) null; } }',
			SameLinePolicy.Same
		);
		Assert.isTrue(out.indexOf('try foo() catch (_:Any) null;') != -1, 'expected one-liner expression try in: <$out>');
	}

	public function testExpressionTryNextSplits():Void {
		// expressionTry=Next → body and each catch break onto own lines.
		final out:String = writeWithExpressionTry(
			'class F { function f():Void { var x = try foo() catch (_:Any) null; } }',
			SameLinePolicy.Next
		);
		Assert.isTrue(out.indexOf('try foo() catch (_:Any) null;') == -1, 'did not expect inline expression try in: <$out>');
		Assert.isTrue(out.indexOf('catch (_:Any)') != -1, 'expected catch clause in: <$out>');
		// catch keyword must sit on its own line, not on the same line as the body's last token.
		Assert.isTrue(out.indexOf('foo() catch') == -1, 'catch should break onto own line in: <$out>');
	}

	public function testExpressionTryNextBreaksTryBody():Void {
		// ω-expression-try-body-break: expressionTry=Next must also break
		// the body away from the `try` keyword — `try\n\t...\n\t\tfoo()`,
		// not `try foo()`.
		final out:String = writeWithExpressionTry(
			'class F { function f():Void { var x = try foo() catch (_:Any) null; } }',
			SameLinePolicy.Next
		);
		Assert.isTrue(out.indexOf('try foo()') == -1, 'try body should break onto own line in: <$out>');
		Assert.isTrue(out.indexOf('try\n') != -1, 'expected hardline immediately after try keyword in: <$out>');
	}

	public function testExpressionTryNextBreaksCatchBody():Void {
		// ω-expression-try-body-break: expressionTry=Next must also break
		// the catch body away from the catch parens — `catch (_:Any)\n\t...\n\t\tnull`,
		// not `catch (_:Any) null`.
		final out:String = writeWithExpressionTry(
			'class F { function f():Void { var x = try foo() catch (_:Any) null; } }',
			SameLinePolicy.Next
		);
		Assert.isTrue(out.indexOf('catch (_:Any) null') == -1, 'catch body should break onto own line in: <$out>');
		Assert.isTrue(out.indexOf('catch (_:Any)\n') != -1, 'expected hardline immediately after catch close paren in: <$out>');
	}

	public function testExpressionTrySameKeepsTryBodyInline():Void {
		// expressionTry=Same → body and catch body stay inline with their
		// preceding tokens. Asserts the bodyBreak `Same` branch keeps the
		// pre-slice spacing byte-identical.
		final out:String = writeWithExpressionTry(
			'class F { function f():Void { var x = try foo() catch (_:Any) null; } }',
			SameLinePolicy.Same
		);
		Assert.isTrue(out.indexOf('try foo()') != -1, 'expected inline `try foo()` in: <$out>');
		Assert.isTrue(out.indexOf('catch (_:Any) null') != -1, 'expected inline `catch (_:Any) null` in: <$out>');
	}

	public function testExpressionTryIndependentFromSameLineCatch():Void {
		// sameLineCatch=Next must not affect expression-form when expressionTry=Same.
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.sameLineCatch = SameLinePolicy.Next;
		opts.expressionTry = SameLinePolicy.Same;
		final src:String = 'class F { function f():Void { var x = try foo() catch (_:Any) null; try {} catch (e:E) {} } }';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('try foo() catch (_:Any) null;') != -1, 'expression form should stay inline in: <$out>');
		Assert.isTrue(out.indexOf('} catch ') == -1, 'statement form catch should break in: <$out>');
	}

	public function testExpressionTryJsonNext():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"expressionTry": "next"}}');
		Assert.equals(SameLinePolicy.Next, opts.expressionTry);
		Assert.equals(SameLinePolicy.Same, opts.sameLineCatch);
	}

	public function testExpressionTryNextKeepsBlockBodyInline():Void {
		// ω-block-shape-aware: with expressionTry=Next, a block try body
		// and block catch body still emit inline `try { … } catch (…) { … }`
		// instead of breaking around the braces. Block bodies have their
		// own visual structure — a hardline before `{` would split a
		// brace pair.
		final out:String = writeWithExpressionTry(
			'class F { function f():Void { var x = try { foo(); } catch (_:Any) { null; }; } }',
			SameLinePolicy.Next
		);
		Assert.isTrue(out.indexOf('try {') != -1, 'expected inline `try {` (block body) in: <$out>');
		Assert.isTrue(out.indexOf('} catch (_:Any) {') != -1, 'expected inline `} catch (_:Any) {` in: <$out>');
		Assert.isTrue(out.indexOf('try\n') == -1, 'block-body try must not break onto own line in: <$out>');
	}

	public function testExpressionTryNextMixedBodiesShapeAware():Void {
		// ω-block-shape-aware: bare body breaks (existing behaviour),
		// block body stays inline (new behaviour) — same `expressionTry=Next`,
		// runtime ctor switch picks the layout per try-catch instance.
		final src:String = 'class F { function f():Void { '
			+ 'var a = try foo() catch (_:Any) null; '
			+ 'var b = try { foo(); } catch (_:Any) { null; }; } }';
		final out:String = writeWithExpressionTry(src, SameLinePolicy.Next);
		Assert.isTrue(out.indexOf('try foo()') == -1, 'bare body should still break in: <$out>');
		Assert.isTrue(out.indexOf('try {') != -1, 'block body should stay inline in: <$out>');
		Assert.isTrue(out.indexOf('} catch (_:Any) {') != -1, 'block-body `} catch ... {` should stay inline in: <$out>');
	}

	public function testExpressionTryNextStatementFormUnaffectedByBlockShape():Void {
		// Statement-form `HxTryCatchStmt` does NOT carry
		// `@:fmt(blockBodyKeepsInline)` — `sameLineCatch=Next` must keep
		// breaking `} catch` to `}\ncatch` regardless of body shape, mirroring
		// haxe-formatter's `sameLine.tryCatch=next` contract.
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.sameLineCatch = SameLinePolicy.Next;
		final src:String = 'class F { function f():Void { try {} catch (e:E) {} } }';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('} catch ') == -1, 'statement-form `} catch` must break in: <$out>');
	}

	private function writeWithExpressionTry(src:String, policy:SameLinePolicy):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.expressionTry = policy;
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}

	public function testSameLineElseTrueSuppressedByNonBlockThenBody():Void {
		// ψ₉: when thenBody is a non-block statement (ExprStmt here),
		// sameLineElse=true is suppressed because a lone `else` on the
		// same line as a semicolon-terminated body has no meaning.
		// ifBody=Same keeps thenBody on the same line as `if (...)`, so
		// the separator after `;` is the one ψ₉ shape-awareness fires on.
		final out:String = writeWithBodyPolicy(
			'class F { function f():Void { if (x) doA(); else doB(); } }',
			anyparse.format.BodyPolicy.Same, anyparse.format.BodyPolicy.Same, true
		);
		Assert.isTrue(out.indexOf('doA(); else') == -1, 'did not expect `doA(); else` inline in: <$out>');
		Assert.isTrue(out.indexOf('doA();\n\t\telse') != -1, 'expected hardline before else (non-block then) in: <$out>');
	}

	public function testSameLineElseTrueHonoredByBlockThenBody():Void {
		// ψ₉: when thenBody is a block, sameLineElse=true continues to
		// emit `} else ` inline. This asserts the flag is still live
		// for block-terminated branches.
		final out:String = writeWith(
			'class F { function f():Void { if (x) {} else {} } }',
			true, true, true
		);
		Assert.isTrue(out.indexOf('} else ') != -1, 'expected `} else ` inline (block then) in: <$out>');
	}

	private function writeWithBodyPolicy(
		src:String, ifBody:anyparse.format.BodyPolicy, elseBody:anyparse.format.BodyPolicy, sameLineElse:Bool
	):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.sameLineElse = boolToSameLine(sameLineElse);
		opts.ifBody = ifBody;
		opts.elseBody = elseBody;
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}

	private function writeWith(src:String, sameLineElse:Bool, sameLineCatch:Bool, sameLineDoWhile:Bool):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(sameLineElse, sameLineCatch, sameLineDoWhile));
	}

	private static inline function boolToSameLine(v:Bool):SameLinePolicy {
		return v ? SameLinePolicy.Same : SameLinePolicy.Next;
	}

	private function makeOpts(sameLineElse:Bool, sameLineCatch:Bool, sameLineDoWhile:Bool):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.sameLineElse = boolToSameLine(sameLineElse);
		opts.sameLineCatch = boolToSameLine(sameLineCatch);
		opts.sameLineDoWhile = boolToSameLine(sameLineDoWhile);
		return opts;
	}
}
