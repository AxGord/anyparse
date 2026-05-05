package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-tryBody — runtime-switchable body-placement axis for the
 * `try`→body separator at `HxTryCatchStmt.body`. Co-exists with the
 * sibling `tryPolicy:WhitespacePolicy` knob via `bodyPolicyWrap`'s
 * `kwOwnsInlineSpace` mode: the body field carries
 * `@:fmt(bodyPolicy('tryBody'), kwPolicy('tryPolicy'))` so the
 * `Same` inline gap routes through `opt.tryPolicy` (After/Both →
 * space, None/Before → empty) rather than a fixed `_dt(' ')`.
 *
 * The architectural goal is orthogonality between the two axes:
 *  - `tryBody` controls "is the body on the same line at all?"
 *    (`Same` / `Next` / `FitLine` / `Keep`).
 *  - `tryPolicy` controls "is there a space right after the `try`
 *    keyword?" (`None` / `Before` / `After` / `Both`).
 * Block bodies (`{ … }`) defer to `lineEnds.leftCurly` for the brace
 * position regardless of `tryBody` (mirrors `ifBody`/`forBody`/etc.).
 */
@:nullSafety(Strict)
class HxTryBodyOptionsTest extends Test {

	private static inline final SRC_BLOCK_BODY:String = 'class C { static function m() { try { a; } catch (e:Any) {} } }';

	public function new():Void {
		super();
	}

	public function testDefaultIsNext():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(BodyPolicy.Next, defaults.tryBody);
	}

	public function testTryPolicyAfterTryBodySameKeepsSpace():Void {
		// Default tryPolicy=After + tryBody=Same + leftCurly=Same → `try {`.
		final out:String = writeWith(SRC_BLOCK_BODY, BodyPolicy.Same, WhitespacePolicy.After);
		Assert.isTrue(out.indexOf('try {') != -1, 'expected `try {` (After+Same) in: <$out>');
	}

	public function testTryPolicyNoneTryBodySameCollapsesGap():Void {
		// Architectural invariant: tryPolicy=None must collapse `try{…}`
		// even with tryBody=Same in play (kwOwnsInlineSpace routes the
		// Same inline gap through opt.tryPolicy).
		final out:String = writeWith(SRC_BLOCK_BODY, BodyPolicy.Same, WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('try{') != -1, 'expected `try{` (None+Same) in: <$out>');
		Assert.isTrue(out.indexOf('try {') == -1, 'did not expect `try {` (None+Same) in: <$out>');
	}

	public function testTryPolicyBeforeTryBodySameCollapsesGap():Void {
		final out:String = writeWith(SRC_BLOCK_BODY, BodyPolicy.Same, WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('try{') != -1, 'expected `try{` (Before+Same) in: <$out>');
	}

	public function testTryPolicyBothTryBodySameKeepsSpace():Void {
		final out:String = writeWith(SRC_BLOCK_BODY, BodyPolicy.Same, WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('try {') != -1, 'expected `try {` (Both+Same) in: <$out>');
	}

	public function testLeftCurlyNextOverridesTryBodySame():Void {
		// Block-body shape-aware: `leftCurly=Next` wins for the brace
		// position regardless of `tryBody` (mirrors ifBody/forBody/etc.).
		final opts:HxModuleWriteOptions = makeOpts(BodyPolicy.Same, WhitespacePolicy.After);
		opts.leftCurly = BracePlacement.Next;
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(SRC_BLOCK_BODY), opts);
		Assert.isTrue(out.indexOf('try\n') != -1, 'expected `try\\n` (leftCurly=Next overrides) in: <$out>');
		Assert.isTrue(out.indexOf('try {') == -1, 'did not expect `try {` under leftCurly=Next in: <$out>');
	}

	public function testLeftCurlyNextStripsKwTrailSpace():Void {
		// Even with tryPolicy=After, leftCurly=Next must NOT produce
		// `try \n{` — the kw-trail-space slot is owned by bodyPolicyWrap
		// and the leftCurly=Next branch emits a hardline directly.
		final opts:HxModuleWriteOptions = makeOpts(BodyPolicy.Same, WhitespacePolicy.After);
		opts.leftCurly = BracePlacement.Next;
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(SRC_BLOCK_BODY), opts);
		Assert.isTrue(out.indexOf('try \n') == -1, 'did not expect `try \\n` (dangling space) in: <$out>');
	}

	public function testTryBodyKeepUnderAfterStaysOpen():Void {
		// tryBody=Keep + tryPolicy=After + leftCurly=Same default →
		// `try {`. Keep degrades to Same in `bodyPolicyWrap` (no
		// trivia-mode `bodyOnSameLine` slot threaded here), so the
		// kwOwnsInlineSpace switch picks the After/Both branch.
		final out:String = writeWith(SRC_BLOCK_BODY, BodyPolicy.Keep, WhitespacePolicy.After);
		Assert.isTrue(out.indexOf('try {') != -1, 'expected `try {` (Keep+After) in: <$out>');
	}

	public function testTryBodyNextOnBlockBodyDefersToLeftCurly():Void {
		// tryBody=Next on a tagged block body still routes through
		// blockLayoutExpr (leftCurly wins). leftCurly=Same default →
		// `try {…}` regardless of tryBody=Next.
		final out:String = writeWith(SRC_BLOCK_BODY, BodyPolicy.Next, WhitespacePolicy.After);
		Assert.isTrue(out.indexOf('try {') != -1, 'expected `try {` (block-body shape wins over tryBody=Next) in: <$out>');
		Assert.isTrue(out.indexOf('try\n') == -1, 'tryBody=Next must NOT push block body to next line under leftCurly=Same in: <$out>');
	}

	public function testJsonSameMapsToSame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"tryBody": "same"}}');
		Assert.equals(BodyPolicy.Same, opts.tryBody);
	}

	public function testJsonNextMapsToNext():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"tryBody": "next"}}');
		Assert.equals(BodyPolicy.Next, opts.tryBody);
	}

	public function testJsonFitLineMapsToFitLine():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"tryBody": "fitLine"}}');
		Assert.equals(BodyPolicy.FitLine, opts.tryBody);
	}

	public function testJsonKeepMapsToKeep():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"tryBody": "keep"}}');
		Assert.equals(BodyPolicy.Keep, opts.tryBody);
	}

	public function testEmptyJsonKeepsDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(BodyPolicy.Next, opts.tryBody);
	}

	public function testTryBodyAndCatchBodyIndependent():Void {
		// Adding tryBody must NOT silence catchBody — the two flags
		// drive different field sites (HxTryCatchStmt.body vs
		// HxCatchClause.body). Verify both axes hold simultaneously:
		// the catch body breaks (catchBody=Next) AND the try body
		// stays inline (tryBody=Same — no `try\n` push).
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.tryBody = BodyPolicy.Same;
		opts.catchBody = BodyPolicy.Next;
		final src:String = 'class M { function f():Void { try a(); catch (e:Any) trace(e); } }';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf(')\n') != -1, 'expected catch-body break preserved under tryBody=Same in: <$out>');
		Assert.isTrue(out.indexOf('try\n') == -1, 'tryBody=Same must keep the try body inline (no `try\\n`) in: <$out>');
	}

	private inline function writeWith(src:String, tryBody:BodyPolicy, tryPolicy:WhitespacePolicy):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(tryBody, tryPolicy));
	}

	private inline function makeOpts(tryBody:BodyPolicy, tryPolicy:WhitespacePolicy):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.tryBody = tryBody;
		opts.tryPolicy = tryPolicy;
		return opts;
	}
}
