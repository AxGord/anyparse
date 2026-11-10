package unit.grammar.haxe;

import anyparse.grammar.haxe.HxVarDecl;
import utest.Assert;

/**
 * An object-literal key written in single quotes is a field key like a double-quoted one: stored
 * verbatim WITH its quotes (`@:rawString` on `HxObjectKeyLit`).
 */
class HxObjectKeySingleQuotedTest extends HxTestHelpers {

	public function testSingleQuotedKey(): Void {
		final decl: HxVarDecl = parseSingleVarDecl("class C { var x:Dynamic = {'a_b_c': '1'}; }");
		switch decl.init {
			case ObjectLit(lit):
				Assert.equals(1, lit.fields.length);
				Assert.equals("'a_b_c'", (expectObjectFieldBody(lit.fields[0]).name: String));
			case null, _:
				Assert.fail('expected ObjectLit');
		}
	}

	public function testMixedKeyQuotes(): Void {
		final decl: HxVarDecl = parseSingleVarDecl("class C { var x:Dynamic = {a: 1, 'b-c': 2, \"d-e\": 3}; }");
		switch decl.init {
			case ObjectLit(lit):
				Assert.equals(3, lit.fields.length);
				Assert.equals('a', (expectObjectFieldBody(lit.fields[0]).name: String));
				Assert.equals("'b-c'", (expectObjectFieldBody(lit.fields[1]).name: String));
				Assert.equals('"d-e"', (expectObjectFieldBody(lit.fields[2]).name: String));
			case null, _:
				Assert.fail('expected ObjectLit(3 fields)');
		}
	}

	public function testSingleQuotedKeyBesideMetadataOnInterpolatedValue(): Void {
		final decl: HxVarDecl = parseSingleVarDecl("class C { var x:Dynamic = {'Host': @:nullSafety(Off) '127.0.0.1:${port}'}; }");
		switch decl.init {
			case ObjectLit(lit):
				Assert.equals("'Host'", (expectObjectFieldBody(lit.fields[0]).name: String));
			case null, _:
				Assert.fail('expected ObjectLit');
		}
	}

	public function testSingleQuotedKeyRoundTrips(): Void {
		roundTrip("class C { function main() { var x = {'a-b': 0}; } }", 'single-quoted key');
	}

	public function testSingleQuotedKeyHoldingDollarIsVerbatim(): Void {
		final decl: HxVarDecl = parseSingleVarDecl("class C { var x:Dynamic = {'c$port': 2}; }");
		switch decl.init {
			case ObjectLit(lit):
				Assert.equals("'c$port'", (expectObjectFieldBody(lit.fields[0]).name: String));
			case null, _:
				Assert.fail('expected ObjectLit');
		}
		roundTrip("class C { function main() { var x = {'c$port': 2}; } }", 'dollar key');
	}

}
