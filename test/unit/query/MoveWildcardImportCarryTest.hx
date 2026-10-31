package unit.query;

import anyparse.query.MoveSymbol;
import unit.cli.CliFixture;

using Lambda;
using StringTools;

/**
 * `move` over a dependency the source reaches only through a PACKAGE wildcard (`import pkg.*;`, its own or its ambient
 * `import.hx` chain's), and over a `using` only the ambient chain supplies. The wildcard travels as written, unless the
 * destination's own code names another type of that package the carried line would take over. Written to disk: an
 * ambient chain is a fact about where a module sits.
 */
@:nullSafety(Strict)
final class MoveWildcardImportCarryTest extends Test {

	/** The package the wildcard lists: `Node`, which the moved code writes, and `Other`, which it does not. */
	private static final PACKAGE_Q: Array<{ name: String, source: String }> = [
		{ name: 'src/q/Node.hx', source: 'package q;\n\nclass Node {\n\tpublic function new() {}\n}\n' },
		{ name: 'src/q/Other.hx', source: 'package q;\n\nclass Other {}\n' }
	];

	/** `Moved` (line 7, column 7) writes `Node`, which only the source's own `import q.*;` binds. */
	private static final HOST_OWN_WILDCARD: String = 'package p;\n\nimport q.*;\n\nclass Host {}\n\nclass Moved {\n\tvar n: Node;\n}\n';

	/** `Moved` (line 5, column 7) writes `Node` with no statement of the source's own spelling it. */
	private static final HOST_BARE: String = 'package p;\n\nclass Host {}\n\nclass Moved {\n\tvar n: Node;\n}\n';

	/** The source's own package wildcard is the only binding of `Node`: it is carried, where the move used to refuse. */
	@:pin('control')
	@:killer('M-CARRY-TYPE-WILDCARD-NONE')
	public function testTheSourcesOwnPackageWildcardIsCarried(): Void {
		assertCarries(moved('package r;\n\nclass Dest {}\n', HOST_OWN_WILDCARD, 7, PACKAGE_Q), 'import q.*;');
	}

	/** The source's ambient `import.hx` holds the wildcard: it travels as an explicit statement, as an ambient import does. */
	@:pin('control')
	@:killer('M-CARRY-TYPE-WILDCARD-NONE')
	public function testAnAmbientPackageWildcardIsCarried(): Void {
		final tree: Array<{ name: String, source: String }> = PACKAGE_Q.concat([{ name: 'src/p/import.hx', source: 'import q.*;\n' }]);
		assertCarries(moved('package r;\n\nclass Dest {}\n', HOST_BARE, 5, tree), 'import q.*;');
	}

	/**
	 * A std package wildcard binding `Map`, which is also a toplevel name: the moved code means `haxe.ds.Map`, and the move
	 * carries `import haxe.ds.*;` instead of refusing that it has nothing to carry.
	 */
	@:pin('control')
	@:killer('M-CARRY-TYPE-WILDCARD-NONE')
	public function testAStdPackageWildcardBindingMapIsCarried(): Void {
		final host: String = 'package p;\n\nimport haxe.ds.*;\n\nclass Host {}\n\nclass Moved {\n\tvar m: Map<String, Int>;\n}\n';
		assertCarries(moved('package r;\n\nclass Dest {}\n', host, 7, []), 'import haxe.ds.*;');
	}

