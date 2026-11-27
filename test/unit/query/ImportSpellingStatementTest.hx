package unit.query;

import anyparse.check.Check.Violation;
import anyparse.check.Severity;
import anyparse.check.scan.UsingScan;
import anyparse.query.AddImport;
import anyparse.query.Constructs;
import anyparse.query.GrammarPlugin;
import anyparse.query.ImportSpelling;
import anyparse.query.MoveSymbol;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import anyparse.query.TypeRefPrinter;
import anyparse.runtime.Span;
import unit.check.haxe.expressions.RefusingConstructsPlugin;

using StringTools;

/**
 * The import and `using` statements a fix or an op writes are the grammar's own: every site asks `ImportSpelling.statementOf`
 * (the grammar's `Constructs`) and refuses when the grammar builds none, instead of spelling the statement itself.
 */
class ImportSpellingStatementTest extends Test {

	private static inline final SOURCE: String = 'package pkg;\n\nimport a.B;\n\nclass C {}\n';

	public function testStatementsAreTheGrammarsOwn(): Void {
		final build: Null<Constructs> = new HaxeQueryPlugin().constructs();
		Assert.equals('import a.b.C;', ImportSpelling.statementOf(build, 'a.b.C', false));
		Assert.equals('using a.b.C;', ImportSpelling.statementOf(build, 'a.b.C', true));
		Assert.equals('import a.b.C as D;', ImportSpelling.statementOf(build, 'a.b.C as D', false));
		Assert.isNull(ImportSpelling.statementOf(build, 'not a path', false));
		Assert.isNull(ImportSpelling.statementOf(null, 'a.b.C', false));
	}

	public function testAddImportRefusesWhereTheGrammarBuildsNoStatement(): Void {
		final bare: GrammarPlugin = new RefusingConstructsPlugin(_ -> null);
		for (isUsing in [false, true]) switch AddImport.addImport(SOURCE, 'x.Y', isUsing, false, bare) {
			case Ok(_, _):
				Assert.fail('a grammar with no constructs must not get a statement spelled by the op');
			case Err(message):
				Assert.isTrue(message.contains('builds no'), message);
		}
		switch AddImport.addImport(SOURCE, 'x.Y', false, false, new HaxeQueryPlugin()) {
			case Ok(text, _):
				Assert.isTrue(text.contains('import x.Y;'));
			case Err(message):
				Assert.fail(message);
		}
	}

	public function testUsingInsertIsRefusedWhereTheGrammarBuildsNone(): Void {
		final header: UsingHeader = headerOf(new RefusingConstructsPlugin(_ -> null));
		Assert.isNull(UsingScan.usingInsertEdit(header, 'Lambda'));
		Assert.isNull(UsingScan.usingInsertsEdit(header, ['Lambda']));
		final violation: Violation = {
			file: 'C.hx',
			span: new Span(0, 1),
			rule: 'probe',
			severity: Severity.Info,
			message: 'probe'
		};
		Assert.isNull(UsingScan.insertUnlessCovered(header, 'Lambda', [], [violation]));
		Assert.equals(UsingScan.unspellableUsingDecline('Lambda'), violation.declineReason);
		final real: UsingHeader = headerOf(new HaxeQueryPlugin());
		Assert.isTrue(UsingScan.usingInsertEdit(real, 'Lambda')?.text.contains('using Lambda;') == true);
	}

	public function testAMoveIsRefusedWhereTheGrammarBuildsNoStatement(): Void {
		final bare: GrammarPlugin = new RefusingConstructsPlugin(_ -> null);
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/A.hx', source: 'package pkg;\n\nclass Foo {}' },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' }
		];
		switch MoveSymbol.moveType('pkg/A.hx', 3, 7, 'pkg/B.hx', files, bare, new HaxeQueryPlugin().typeRefShape()) {
			case Ok(_, _):
				Assert.fail('a move writes import statements, which this grammar builds none of');
			case Err(message):
				Assert.isTrue(message.contains('builds no import statements'), message);
		}
	}

	public function testNoImportIsPromisedWhereTheGrammarBuildsNone(): Void {
		final source: String = 'package pkg;\n\nclass C {}\n';
		final real: HaxeQueryPlugin = new HaxeQueryPlugin();
		final bare: GrammarPlugin = new RefusingConstructsPlugin(_ -> null);
		final root: QueryNode = real.parseFile(source);
		final kept: TypeRefPrinter = TypeRefPrinter.forFile('pkg/C.hx', source, root, real.importMap(source), bare);
		Assert.equals('pkg.deep.Widget', kept.print('pkg.deep.Widget').text);
		Assert.isFalse(kept.hasPendingImports());
		final built: TypeRefPrinter = TypeRefPrinter.forFile('pkg/C.hx', source, root, real.importMap(source), real);
		Assert.equals('Widget', built.print('pkg.deep.Widget').text);
		Assert.isTrue(built.pendingImportEdits()[0].text.contains('import pkg.deep.Widget;'));
	}

	private static function headerOf(plugin: GrammarPlugin): UsingHeader {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, SOURCE);
		if (tree == null) throw 'the fixture must parse';
		return UsingScan.headerOf(tree, SOURCE, plugin, null);
	}

}
