package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.ExtractSuperclass;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `CanonicalEdit.editKeepingCanonical` on a source that is NOT writer-canonical — the fallback the
 * span-splice ops (`extract-superclass`, `extract-interface`, `introduce-parameter-object`) take.
 *
 * The fallback used to answer `Ok(applyEdits(...))` straight off the canonical gate's `Err`, so
 * every refusal `canonicalize` asks of an EDIT was thrown away with it: `extract-superclass` on a
 * file one stray space away from canonical welded `// about a` onto `// about b`, where the
 * canonical twin was refused. Each refusal test below is RED at base: the fallback wrote the
 * splice. Every fixture asserts its own drift first, or it would be testing `canonicalize`.
 */
class EditKeepingCanonicalGateTest extends Test {

	/** One stray inner space is the drift: the writer prints `{}`. */
	private static final DRIFT: String = '\tfunction drift():Void {   }\n';

	/** `extract-superclass` cutting `a` leaves `// about a` welded to `// about b`. RED at base. */
	@:pin('control')
	@:killer('M-KEEP-CANON-FALLBACK-UNGUARDED')
	@:killer('M-GUARDED-SPLICE-NO-REFUSAL')
	public function testExtractSuperclassOnADriftedFileRefusesAWeld(): Void {
		final src: String =
			'class C {\n\t// about a\n\tpublic function a():Void {}\n\n\t// about b\n\tpublic function b():Void {}\n$DRIFT}\n';
		assertDrifted(src);
		switch ExtractSuperclass.extract('C.hx', 'C', 'Base', 'Base.hx', ['a'], src, new HaxeQueryPlugin()) {
			case Err(message):
				Assert.isTrue(message.contains('welded'), message);
			case Ok(changes, _):
				Assert.fail('the weld was written:\n${changes[0].newSource}');
		}
	}

	/** The canonical twin of the fixture above is refused the same way, so the two paths now agree. */
	public function testTheCanonicalTwinIsRefusedAlike(): Void {
		final src: String = 'class C {\n\t// about a\n\tpublic function a():Void {}\n\n\t// about b\n\tpublic function b():Void {}\n}\n';
		Assert.equals(src, new HaxeQueryPlugin().writeRoundTrip(src, null), 'the twin must be canonical');
		switch ExtractSuperclass.extract('C.hx', 'C', 'Base', 'Base.hx', ['a'], src, new HaxeQueryPlugin()) {
			case Err(message):
				Assert.isTrue(message.contains('welded'), message);
			case Ok(changes, _):
				Assert.fail('the weld was written:\n${changes[0].newSource}');
		}
	}

	/** A raw splice that strands an `else` is refused on a drifted file too. RED at base. */
	@:pin('control')
	@:killer('M-KEEP-CANON-FALLBACK-UNGUARDED')
	@:killer('M-GUARDED-SPLICE-NO-REFUSAL')
	public function testTheFallbackRefusesAStrandedElse(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t}\n$DRIFT}\n';
		final err: Null<String> = refusal(src, 'a();', 'a();\n\t\telse b();');
		Assert.isTrue(err != null && err.contains('`else`'), '$err');
	}

	/** Deleting a brace-less body is refused on a drifted file too: `if (c)` would take `b();`. RED at base. */
	@:pin('control')
	@:killer('M-KEEP-CANON-FALLBACK-UNGUARDED')
	public function testTheFallbackRefusesAnEmptiedSlot(): Void {
		final src: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) a();\n\t\tb();\n\t}\n$DRIFT}\n';
		Assert.notNull(refusal(src, 'a();', ''));
	}

	/** An inserted line between a doc and its member is refused on a drifted file too. RED at base. */
	@:pin('control')
	@:killer('M-KEEP-CANON-FALLBACK-UNGUARDED')
	public function testTheFallbackRefusesASplitDoc(): Void {
		final src: String = 'class C {\n\t/** Documents f. */\n\tfunction f():Void {}\n$DRIFT}\n';
		final at: Int = src.indexOf('\tfunction f');
		final result: EditResult = CanonicalEdit.editKeepingCanonical(
			src,
			[{ span: new Span(at, at), text: '\tvar x:Int;\n' }],
			new HaxeQueryPlugin()
		);
		Assert.isTrue(result.match(Err(_)), '$result');
	}

	/** Control: a harmless edit on a drifted file is still the plain splice, the drift untouched. */
	@:pin('control')
	@:killer('M-GUARDED-SPLICE-ALWAYS-REFUSES')
	public function testTheFallbackStillSplicesAHarmlessEdit(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t}\n$DRIFT}\n';
		final at: Int = src.indexOf('a();');
		switch CanonicalEdit.editKeepingCanonical(src, [{ span: new Span(at, at + 1), text: 'z' }], new HaxeQueryPlugin()) {
			case Ok(text, _):
				Assert.equals(src.replace('a();', 'z();'), text);
			case Err(message):
				Assert.fail(message);
		}
	}

	/** The refusal for replacing the unique `oldText` in drifted `src` with `newText`, or null when it was written. */
	private static function refusal(src: String, oldText: String, newText: String): Null<String> {
		assertDrifted(src);
		final at: Int = src.indexOf(oldText);
		return switch CanonicalEdit.editKeepingCanonical(
			src, [{ span: new Span(at, at + oldText.length), text: newText }], new HaxeQueryPlugin()
		) {
			case Err(message): message;
			case Ok(_, _): null;
		};
	}

	private static function assertDrifted(src: String): Void {
		Assert.notEquals(
			src, new HaxeQueryPlugin().writeRoundTrip(src, null), 'the fixture must be drifted, or the fallback is not reached'
		);
	}

}
