package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * omega-chain-exact-limit-boundary: a method chain whose full physical line
 * lands EXACTLY on `maxLineLength` must stay glued -- the fork keeps a
 * flush-at-limit line flat; only a line that EXCEEDS the limit breaks. The
 * chain probes are emitted as `IfFullLineExceeds(lineWidth, ...)` (bare
 * `lineWidth` is the family discriminator selecting the BG-descending rest
 * walker), so the renderer's exceed threshold is `n + 1` for a genuinely
 * one-line-able tail (a forced-hardline tail keeps the raw `>= n` proxy
 * calibration).
 * Before the fix the raw `>= n` comparison dot-broke a chain one column
 * early: at exactly 140 the statement shape tore `.setMarkerLink` onto its
 * own line, and the call-argument shape inside a ternary branch split its
 * receiver chain while the fork kept both on one line.
 */
@:nullSafety(Strict)
final class HxMethodChainExactLimitBoundaryTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "callParameter": {'
		+ '"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": ['
		+ '{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": '
		+ '"itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}, '
		+ '"expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": ['
		+ '{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}, "whitespace": {"commaPolicy": '
		+ '"after", "binopPolicy": "around", "arrowFunctionsPolicy": "around", "functionTypeHaxe3Policy": '
		+ '"none", "functionTypeHaxe4Policy": "none"}, "sameLine": {"expressionIf": "next"}}';

	public function new(): Void {
		super();
	}

	public function testStatementChainAtExactLimitStaysFlat(): Void {
		final flat: String = 'class C {\n\tfunction f() {\n\t\tfinal res = fetch(\'(Notice sent. <marker>Send '
			+ 're-noticexxxxx</<marker>)\').setMarkerLink(RENOTICE, Styles.getPanelDialText(), extra);\n\t}\n}';
		Assert.equals(flat, triviaWrite(flat));
	}

	public function testStatementChainOneOverLimitDotBreaks(): Void {
		final flat: String = 'class C {\n\tfunction f() {\n\t\tfinal res = fetch(\'(Notice sent. <marker>Send '
			+ 're-noticexxxxxx</<marker>)\').setMarkerLink(RENOTICE, Styles.getPanelDialText(), extra);\n\t}\n}';
		final wrapped: String = 'class C {\n\tfunction f() {\n\t\tfinal res = fetch(\'(Notice sent. <marker>Send '
			+ 're-noticexxxxxx</<marker>)\')\n\t\t\t.setMarkerLink(RENOTICE, Styles.getPanelDialText(), extra);\n\t}\n}';
		final out: String = triviaWrite(flat);
		Assert.equals(wrapped, out);
		Assert.equals(wrapped, triviaWrite(wrapped));
	}

	public function testCallArgChainAtExactLimitStaysFlat(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal info:Null<Panel> = cond.newInvite\n'
			+ "\t\t\t? new Panel(fetch('(Notice sent. <marker>Send re-notice</<marker>)').setMarkerLink(RENOTICE), "
			+ 'Styles.getPanelDialogText(), true)\n\t\t\t: null;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testCallArgChainOneOverLimitOpensCallParen(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal info:Null<Panel> = cond.newInvite\n'
			+ "\t\t\t? new Panel(fetch('(Notice sent. <marker>Send re-noticex</<marker>)').setMarkerLink(RENOTICE), "
			+ 'Styles.getPanelDialogText(), true)\n\t\t\t: null;\n\t}\n}';
		final wrapped: String = 'class C {\n\tfunction f() {\n\t\tfinal info:Null<Panel> = cond.newInvite\n\t\t\t? new Panel(\n'
			+ "\t\t\t\tfetch('(Notice sent. <marker>Send re-noticex</<marker>)').setMarkerLink(RENOTICE), Styles.getPanelDialogText(), "
			+ 'true\n\t\t\t)\n\t\t\t: null;\n\t}\n}';
		final out: String = triviaWrite(src);
		Assert.equals(wrapped, out);
		Assert.equals(wrapped, triviaWrite(wrapped));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
