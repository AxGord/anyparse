package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-catch-body — `opt.catchBody:BodyPolicy` driving the separator
 * between the `)` of a catch clause's `(name:Type)` header and its
 * body at `HxCatchClause.body`. Mirrors `ifBody` / `forBody` /
 * `whileBody` / `doBody` — same `bodyPolicyWrap` macro path, same
 * 4-value `BodyPolicy` enum. Default is `Next` matching haxe-
 * formatter's `sameLine.catchBody: @:default(Next)`.
 *
 * Block bodies stay inline regardless of the policy via
 * `bodyPolicyWrap`'s block-ctor detection — the typical
 * `} catch (e:T) { … }` does not change shape. Only non-block
 * catch bodies (`} catch (e:T) trace(e);`) see the hardline under
 * `Next` / `FitLine`.
 *
 * `tryBody` (the sibling knob for the `try`→body separator) is
 * deliberately absent: adding a first-field `bodyPolicy` on
 * `HxTryCatchStmt.body` would silence the existing `tryPolicy`
 * knob's `try{` / `try {` collapse semantics via
 * `subStructStartsWithBodyPolicy`'s strip. A separate slice will
 * resolve the conflict.
 */
@:nullSafety(Strict)
class HxCatchBodySliceTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultIsNext():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(BodyPolicy.Next, defaults.catchBody);
	}

	public function testBlockBodyStaysInlineUnderNext():Void {
		// Block bodies are shape-aware — `Next` does NOT push `{` to
		// the next line; the inline `} catch (e:Any) {` survives.
		final out:String = writeWith('class M { function f():Void { try { a; } catch (e:Any) { b; } } }', BodyPolicy.Next);
		Assert.isTrue(out.indexOf(') {') != -1, 'expected `) {` inline (block-body shape) in: <$out>');
	}

	public function testBlockBodyStaysInlineUnderSame():Void {
		final out:String = writeWith('class M { function f():Void { try { a; } catch (e:Any) { b; } } }', BodyPolicy.Same);
		Assert.isTrue(out.indexOf(') {') != -1, 'expected `) {` inline under Same in: <$out>');
	}

	public function testBlockBodyStaysInlineUnderFitLine():Void {
		final out:String = writeWith('class M { function f():Void { try { a; } catch (e:Any) { b; } } }', BodyPolicy.FitLine);
		Assert.isTrue(out.indexOf(') {') != -1, 'expected `) {` inline under FitLine in: <$out>');
	}

	public function testNonBlockBodyBreaksUnderNext():Void {
		final out:String = writeWith('class M { function f():Void { try a(); catch (e:Any) trace(e); } }', BodyPolicy.Next);
		Assert.isTrue(out.indexOf(')\n') != -1, 'expected hardline after `)` (non-block body Next) in: <$out>');
	}

	public function testNonBlockBodyStaysInlineUnderSame():Void {
		final out:String = writeWith('class M { function f():Void { try a(); catch (e:Any) trace(e); } }', BodyPolicy.Same);
		Assert.isTrue(out.indexOf(') trace(e)') != -1, 'expected `) trace(e)` flat (non-block body Same) in: <$out>');
	}

	public function testKeepDoesNotCrash():Void {
		final out:String = writeWith('class M { function f():Void { try { a; } catch (e:Any) { b; } } }', BodyPolicy.Keep);
		Assert.isTrue(out.indexOf('catch (e:Any)') != -1, 'sanity: `catch (e:Any)` present in: <$out>');
	}

	public function testJsonNextMapsToNext():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"catchBody": "next"}}'
		);
		Assert.equals(BodyPolicy.Next, opts.catchBody);
	}

	public function testJsonSameMapsToSame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"catchBody": "same"}}'
		);
		Assert.equals(BodyPolicy.Same, opts.catchBody);
	}

	public function testJsonFitLineMapsToFitLine():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"catchBody": "fitLine"}}'
		);
		Assert.equals(BodyPolicy.FitLine, opts.catchBody);
	}

	public function testJsonKeepMapsToKeep():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"catchBody": "keep"}}'
		);
		Assert.equals(BodyPolicy.Keep, opts.catchBody);
	}

	public function testEmptyJsonKeepsDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(BodyPolicy.Next, opts.catchBody);
	}

	public function testCatchBodyAndTryPolicyIndependent():Void {
		// Adding `catchBody` must NOT silence `tryPolicy` — the latter
		// gates the `try`→body gap, which is a different field site.
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"tryPolicy": "none"}}');
		opts.catchBody = BodyPolicy.Next;
		final src:String = 'class M { function f():Void { try { a; } catch (e:Any) { b; } } }';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('try{') != -1, 'expected `try{` (tryPolicy=None) preserved under catchBody=Next in: <$out>');
	}

	private inline function writeWith(src:String, policy:BodyPolicy):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.catchBody = policy;
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}
}
