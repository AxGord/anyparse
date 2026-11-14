package unit.query;

import anyparse.query.ModuleMove;

/** A string literal composing a path from a package the move leaves populated is not a refusal. */
class ModuleMoveSurvivingPackageTest extends Test {

	@:pin('control')
	@:killer('M-MODMOVE-SURVIVING-BLIND')
	public function testAPrefixLiteralOfAPackageThatKeepsAModuleIsAccepted(): Void {
		final user: String = "package other;\n\nclass User {\n\tstatic function f(n: String): Dynamic return Type.resolveClass('pkg.' + "
			+ "n);\n\tstatic final P: String = 'pkg';\n}\n";
		final result: ModuleMoveResult = ModuleMove.run({
			moves: [{ from: 'src/pkg/A.hx', to: 'src/pkg/sub/A.hx' }],
			scopeFiles: [
				{ file: 'src/pkg/A.hx', source: 'package pkg;\n\nclass A {}\n' },
				{ file: 'src/pkg/B.hx', source: 'package pkg;\n\nclass B {}\n' },
				{ file: 'src/other/User.hx', source: user }
			],
			libraryFiles: [],
			textFiles: [],
			registries: [],
			sortedLists: [],
			mirrors: []
		}, new HaxeQueryPlugin());
		switch result {
			case Moved(_):
				Assert.pass();
			case Refused(reasons):
				Assert.fail(reasons.join(' | '));
		}
	}

}
