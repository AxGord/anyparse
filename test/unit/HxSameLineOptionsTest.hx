package unit;

import utest.Assert;
import utest.Test;
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
 * `@:sameLine("flagName")` meta on the relevant grammar fields wires
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
		Assert.isTrue(defaults.sameLineElse);
		Assert.isTrue(defaults.sameLineCatch);
		Assert.isTrue(defaults.sameLineDoWhile);
	}

	private function writeWith(src:String, sameLineElse:Bool, sameLineCatch:Bool, sameLineDoWhile:Bool):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(sameLineElse, sameLineCatch, sameLineDoWhile));
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
			sameLineElse: sameLineElse,
			sameLineCatch: sameLineCatch,
			sameLineDoWhile: sameLineDoWhile,
			trailingCommaArrays: base.trailingCommaArrays,
			trailingCommaArgs: base.trailingCommaArgs,
			trailingCommaParams: base.trailingCommaParams,
			ifBody: base.ifBody,
			elseBody: base.elseBody,
			forBody: base.forBody,
			whileBody: base.whileBody,
			doBody: base.doBody,
			leftCurly: base.leftCurly,
		};
	}
}
