import unit.ArParserTest;
import unit.DocRendererTest;
import unit.HaxeFirstSliceTest;
import unit.HaxeModuleSliceTest;
import unit.HxAssignSliceTest;
import unit.HxBitwiseSliceTest;
import unit.HxExprSliceTest;
import unit.HxParenSliceTest;
import unit.HxPrattSliceTest;
import unit.HxPrattOpsTest;
import unit.HxPostfixSliceTest;
import unit.HxModifierSliceTest;
import unit.HxBodySliceTest;
import unit.HxTernarySliceTest;
import unit.HxTopLevelSliceTest;
import unit.HxControlFlowSliceTest;
import unit.HxForEnumVoidSliceTest;
import unit.HxSwitchNewSliceTest;
import unit.HxDoWhileThrowTryCatchSliceTest;
import unit.HxAbstractSliceTest;
import unit.HxStringSliceTest;
import unit.HxArrowArraySliceTest;
import unit.HxObjectLitSliceTest;
import unit.HxParamSliceTest;
import unit.HxPrefixSliceTest;
import unit.HxSameLineOptionsTest;
import unit.HxTrailingCommaOptionsTest;
import unit.HxLeftCurlyOptionsTest;
import unit.HxObjectFieldColonOptionsTest;
import unit.HxElseIfOptionsTest;
import unit.HxTriviaTypesTest;
import unit.HxTriviaParseTest;
import unit.HxTriviaWriteTest;
import unit.HaxeFormatConfigLoaderTest;
import unit.HaxeWriterRoundTripTest;
import unit.HxFormatterCorpusTest;
import unit.JsonParserTest;
import unit.JsonRoundTripTest;
import unit.JsonTypedParserTest;
import unit.SpanTest;
import unit.ParseErrorTest;
import unit.InputTest;
import unit.WriteOptionsTest;

/**
	Entry point for the test suite. Adds every test case to the utest
	runner and reports results.
**/
class RunTests {
	public static function main() {
		var runner = new utest.Runner();
		runner.addCase(new ArParserTest());
		runner.addCase(new DocRendererTest());
		runner.addCase(new JsonParserTest());
		runner.addCase(new JsonRoundTripTest());
		runner.addCase(new HaxeFirstSliceTest());
		runner.addCase(new HaxeModuleSliceTest());
		runner.addCase(new HxExprSliceTest());
		runner.addCase(new HxPrattSliceTest());
		runner.addCase(new HxPrattOpsTest());
		runner.addCase(new HxParenSliceTest());
		runner.addCase(new HxAssignSliceTest());
		runner.addCase(new HxBitwiseSliceTest());
		runner.addCase(new HxPrefixSliceTest());
		runner.addCase(new HxPostfixSliceTest());
		runner.addCase(new HxModifierSliceTest());
		runner.addCase(new HxParamSliceTest());
		runner.addCase(new HxBodySliceTest());
		runner.addCase(new HxTernarySliceTest());
		runner.addCase(new HxTopLevelSliceTest());
		runner.addCase(new HxControlFlowSliceTest());
		runner.addCase(new HxForEnumVoidSliceTest());
		runner.addCase(new HxSwitchNewSliceTest());
		runner.addCase(new HxDoWhileThrowTryCatchSliceTest());
		runner.addCase(new HxAbstractSliceTest());
		runner.addCase(new HxStringSliceTest());
		runner.addCase(new HxArrowArraySliceTest());
		runner.addCase(new HxObjectLitSliceTest());
		runner.addCase(new HxSameLineOptionsTest());
		runner.addCase(new HxTrailingCommaOptionsTest());
		runner.addCase(new HxLeftCurlyOptionsTest());
		runner.addCase(new HxObjectFieldColonOptionsTest());
		runner.addCase(new HxElseIfOptionsTest());
		runner.addCase(new HxTriviaTypesTest());
		runner.addCase(new HxTriviaParseTest());
		runner.addCase(new HxTriviaWriteTest());
		runner.addCase(new HaxeFormatConfigLoaderTest());
		runner.addCase(new HaxeWriterRoundTripTest());
		runner.addCase(new HxFormatterCorpusTest());
		runner.addCase(new JsonTypedParserTest());
		runner.addCase(new SpanTest());
		runner.addCase(new ParseErrorTest());
		runner.addCase(new InputTest());
		runner.addCase(new WriteOptionsTest());
		utest.ui.Report.create(runner);
		runner.run();
	}
}
