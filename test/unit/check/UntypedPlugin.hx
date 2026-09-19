package unit.check;

import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import haxe.exceptions.NotImplementedException;

/**
 * A `GrammarPlugin` that offers NO type information — the shape a type-gated entry loop must answer
 * nothing for, before it parses anything. Every method throws: the gate is expected to stop before
 * any is reached.
 */
@:nullSafety(Strict)
final class UntypedPlugin implements GrammarPlugin {

	public function new() {}

	public function langName(): String {
		throw new NotImplementedException();
	}

	public function parseFile(source: String): QueryNode {
		throw new NotImplementedException();
	}

	public function parsePattern(source: String): Pattern {
		throw new NotImplementedException();
	}

	public function refShape(): RefShape {
		throw new NotImplementedException();
	}

	public function projectedKinds(): Array<String> {
		throw new NotImplementedException();
	}

	public function metaShape(): MetaShape {
		throw new NotImplementedException();
	}

	public function selectKindEquivalence(): KindEquivalence {
		throw new NotImplementedException();
	}

	public function parseFileTypeRefs(source: String): QueryNode {
		throw new NotImplementedException();
	}

	public function projectBranchAware(tree: QueryNode, source: String): QueryNode {
		throw new NotImplementedException();
	}

	public function typeRefShape(): TypeRefShape {
		throw new NotImplementedException();
	}

	public function writeRoundTrip(source: String, ?optsJson: String): Null<String> {
		throw new NotImplementedException();
	}

	public function layoutMetrics(?optsJson: String): Null<LayoutMetrics> {
		throw new NotImplementedException();
	}

	public function writeRoundTripPlain(source: String, ?optsJson: String): Null<String> {
		throw new NotImplementedException();
	}

	public function reconParse(source: String): Bool {
		throw new NotImplementedException();
	}

	public function namingSupport(): Null<NamingSupport> {
		throw new NotImplementedException();
	}

	public function stringFoldSupport(): Null<StringFoldSupport> {
		throw new NotImplementedException();
	}

	public function maxComplexity(path: String): Null<Int> {
		throw new NotImplementedException();
	}

	public function controlFlowSupport(): Null<ControlFlowSupport> {
		throw new NotImplementedException();
	}

	public function lexicalRegions(source: String): Array<LexRegion> {
		throw new NotImplementedException();
	}

	public function booleanLogicSupport(): Null<BooleanLogicSupport> {
		throw new NotImplementedException();
	}

	public function knownExtensionMethods(modulePath: String): Null<Array<String>> {
		throw new NotImplementedException();
	}

	public function checkOverrides(path: String): Null<CheckOverrides> {
		throw new NotImplementedException();
	}

	public function ambientImportSources(path: String, pkg: String): AmbientImports {
		throw new NotImplementedException();
	}

}
