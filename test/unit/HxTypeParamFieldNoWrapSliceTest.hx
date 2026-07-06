package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-typeparam-field-nowrap: a typed field whose type is a generic with a
 * long type-parameter list, initialized by a `new`, must keep its LHS type on
 * ONE line (it fits `maxLineLength`) and break only AFTER `=` - matching the
 * fork. The bug: the field's `=`-break lowers to an `IfNaturalFirstLineExceeds`,
 * and the LHS type-param Star's trailing-width rest-probe DESCENDED that node's
 * flat branch, counting the whole `= new ...(...)` RHS as trailing content, so the
 * type-param `Group` failed its fit check and the `<A, B, C>` list wrapped even
 * though the LHS line fits 140. The fix makes the rest-probe treat
 * `IfNaturalFirstLineExceeds` as a break boundary (stops at `=`). Identifiers
 * are synthetic.
 */
@:nullSafety(Strict)
final class HxTypeParamFieldNoWrapSliceTest extends Test {

	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}}';

	public function new(): Void {
		super();
	}

	/** The LHS generic type (fits 140) stays on one line; only the `=` breaks - the type-param list does NOT wrap. */
	public function testLongGenericFieldTypeStaysOnOneLine(): Void {
		final src: String = 'class M {\n\tpublic final createPrimaryEntry:RemoteAction<PrimaryEntryRecordModel, PrimaryEntryRecordResponse, PrimaryEntryRecordRequest> =\n\t\tnew RemoteAction<PrimaryEntryRecordModel, PrimaryEntryRecordResponse, PrimaryEntryRecordRequest>(\'rootScope/CreatePrimary\');\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CFG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
