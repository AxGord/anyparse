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
import unit.HxParamSliceTest;
import unit.HxPrefixSliceTest;
import unit.HaxeFastWriterRoundTripTest;
import unit.JsonFastParserTest;
import unit.JsonFastRoundTripTest;
import unit.SpanTest;
import unit.ParseErrorTest;
import unit.InputTest;

/**
	Entry point for the test suite. Adds every test case to the utest
	runner and reports results.
**/
class RunTests {
	public static function main() {
		var runner = new utest.Runner();
		runner.addCase(new ArParserTest());
		runner.addCase(new DocRendererTest());
		runner.addCase(new JsonFastParserTest());
		runner.addCase(new JsonFastRoundTripTest());
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
		runner.addCase(new HaxeFastWriterRoundTripTest());
		runner.addCase(new SpanTest());
		runner.addCase(new ParseErrorTest());
		runner.addCase(new InputTest());
		utest.ui.Report.create(runner);
		runner.run();
	}
}
