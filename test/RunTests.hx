import unit.DocRendererTest;
import unit.HaxeFirstSliceTest;
import unit.HaxeModuleSliceTest;
import unit.HxExprSliceTest;
import unit.HxPrattSliceTest;
import unit.JsonParserTest;
import unit.JsonMacroParserTest;
import unit.JsonWriterTest;
import unit.JsonRoundTripTest;
import unit.JsonMacroRoundTripTest;
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
		runner.addCase(new DocRendererTest());
		runner.addCase(new JsonParserTest());
		runner.addCase(new JsonMacroParserTest());
		runner.addCase(new JsonWriterTest());
		runner.addCase(new JsonRoundTripTest());
		runner.addCase(new JsonMacroRoundTripTest());
		runner.addCase(new HaxeFirstSliceTest());
		runner.addCase(new HaxeModuleSliceTest());
		runner.addCase(new HxExprSliceTest());
		runner.addCase(new HxPrattSliceTest());
		runner.addCase(new SpanTest());
		runner.addCase(new ParseErrorTest());
		runner.addCase(new InputTest());
		utest.ui.Report.create(runner);
		runner.run();
	}
}
