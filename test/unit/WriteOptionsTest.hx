package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;
import anyparse.format.text.JsonFormat;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueWriteOptions;
import anyparse.grammar.json.JValueWriter;

/**
 * σ infrastructure regression: confirm the generated `write()` entry
 * points accept `?options`, resolve to the format's defaults when
 * omitted, and produce identical output for an explicit copy of those
 * defaults. Real option branches land in τ₁/τ₂ and get their own tests.
 */
@:nullSafety(Strict)
class WriteOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testJsonWriterAcceptsOptions():Void {
		final ast:JValue = JValueParser.parse('{"x":1}');
		final opts:JValueWriteOptions = {
			indentChar: Space,
			indentSize: 4,
			tabWidth: 4,
			lineWidth: 120,
			lineEnd: '\n',
			finalNewline: false,
			trailingWhitespace: false,
		};
		final out:String = JValueWriter.write(ast, opts);
		Assert.equals(JValueWriter.write(ast), out);
	}

	public function testJsonFormatExposesDefaults():Void {
		final defaults:WriteOptions = JsonFormat.instance.defaultWriteOptions;
		Assert.equals(Space, defaults.indentChar);
		Assert.equals(4, defaults.indentSize);
		Assert.equals(120, defaults.lineWidth);
	}

	public function testHaxeWriterAcceptsOptions():Void {
		final ast:HxModule = HaxeModuleParser.parse('class Foo {}');
		final opts:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		final out:String = HxModuleWriter.write(ast, opts);
		Assert.equals(HxModuleWriter.write(ast), out);
	}

	public function testHaxeFormatExposesDefaults():Void {
		final defaults:WriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(Tab, defaults.indentChar);
		Assert.equals(1, defaults.indentSize);
		Assert.equals(4, defaults.tabWidth);
		Assert.isTrue(defaults.finalNewline);
	}
}
