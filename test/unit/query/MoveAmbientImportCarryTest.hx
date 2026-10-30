package unit.query;

import anyparse.query.MoveSymbol;
import unit.cli.CliFixture;

using Lambda;
using StringTools;

/**
 * `move` over a dependency the source reaches only through an AMBIENT import source (`import.hx`), which no statement of
 * the source spells. The collision gate compares the declarations the two files bind, never the spelling of the path, so a
 * destination reaching the very same type by a statement of its own is no rebind — and one that binds a namesake elsewhere
 * still refuses. Written to disk: an ambient chain is a fact about where a module sits.
 */
@:nullSafety(Strict)
final class MoveAmbientImportCarryTest extends Test {

	/** The source module: `Moved` (line 5, column 7) writes `Node`, which only `src/p/import.hx` binds. */
	private static final HOST: String = 'package p;\n\nclass Host {}\n\nclass Moved {\n\tvar n: Node;\n}\n';

	/** The destination imports the very `q.Node` the ambient source gives the moved code, so the move rebinds nothing. */
	@:pin('control')
	@:killer('M-BINDING-NO-AMBIENT-CHAIN')
	public function testADestinationImportingTheAmbientTypeItselfTakesTheMove(): Void {
		#if (sys || nodejs)
		final dest: String = 'package p;\n\nimport q.Node;\n\nclass Dest {\n\tvar m: Node;\n}\n';
		switch moved(dest) {
			case Ok(changes, _):
				final written: Null<MoveChange> = changes.find(c -> c.file.endsWith('/src/p/Dest.hx'));
				Assert.isTrue(written?.newSource.contains('class Moved') == true, 'the declaration should arrive at the destination');
			case Err(message):
				Assert.fail('the destination binds the same q.Node the ambient import.hx gives the moved code, got: $message');
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The destination imports a NAMESAKE `r.Node`: the moved code would silently rebind to it, so the move still refuses. */
	@:pin('guard')
	public function testADestinationBindingANamesakeStillRefuses(): Void {
		#if (sys || nodejs)
		final dest: String = 'package p;\n\nimport r.Node;\n\nclass Dest {\n\tvar m: Node;\n}\n';
		switch moved(dest) {
			case Ok(_, _):
				Assert.fail('the moved code means q.Node and the destination binds r.Node — the move must refuse');
			case Err(message):
				Assert.isTrue(message.contains('r.Node'), 'the refusal should name the destination\'s binding, got: $message');
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Cross-package, `p` to `r`, where the destination's own package declares `r.Node`: the moved code means `q.Node`, so the
	 * ambient statement travels as an explicit `import q.Node;`, which outranks the package sibling — and the destination names
	 * no `Node` of its own that the carried line could rebind.
	 */
	@:pin('control')
	@:killer('M-CARRY-AMBIENT-PROVIDER-NONE')
	public function testTheCarriedAmbientImportOutranksADestinationPackageSibling(): Void {
		#if (sys || nodejs)
		switch moved('package r;\n\nclass Dest {}\n', 'src/r/Dest.hx') {
			case Ok(changes, _):
				final written: String = destSource(changes, '/src/r/Dest.hx');
				Assert.isTrue(written.contains('import q.Node;'), 'the ambient statement should be carried, got: $written');
			case Err(message):
				Assert.fail('a carried import q.Node outranks the package sibling r.Node, got: $message');
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The same move into a destination that NAMES its package sibling `r.Node`: the carried line would rebind that file's own
	 * references, so the move refuses — naming both bindings and the ambient file the moved code's binding comes from.
	 */
	@:pin('guard')
	public function testADestinationNamingItsPackageSiblingRefusesNamingTheAmbientSource(): Void {
		#if (sys || nodejs)
		switch moved('package r;\n\nclass Dest {\n\tvar m: Node;\n}\n', 'src/r/Dest.hx') {
			case Ok(_, _):
				Assert.fail('the destination means r.Node and the carried import would rebind it to q.Node — the move must refuse');
			case Err(message):
				Assert.isTrue(
					message.contains('r.Node') && message.contains('q.Node') && message.contains('/src/p/import.hx'),
					'the refusal should name both bindings and the ambient source, got: $message'
				);
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Cross-package, `p` to `s`, where nothing binds `Node`: the ambient statement is carried, or the moved code stops compiling. */
	@:pin('control')
	@:killer('M-CARRY-AMBIENT-PROVIDER-NONE')
	public function testAnAmbientBindingTheDestinationLacksIsCarried(): Void {
		#if (sys || nodejs)
		switch moved('package s;\n\nclass Dest {}\n', 'src/s/Dest.hx') {
			case Ok(changes, _):
				final written: String = destSource(changes, '/src/s/Dest.hx');
				Assert.isTrue(written.contains('import q.Node;'), 'the ambient statement should be carried, got: $written');
			case Err(message):
				Assert.fail('the moved code means q.Node and the destination binds nothing, got: $message');
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The source imports `q.Node` itself and the destination holds the same statement only inside `#if foo`: a build without
	 * `foo` would not find `Node`, so the guarded copy does not cover it and the statement is carried unconditionally.
	 */
	@:pin('control')
	@:killer('M-CARRY-HOLDS-GUARDED-COUNTS')
	public function testAGuardedCopyAtTheDestinationDoesNotCoverTheCarry(): Void {
		#if (sys || nodejs)
		// `Moved` stays on line 5, where `moved` addresses it.
		final host: String = 'package p;\nimport q.Node;\nclass Host {}\n\nclass Moved {\n\tvar n: Node;\n}\n';
		switch moved('package s;\n\n#if foo\nimport q.Node;\n#end\n\nclass Dest {}\n', 'src/s/Dest.hx', null, host) {
			case Ok(changes, _):
				final written: String = destSource(changes, '/src/s/Dest.hx');
				final unguarded: Int = written.indexOf('import q.Node;');
				Assert.isTrue(
					unguarded >= 0 && unguarded < written.indexOf('#if'), 'an unconditional import should be carried, got: $written'
				);
			case Err(message):
				Assert.fail('the destination binds the same q.Node under foo, got: $message');
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Cross-package with the destination's own `import.hx` importing `q.Node`: that ambient binding outranks the package
	 * sibling `r.Node`, so both files mean the one `q.Node` and the move goes through.
	 */
	@:pin('control')
	@:killer('M-BINDING-NO-AMBIENT-CHAIN')
	public function testADestinationImportHxBindingTheSameTypeOutranksItsPackageSibling(): Void {
		#if (sys || nodejs)
		switch moved('package r;\n\nclass Dest {}\n', 'src/r/Dest.hx', [{ name: 'src/r/import.hx', source: 'import q.Node;\n' }]) {
			case Ok(changes, _):
				final written: Null<MoveChange> = changes.find(c -> c.file.endsWith('/src/r/Dest.hx'));
				Assert.isTrue(written?.newSource.contains('class Moved') == true, 'the declaration should arrive at the destination');
			case Err(message):
				Assert.fail('both import.hx files bind the same q.Node, got: $message');
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Write the fixture tree (plus `extra`, with `host` as the source module) with `dest` at `destPath`, move `Moved` into it,
	 * and remove the tree again.
	 */
	private function moved(
		dest: String, destPath: String = 'src/p/Dest.hx', ?extra: Array<{ name: String, source: String }>, ?host: String
	): MoveResult {
		var result: MoveResult = Err('the fixture did not run');
		#if (sys || nodejs)
		final tree: Array<{ name: String, source: String }> = [
			{ name: 'src/p/import.hx', source: 'import q.Node;\n' },
			{ name: 'src/q/Node.hx', source: 'package q;\n\nclass Node {}\n' },
			{ name: 'src/r/Node.hx', source: 'package r;\n\nclass Node {}\n' },
			{ name: 'src/p/Host.hx', source: host ?? HOST },
			{ name: destPath, source: dest }
		].concat(extra ?? []);
		final root: String = CliFixture.writeTree('apq_move_ambient', tree);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final files: Array<{ file: String, source: String }> = [
				for (entry in tree) { file: '$root/${entry.name}', source: entry.source }
			];
			final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
			result = MoveSymbol.moveType('$root/src/p/Host.hx', 5, 7, '$root/$destPath', files, plugin, plugin.typeRefShape());
		});
		#end
		return result;
	}

	/** The text the move writes to the file whose path ends in `suffix`, empty when it writes none. */
	private static function destSource(changes: Array<MoveChange>, suffix: String): String {
		return changes.find(c -> c.file.endsWith(suffix))?.newSource ?? '';
	}

}
