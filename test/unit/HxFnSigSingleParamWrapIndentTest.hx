package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-fnsig-singleparam-indent: when a function signature leading-breaks
 * (whole sig too long, `fillLineWithLeadingBreak`) and the `functionSignature`
 * cascade resolves to `noWrap` because the param list has a single item
 * (`itemCount <= 1`), the lone param must land ONE indent level below the
 * signature (the signature at N tabs -> param at N+1), matching the closing
 * `)` and the haxe-formatter fork. anyparse indented it at N+2 (an extra tab)
 * on this single-param noWrap path, while the multi-param one-per-line path
 * already used N+1. Identifiers are synthetic and bear no relation to any
 * downstream code.
 */
@:nullSafety(Strict)
final class HxFnSigSingleParamWrapIndentTest extends Test {

	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "functionSignature": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 100}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}], "type": "noWrap"}]}}, "whitespace": {"functionTypeHaxe4Policy": "none", "functionTypeHaxe3Policy": "none"}}';

	public function new(): Void {
		super();
	}

	/** A single-param signature that leading-breaks puts the lone param at signature-indent + 1 (2 tabs for a 1-tab method), not + 2. */
	public function testSingleParamLeadingBreakIndentsOneLevel(): Void {
		final src: String = 'class M {\n\tpublic function createOperationz(?sessionLoader:(cb:(handlerArg:GenericBaseKindType<PrimaryObserverKindXy>, finishCb:()->Void)->Void)->Void):ResultCarrierValue<A, A2> {\n\t\treturn null;\n\t}\n}';
		final expected: String = 'class M {\n\tpublic function createOperationz(\n\t\t?sessionLoader:(cb:(handlerArg:GenericBaseKindType<PrimaryObserverKindXy>, finishCb:()->Void)->Void)->Void\n\t):ResultCarrierValue<A, A2> {\n\t\treturn null;\n\t}\n}';
		Assert.equals(expected, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CFG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
