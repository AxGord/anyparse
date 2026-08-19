package unit;

import utest.Assert;
import utest.Test;

/**
 * ω-N-break-after-eq, overflow arm: a `var` / `final` declaration whose RHS's
 * NATURAL first line (its own wrap decisions active) still overflows
 * `maxLineLength` breaks after the `=` (LF + one indent step) REGARDLESS of the
 * LHS declared type — an unbreakable atom RHS (a long interpolated string) is
 * the motivating shape. A wrappable RHS (a call that folds its own args) keeps
 * a short natural first line and stays glued to the `=`; a line exactly ON the
 * limit stays glued (strict `>`). The LHS-type-param shape keeps its existing
 * break via the same probe.
 */
@:nullSafety(Strict)
final class HxVarInitBreakAfterEqOverflowTest extends Test {

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {'
		+ '"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	public function testStringAtomPastLimitBreaksAfterEq(): Void {
		// Glued decl line = 141 columns at tab=4; the string atom cannot wrap
		// internally, so the only fit is the `=` break (broken line = 117).
		final glued: String = 'class C {\n\tfunction f() {\n\t\tfinal newSharePath:String = \'$${Prefix.SHARED_ROOT_WITH_SLASH + '
			+ 'ownerAccountName}/$$oldSharedFirstPart$$newSharedLastPart$$pathLastPart\';\n\t}\n}';
		final broken: String = 'class C {\n\tfunction f() {\n\t\tfinal newSharePath:String =\n'
			+ "\t\t\t'${Prefix.SHARED_ROOT_WITH_SLASH + ownerAccountName}/$oldSharedFirstPart$newSharedLastPart$pathLastPart';\n\t}\n}";
		Assert.equals(broken, triviaWrite(glued));
		Assert.equals(broken, triviaWrite(broken));
	}

	public function testStringAtomExactlyOnLimitStaysGlued(): Void {
		// Same shape one column shorter — exactly 140. Strict `>`: stays glued.
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal newShareTag:String = \'$${Prefix.SHARED_ROOT_WITH_SLASH + '
			+ 'ownerAccountName}/$$oldSharedFirstPart$$newSharedLastPart$$pathLastPart\';\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testUntypedDeclPastLimitBreaksAfterEq(): Void {
		// No LHS type annotation at all — the overflow probe must still fire.
		final glued: String = 'class C {\n\tfunction f() {\n\t\tfinal newSharedItemPath = \'$${Prefix.SHARED_ROOT_WITH_SLASH + '
			+ 'ownerAccountNameXy}/$$oldSharedFirstPart$$newSharedLastPart$$pathLastPart\';\n\t}\n}';
		final broken: String = 'class C {\n\tfunction f() {\n\t\tfinal newSharedItemPath =\n'
			+ "\t\t\t'${Prefix.SHARED_ROOT_WITH_SLASH + ownerAccountNameXy}/$oldSharedFirstPart$newSharedLastPart$pathLastPart';\n\t}\n}";
		Assert.equals(broken, triviaWrite(glued));
		Assert.equals(broken, triviaWrite(broken));
	}

	public function testWrappableCallRhsKeepsEqGlued(): Void {
		// A call RHS folds its own args (natural first line = the open paren),
		// so the decl stays glued to the `=` — the probe must not over-break.
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal sharedPathCacheKey:String = '
			+ 'buildSharedPathCacheKeyFromParts(ownerAccountName, oldSharedFirstPart, newSharedLastPart, pathLastPart);\n\t}\n}';
		final out: String = triviaWrite(src);
		Assert.isTrue(out.indexOf('String =\n') == -1);
		Assert.isTrue(out.indexOf('buildSharedPathCacheKeyFromParts(\n') != -1);
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
