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
 * `tryBody` (the sibling knob for the `try`→body separator) lives in
 * `HxTryBodyOptionsTest` (slice ω-tryBody) — they co-exist via
 * `bodyPolicyWrap`'s `kwOwnsInlineSpace` mode so `tryPolicy=None`
 * + `tryBody=Same` still collapses to `try{…}`.
 */
@:nullSafety(Strict)
class HxCatchBodySliceTest extends Test {

	public function new(): Void {
		super();
	}

	public function testDefaultIsNext(): Void {
		final defaults: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(BodyPolicy.Next, defaults.catchBody);
	}

	public function testBlockBodyStaysInlineUnderNext(): Void {
		// Block bodies are shape-aware — `Next` does NOT push `{` to
		// the next line; the inline `} catch (e:Any) {` survives.
		final out: String = writeWith('class M { function f():Void { try { a; } catch (e:Any) { b; } } }', BodyPolicy.Next);
		Assert.isTrue(out.indexOf(') {') != -1, 'expected `) {` inline (block-body shape) in: <$out>');
	}

	public function testBlockBodyStaysInlineUnderSame(): Void {
		final out: String = writeWith('class M { function f():Void { try { a; } catch (e:Any) { b; } } }', BodyPolicy.Same);
		Assert.isTrue(out.indexOf(') {') != -1, 'expected `) {` inline under Same in: <$out>');
	}

	public function testBlockBodyStaysInlineUnderFitLine(): Void {
		final out: String = writeWith('class M { function f():Void { try { a; } catch (e:Any) { b; } } }', BodyPolicy.FitLine);
		Assert.isTrue(out.indexOf(') {') != -1, 'expected `) {` inline under FitLine in: <$out>');
	}

	public function testNonBlockBodyBreaksUnderNext(): Void {
		final out: String = writeWith('class M { function f():Void { try a(); catch (e:Any) trace(e); } }', BodyPolicy.Next);
		Assert.isTrue(out.indexOf(')\n') != -1, 'expected hardline after `)` (non-block body Next) in: <$out>');
	}

	public function testNonBlockBodyStaysInlineUnderSame(): Void {
		final out: String = writeWith('class M { function f():Void { try a(); catch (e:Any) trace(e); } }', BodyPolicy.Same);
		Assert.isTrue(out.indexOf(') trace(e)') != -1, 'expected `) trace(e)` flat (non-block body Same) in: <$out>');
	}

	public function testKeepDoesNotCrash(): Void {
		final out: String = writeWith('class M { function f():Void { try { a; } catch (e:Any) { b; } } }', BodyPolicy.Keep);
		Assert.isTrue(out.indexOf('catch (e:Any)') != -1, 'sanity: `catch (e:Any)` present in: <$out>');
	}

	public function testJsonNextMapsToNext(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"catchBody": "next"}}');
		Assert.equals(BodyPolicy.Next, opts.catchBody);
	}

	public function testJsonSameMapsToSame(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"catchBody": "same"}}');
		Assert.equals(BodyPolicy.Same, opts.catchBody);
	}

	public function testJsonFitLineMapsToFitLine(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"catchBody": "fitLine"}}');
		Assert.equals(BodyPolicy.FitLine, opts.catchBody);
	}

	public function testJsonKeepMapsToKeep(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"catchBody": "keep"}}');
		Assert.equals(BodyPolicy.Keep, opts.catchBody);
	}

	public function testEmptyJsonKeepsDefault(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(BodyPolicy.Next, opts.catchBody);
	}

	// Slice 3 — body-less `catch (e:Type)` (`@:optional @:absentOn('}')`
	// on `HxCatchClause.body`). Recon-confirmed sole blocker of the
	// `whitespace/issue_583_*` cluster (×6) once Slice 2 multi-var
	// landed. Parse-additive: the present-body path is unchanged.

	public function testBodylessCatchParses(): Void {
		// `catch (e:Any)` directly followed by the function close `}` —
		// must parse (body absent) instead of throwing.
		Assert.notNull(HaxeModuleParser.parse('class M { function f():Void { try { a; } catch (e:Any) } }'));
	}

	public function testBodylessCatchAtClassClose(): Void {
		// The exact `whitespace/issue_583_*` shape: bodyless catch then
		// the function close then the class close.
		final src: String = 'class Main {\n\tstatic function main() {\n\t\ttry {\n\t\t\tvar v = 1;\n\t\t} catch (e:Any)\n\t}\n}';
		Assert.notNull(HaxeModuleParser.parse(src));
	}

	public function testBodylessCatchWritesNoCrash(): Void {
		// The writer must not throw on an absent catch body; the catch
		// header itself survives.
		final out: String = writeWith('class M { function f():Void { try { a; } catch (e:Any) } }', BodyPolicy.Next);
		Assert.isTrue(out.indexOf('catch (e:Any)') != -1, 'expected `catch (e:Any)` header in: <$out>');
	}

	public function testCatchWithBodyStillParses(): Void {
		// Regression sentinel — the present-body path is byte-identical
		// to the pre-Slice-3 required-Ref path.
		final out: String = writeWith('class M { function f():Void { try { a; } catch (e:Any) { b; } } }', BodyPolicy.Next);
		Assert.isTrue(out.indexOf(') {') != -1, 'expected `) {` (block body) unaffected in: <$out>');
	}

	public function testCatchBodyAndTryPolicyIndependent(): Void {
		// Adding `catchBody` must NOT silence `tryPolicy` — the latter
		// gates the `try`→body gap, which is a different field site.
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"tryPolicy": "none"}}');
		opts.catchBody = BodyPolicy.Next;
		final src: String = 'class M { function f():Void { try { a; } catch (e:Any) { b; } } }';
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('try{') != -1, 'expected `try{` (tryPolicy=None) preserved under catchBody=Next in: <$out>');
	}

	private inline function writeWith(src: String, policy: BodyPolicy): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.catchBody = policy;
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}

}
