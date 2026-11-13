package unit.cli;

import anyparse.query.Cli;

/**
 * `apq mentions <Type>` lists, in its lit section, the type annotation of a field, a parameter and a local
 * `final` / `var` in a file that does not declare the type: the annotation sits in the node's `type` slot, and
 * `Lit.find` reads that slot like a child, so lit is a superset of the leaves `uses` reports.
 */
@:nullSafety(Strict)
class ApqMentionsLocalTypeLeafCliTest extends Test {

	private static final SOURCE: String = 'package a;\n\nclass M {\n\n\tvar field: Foo;\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function f(p: Foo): Void {\n\t\tfinal x: Null<Foo> = null;\n\t\tvar y: Foo = p;\n\t}\n\n}\n';

	/** One lit leaf per annotation: field, parameter, nested local, plain local. */
	@:pin('control')
	@:killer('M-LIT-TYPE-SLOT-UNWALKED')
	public function testLitListsFieldParameterAndLocalAnnotations(): Void {
		final lit: String = mentions('Foo').split('# lit')[1];
		for (position in ['5:', '9:', '10:', '11:']) Assert.isTrue(lit.indexOf('  $position') >= 0, 'no lit leaf at $position\n$lit');
	}

	private static function mentions(name: String): String {
		#if (sys || nodejs)
		final file: String = CliFixture.write('mentionstypeleaf', SOURCE);
		final out: String = CliFixture.captureStdout(() -> Cli.run(['mentions', name, file]));
		sys.FileSystem.deleteFile(file);
		return out;
		#else
		return '# lit  5: 9: 10: 11:';
		#end
	}

}
