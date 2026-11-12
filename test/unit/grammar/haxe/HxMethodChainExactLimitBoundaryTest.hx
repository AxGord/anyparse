package unit.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.SameLinePolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.grammar.haxe.HxModuleWriteOptions;
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

	private static final CONFIG: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.lineWidth = 140;
		edited.sameLineExpressionElse = SameLinePolicy.SameOnBlock;
		edited.expressionIfBody = BodyPolicy.Next;
		edited.expressionElseBody = BodyPolicy.Next;
		edited.callParameterWrap = {
			containerItemWrap: {
				defaultMode: WrapMode.OnePerLine,
				rules: [
					{
						conditions: [
							{ cond: WrapConditionType.ItemCountLessThan, value: 3 },
							{ cond: WrapConditionType.HasContainerItems, value: 0 },
							{ cond: WrapConditionType.TotalItemLengthLessThan, value: 60 }
						],
						mode: WrapMode.FillLine
					}
				]
			},
			defaultAdditionalIndent: 0,
			defaultMode: WrapMode.FillLineWithLeadingBreak,
			rules: [
				{ conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }], mode: WrapMode.NoWrap },
				{
					conditions: [
						{ cond: WrapConditionType.ItemCountLessThan, value: 1 },
						{ cond: WrapConditionType.TotalItemLengthLessThan, value: 100 }
					],
					mode: WrapMode.NoWrap
				}
			]
		};
		edited.expressionWrappingWrap = {
			defaultAdditionalIndent: 0,
			defaultMode: WrapMode.FillLineWithLeadingBreak,
			rules: [
				{ conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }], mode: WrapMode.NoWrap }
			]
		};
		edited.functionTypeHaxe4 = WhitespacePolicy.None;
	});

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
