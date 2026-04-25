package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.SameLinePolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * τ₁ — runtime-switchable `sameLine` policies for `else`, `catch`, and
 * the trailing `while` of `do … while (…)`.
 *
 * Three independent `Bool` knobs on `HxModuleWriteOptions` control
 * whether the follow-up keyword sits on the same line as the preceding
 * `}` (default — matches haxe-formatter's `sameLine` defaults) or is
 * moved to the next line at the current indent level. The declarative
 * `@:fmt(sameLine("flagName"))` knob on the relevant grammar fields wires
 * each knob to one specific emission site in `WriterLowering`.
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
		final base:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		final opts:HxModuleWriteOptions = {
			indentChar: base.indentChar,
			indentSize: base.indentSize,
			tabWidth: base.tabWidth,
			lineWidth: base.lineWidth,
			lineEnd: base.lineEnd,
			finalNewline: base.finalNewline,
			trailingWhitespace: base.trailingWhitespace,
			commentStyle: base.commentStyle,
			sameLineElse: boolToSameLine(sameLineElse),
			sameLineCatch: base.sameLineCatch,
			sameLineDoWhile: base.sameLineDoWhile,
			trailingCommaArrays: base.trailingCommaArrays,
			trailingCommaArgs: base.trailingCommaArgs,
			trailingCommaParams: base.trailingCommaParams,
			ifBody: ifBody,
			elseBody: elseBody,
			forBody: base.forBody,
			whileBody: base.whileBody,
			doBody: base.doBody,
			leftCurly: base.leftCurly,
			objectFieldColon: base.objectFieldColon,
			typeHintColon: base.typeHintColon,
			funcParamParens: base.funcParamParens,
			callParens: base.callParens,
			elseIf: base.elseIf,
			fitLineIfWithElse: base.fitLineIfWithElse,
			afterFieldsWithDocComments: base.afterFieldsWithDocComments,
			existingBetweenFields: base.existingBetweenFields,
			beforeDocCommentEmptyLines: base.beforeDocCommentEmptyLines,
			betweenVars: base.betweenVars,
			betweenFunctions: base.betweenFunctions,
			afterVars: base.afterVars,
			interfaceBetweenVars: base.interfaceBetweenVars,
			interfaceBetweenFunctions: base.interfaceBetweenFunctions,
			interfaceAfterVars: base.interfaceAfterVars,
			typedefAssign: base.typedefAssign,
		};
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}

	private function writeWith(src:String, sameLineElse:Bool, sameLineCatch:Bool, sameLineDoWhile:Bool):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(sameLineElse, sameLineCatch, sameLineDoWhile));
	}

	private static inline function boolToSameLine(v:Bool):SameLinePolicy {
		return v ? SameLinePolicy.Same : SameLinePolicy.Next;
	}

	private function makeOpts(sameLineElse:Bool, sameLineCatch:Bool, sameLineDoWhile:Bool):HxModuleWriteOptions {
		final base:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		return {
			indentChar: base.indentChar,
			indentSize: base.indentSize,
			tabWidth: base.tabWidth,
			lineWidth: base.lineWidth,
			lineEnd: base.lineEnd,
			finalNewline: base.finalNewline,
			trailingWhitespace: base.trailingWhitespace,
			commentStyle: base.commentStyle,
			sameLineElse: boolToSameLine(sameLineElse),
			sameLineCatch: boolToSameLine(sameLineCatch),
			sameLineDoWhile: boolToSameLine(sameLineDoWhile),
			trailingCommaArrays: base.trailingCommaArrays,
			trailingCommaArgs: base.trailingCommaArgs,
			trailingCommaParams: base.trailingCommaParams,
			ifBody: base.ifBody,
			elseBody: base.elseBody,
			forBody: base.forBody,
			whileBody: base.whileBody,
			doBody: base.doBody,
			leftCurly: base.leftCurly,
			objectFieldColon: base.objectFieldColon,
			typeHintColon: base.typeHintColon,
			funcParamParens: base.funcParamParens,
			callParens: base.callParens,
			elseIf: base.elseIf,
			fitLineIfWithElse: base.fitLineIfWithElse,
			afterFieldsWithDocComments: base.afterFieldsWithDocComments,
			existingBetweenFields: base.existingBetweenFields,
			beforeDocCommentEmptyLines: base.beforeDocCommentEmptyLines,
			betweenVars: base.betweenVars,
			betweenFunctions: base.betweenFunctions,
			afterVars: base.afterVars,
			interfaceBetweenVars: base.interfaceBetweenVars,
			interfaceBetweenFunctions: base.interfaceBetweenFunctions,
			interfaceAfterVars: base.interfaceAfterVars,
			typedefAssign: base.typedefAssign,
		};
	}
}
