package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * A paren-bearing meta (`@:name(args)`) prefixing an unbraced `if`
 * statement must keep the space between the meta's closing `)` and
 * the `if` keyword. Regression shape: the statement is followed by
 * another statement (forcing the `HxMetaStmt` route — the unbraced
 * branch consumed its `;`, so `ExprStmt(MetaExpr(...))` cannot
 * terminate), and the writer glued `@:n(Off)if (...)`.
 *
 * Bare metas (`@:n if`) and non-empty `rest` (`@:a(b) @:c if`) were
 * unaffected; both are pinned here as guards.
 */
class HxMetaCallStmtSpaceTest extends HxTestHelpers {

	public function testMetaCallBeforeUnbracedIfKeepsSpace(): Void {
		writerEquals(
			'class C {\n\tfunction f():Void {\n\t\t@:nullSafety(Off) if (value != null) target.field = value;\n\t\tnext = 1;\n\t}\n}\n',
			'class C {\n\tfunction f():Void {\n\t\t@:nullSafety(Off) if (value != null) target.field = value;\n\t\tnext = 1;\n\t}\n}\n',
			'meta-call before unbraced if'
		);
	}

	public function testBareMetaBeforeUnbracedIfKeepsSpace(): Void {
		writerEquals(
			'class C {\n\tfunction f():Void {\n\t\t@:unreflective if (value != null) target.field = value;\n\t\tnext = 1;\n\t}\n}\n',
			'class C {\n\tfunction f():Void {\n\t\t@:unreflective if (value != null) target.field = value;\n\t\tnext = 1;\n\t}\n}\n',
			'bare meta before unbraced if'
		);
	}

	// Non-empty `rest` guard — only the meta→stmt boundary is pinned.
	// The `first`→`rest` inter-meta separator (`@:a(b) @:c`) is a
	// separate pre-existing gap: the inter-Star separator after a
	// mandatory Ref stays quiet because trivia Stars that emit their
	// own leading hardline would get a doubled break.
	public function testMetaCallPlusBareMetaBeforeUnbracedIfKeepsStmtSpace(): Void {
		final written: String = HxModuleWriter.write(
			HaxeModuleParser.parse(
				'class C {\n\tfunction f():Void {\n\t\t@:a(b) @:c if (value != null) target.field = value;\n\t\tnext = 1;\n\t}\n}\n'
			)
		);
		Assert.isTrue(written.indexOf('@:c if (') != -1, 'space between last meta and `if` lost: <$written>');
	}

}
