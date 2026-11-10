package unit.grammar.haxe;

import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * This repository's own `hxformat.json` keeps the object-literal pad symmetric
 * (`{ a: 1 }`) where the literal is an arrow-lambda body, the same as at a var
 * value or a call argument: the fork-parity open-pad suppression there is a
 * default, and the repo config turns it off with `arrowBodyOpenPad`.
 */
@:nullSafety(Strict)
final class HxRepoConfigLambdaObjectBracesTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-ARROW-BODY-PAD-KEY-OFF')
	public function testLambdaBodyLiteralIsSymmetric(): Void {
		final src: String = inMethod('final entries = users.map(e -> { a: e.a, b: e.b });');
		Assert.equals(src, repoWrite(src));
	}

	@:pin('control')
	@:killer('M-ARROW-BODY-PAD-KEY-OFF')
	public function testLambdaBodyLiteralWithoutPadsGainsBoth(): Void {
		final src: String = inMethod('final entries = users.map(e -> {a: e.a, b: e.b});');
		Assert.equals(inMethod('final entries = users.map(e -> { a: e.a, b: e.b });'), repoWrite(src));
	}

	@:pin('guard')
	public function testVarValueAndCallArgumentKeepTheirPad(): Void {
		final src: String = inMethod('final v = { a: 1, b: 2 };\n\t\tuse({ a: 1, b: 2 });');
		Assert.equals(src, repoWrite(src));
	}

	private function repoWrite(src: String): String {
		return #if (sys || nodejs) HxWriteFixture.triviaWrite(src, File.getContent('hxformat.json')) #else src #end;
	}

	private static function inMethod(statements: String): String {
		return 'class C {\n\n\tfunction test() {\n\t\t$statements\n\t}\n\n}';
	}

}