	/**
	 * The destination names `Other` and means its package sibling `r.Other`: the carried `import q.*;` outranks the package,
	 * so that file's own `Other` would silently become `q.Other` — the move refuses, naming it.
	 */
	@:pin('control')
	@:killer('M-CARRY-TYPE-WILDCARD-CLASH-BLIND')
	public function testADestinationNamingAnotherTypeOfThePackageRefuses(): Void {
		#if (sys || nodejs)
		final tree: Array<{ name: String, source: String }> = PACKAGE_Q.concat([
			{
				name: 'src/r/Other.hx',
				source: 'package r;\n\nclass Other {}\n'
			}
		]);
		switch moved('package r;\n\nclass Dest {\n\tvar o: Other;\n}\n', HOST_OWN_WILDCARD, 7, tree) {
			case Ok(_, _):
				Assert.fail('the carried wildcard would rebind the destination\'s Other from r.Other to q.Other — the move must refuse');
			case Err(message):
				Assert.isTrue(
					message.contains('"Other"') && message.contains('q.Other'), 'the refusal should name the rebound type, got: $message'
				);
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The same clash over a STD package, which the index does not hold, so its type list comes from the std listing: the
	 * destination names its package sibling `r.Vector`, and the carried `import haxe.ds.*;` would silently make it
	 * `haxe.ds.Vector` — the move refuses, naming it.
	 */
	@:pin('control')
	@:killer('M-STD-MODULE-NAMES-NONE')
	public function testADestinationNamingAnotherTypeOfAStdPackageRefuses(): Void {
		#if (sys || nodejs)
		final host: String = 'package p;\n\nimport haxe.ds.*;\n\nclass Host {}\n\nclass Moved {\n\tvar m: StringMap<Int>;\n}\n';
		final tree: Array<{ name: String, source: String }> = [{ name: 'src/r/Vector.hx', source: 'package r;\n\nclass Vector {}\n' }];
		switch moved('package r;\n\nclass Dest {\n\tvar v: Vector;\n}\n', host, 7, tree) {
			case Ok(_, _):
				Assert.fail(
					'the carried wildcard would rebind the destination\'s Vector from r.Vector to haxe.ds.Vector — the move must refuse'
				);
			case Err(message):
				Assert.isTrue(
					message.contains('"Vector"') && message.contains('haxe.ds.Vector'),
					'the refusal should name the rebound type, got: $message'
				);
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The destination names `Other` through an explicit import, which outranks any wildcard: nothing rebinds, the move goes through. */
	@:pin('guard')
	public function testADestinationImportingTheOtherTypeExplicitlyTakesTheMove(): Void {
		final tree: Array<{ name: String, source: String }> = PACKAGE_Q.concat([
			{
				name: 'src/r/Other.hx',
				source: 'package r;\n\nclass Other {}\n'
			}
		]);
		assertCarries(
			moved('package r;\n\nimport r.Other;\n\nclass Dest {\n\tvar o: Other;\n}\n', HOST_OWN_WILDCARD, 7, tree), 'import q.*;'
		);
	}

	/**
	 * The moved code calls `qx`, an extension only the source's ambient `using q.Tools;` grants: the destination lies outside
	 * that chain, so the `using` is carried — without it the move writes `q.Node has no field qx`.
	 */
	@:pin('control')
	@:killer('M-CARRY-USING-OWN-ONLY')
	public function testAUsingOnlyTheAmbientChainSuppliesIsCarried(): Void {
		final host: String =
			'package p;\n\nclass Host {}\n\nclass Moved {\n\tpublic function new() {\n\t\ttrace(new Node().qx());\n\t}\n}\n';
		final tree: Array<{ name: String, source: String }> = PACKAGE_Q.concat([
			{ name: 'src/q/Tools.hx', source: 'package q;\n\nclass Tools {\n\tpublic static function qx(n: Node): Int return 1;\n}\n' },
			{ name: 'src/p/import.hx', source: 'import q.Node;\nusing q.Tools;\n' }
		]);
		assertCarries(moved('package r;\n\nclass Dest {}\n', host, 5, tree), 'using q.Tools;');
	}

	/** The move succeeded and wrote `line` into the destination. */
	private static function assertCarries(result: MoveResult, line: String): Void {
		#if (sys || nodejs)
		switch result {
			case Ok(changes, _):
				final written: String = changes.find(c -> c.file.endsWith('/src/r/Dest.hx'))?.newSource ?? '';
				Assert.isTrue(written.contains('class Moved') && written.contains(line), 'the move should carry "$line", got: $written');
			case Err(message):
				Assert.fail('the move should carry "$line", got: $message');
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Write `extra` plus the source module `host` and `dest` at `src/r/Dest.hx`,
	 * move `Moved` (at `line`, column 7) there, and remove the tree.
	 */
	private static function moved(dest: String, host: String, line: Int, extra: Array<{ name: String, source: String }>): MoveResult {
		var result: MoveResult = Err('the fixture did not run');
		#if (sys || nodejs)
		final tree: Array<{ name: String, source: String }> = extra.concat([
			{ name: 'src/p/Host.hx', source: host },
			{ name: 'src/r/Dest.hx', source: dest }
		]);
		final root: String = CliFixture.writeTree('apq_move_wildcard', tree);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final files: Array<{ file: String, source: String }> = [
				for (entry in tree) { file: '$root/${entry.name}', source: entry.source }
			];
			final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
			result = MoveSymbol.moveType('$root/src/p/Host.hx', line, 7, '$root/src/r/Dest.hx', files, plugin, plugin.typeRefShape());
		});
		#end
		return result;
	}

}
