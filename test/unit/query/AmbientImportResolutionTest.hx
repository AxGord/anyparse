package unit.query;

import anyparse.grammar.haxe.HaxeAmbientImports;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.AmbientImports;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * Resolution through an AMBIENT import source — a per-directory `import.hx`.
 *
 * Every fixture here is written to DISK, because the chain is a fact about where a module sits: an
 * in-memory file set with invented paths has no ancestors to walk. The precedence each pin asserts
 * was taken from the compiler, not from this implementation.
 */
@:nullSafety(Strict)
class AmbientImportResolutionTest extends Test {

	/** The fixture tree: a source root under `src`, one ambient source above it, and one per package. */
	private static final TREE: Array<{ name: String, source: String }> = [
		{ name: 'import.hx', source: 'import a.W;\n' },
		{ name: 'src/import.hx', source: 'import a.V;\n' },
		{ name: 'src/a/T.hx', source: 'package a;\n\nclass T {}\n' },
		{ name: 'src/a/U.hx', source: 'package a;\n\nclass U {}\n' },
		{ name: 'src/a/V.hx', source: 'package a;\n\nclass V {}\n' },
		{ name: 'src/a/W.hx', source: 'package a;\n\nclass W {}\n' },
		{
			name: 'src/a/Ext.hx',
			source: 'package a;\n\nclass Ext {\n\n\tpublic static function shout(s: String): String {\n\t\treturn s;\n\t}\n\n}\n'
		},
		{ name: 'src/b/T.hx', source: 'package b;\n\nclass T {}\n' },
		{ name: 'src/lib/import.hx', source: 'import a.T;\nimport a.U;\n\nusing a.Ext;\n' },
		{ name: 'src/lib/T.hx', source: 'package lib;\n\nclass T {}\n' },
		{ name: 'src/lib/Plain.hx', source: 'package lib;\n\nclass Plain {}\n' },
		{ name: 'src/lib/Misplaced.hx', source: 'package wrong;\n\nclass Misplaced {}\n' },
		{ name: 'src/lib/deep/import.hx', source: 'import b.T;\n' },
		{ name: 'src/lib/deep/Deep.hx', source: 'package lib.deep;\n\nclass Deep {}\n' },
		{ name: 'src/own/import.hx', source: 'import a.T;\n' },
		{ name: 'src/own/Own.hx', source: 'package own;\n\nimport b.T;\n\nclass Own {}\n' },
		{ name: 'src/wild/import.hx', source: 'import a.*;\n' },
		{ name: 'src/wild/Wild.hx', source: 'package wild;\n\nclass Wild {}\n' }
	];

	@:pin('control')
	@:killer('M-AMBIENT-IMPORT-BAND')
	public function testAmbientSourceOutranksTheSamePackageNamesake(): Void {
		#if (sys || nodejs)
		withTree(root -> {
			final index: SymbolIndex = indexOf(root);
			Assert.equals(
				'$root/src/a/T.hx', declaringFile(index, 'T', '$root/src/lib/Plain.hx'),
				'an ambient `import a.T;` outranks the `lib.T` of the reader\'s own package'
			);
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-IMPORT-BAND')
	public function testTheNearestAmbientSourceWinsAndTheParentStillBinds(): Void {
		#if (sys || nodejs)
		withTree(root -> {
			final index: SymbolIndex = indexOf(root);
			final from: String = '$root/src/lib/deep/Deep.hx';
			Assert.equals('$root/src/b/T.hx', declaringFile(index, 'T', from), 'the nested ambient source outranks its parent');
			Assert.equals('$root/src/a/U.hx', declaringFile(index, 'U', from), 'a name only the parent binds still resolves');
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('guard')
	public function testAFilesOwnImportOutranksTheAmbientOne(): Void {
		#if (sys || nodejs)
		withTree(root -> {
			final index: SymbolIndex = indexOf(root);
			Assert.equals(
				'$root/src/b/T.hx', declaringFile(index, 'T', '$root/src/own/Own.hx'),
				'the module own `import b.T;` outranks the ambient `import a.T;`, so the reference stays PINNED'
			);
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-CHAIN-EMPTY')
	public function testAmbientUsingAndWildcardBindTheirTypesBySimpleName(): Void {
		#if (sys || nodejs)
		withTree(root -> {
			final index: SymbolIndex = indexOf(root);
			Assert.equals(
				'$root/src/a/Ext.hx', declaringFile(index, 'Ext', '$root/src/lib/Plain.hx'),
				'an ambient `using a.Ext;` carries the module into simple-name scope'
			);
			Assert.equals(
				'$root/src/a/W.hx', declaringFile(index, 'W', '$root/src/wild/Wild.hx'),
				'an ambient `import a.*;` binds every type of the package it names'
			);
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-CHAIN-ROOT')
	public function testTheChainReachesTheSourceRootAndStopsThere(): Void {
		#if (sys || nodejs)
		withTree(root -> {
			final index: SymbolIndex = indexOf(root);
			final from: String = '$root/src/lib/Plain.hx';
			Assert.equals('$root/src/a/V.hx', declaringFile(index, 'V', from), 'the source root own ambient source applies');
			Assert.isNull(
				index.refs.resolveStartType('W', from), 'an ambient source ABOVE the source root is inert, as it is for the compiler'
			);
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-CHAIN-ROOT')
	public function testAChainThatCannotBeBoundedIsReportedUnbounded(): Void {
		#if (sys || nodejs)
		withTree(root -> {
			final index: SymbolIndex = indexOf(root);
			Assert.isTrue(boundedAt(index, '$root/src/lib/Plain.hx', 'Plain'), 'a module whose directory mirrors its package is bounded');
			Assert.isFalse(
				boundedAt(index, '$root/src/lib/Misplaced.hx', 'Misplaced'),
				'a module whose directory contradicts its package has no computable source root, so its chain is withheld'
			);
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-IMPORT-MAP')
	public function testTheImportMapCarriesAmbientBindingsOnlyWhenGivenAPath(): Void {
		#if (sys || nodejs)
		withTree(root -> {
			final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
			final path: String = '$root/src/lib/Plain.hx';
			final source: String = sys.io.File.getContent(path);
			Assert.equals('a.T', plugin.importMap(source, path)['T'], 'with a path the map carries what the chain binds');
			Assert.isNull(plugin.importMap(source)['T'], 'without a path there is no chain to read, so the map is the module own');
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-CHAIN-ROOT')
	public function testTheChainIsOrderedNearestFirst(): Void {
		#if (sys || nodejs)
		withTree(root -> {
			final chain: AmbientImports = HaxeAmbientImports.chainFor('$root/src/lib/deep/Deep.hx', 'lib.deep');
			Assert.equals(
				'$root/src/lib/deep/import.hx,$root/src/lib/import.hx,$root/src/import.hx', [for (s in chain.sources) s.file].join(','),
				'the chain is the walk upward from the module to its source root, nearest first'
			);
			Assert.isTrue(chain.bounded, 'the walk consumed exactly the package it was given');
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-AMBIENT-IMPORT-BAND')
	public function testTheEngineResolvesThroughAChainItDidNotComputeItself(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'lib/Plain.hx', source: 'package lib;\n\nclass Plain {}\n' },
			{ file: 'lib/T.hx', source: 'package lib;\n\nclass T {}\n' },
			{ file: 'a/T.hx', source: 'package a;\n\nclass T {}\n' }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		Assert.equals(
			'lib/T.hx', declaringFile(index, 'T', 'lib/Plain.hx'), 'with no ambient source only the same-package `lib.T` is in scope'
		);
		final host: Null<ResolvedType> = index.refs.findDeclaredType('lib/Plain.hx', 'Plain');
		if (host == null) {
			Assert.fail('the fixture file must be indexed');
			return;
		}
		// A source spelled nothing like the Haxe plugin file name, handed straight to the engine: what the
		// engine honours is the DATA on the file record, never a grammar spelling of where it came from.
		host.file.ambientImports = [
			{
				file: 'lib/globals.prelude',
				imports: [
					{
						raw: 'a.T',
						kind: ImportKind.Import,
						alias: null,
						aliasTarget: null,
						span: new Span(0, 0),
						guarded: false
					}
				]
			}
		];
		final resolved: Null<ResolvedType> = index.refs.resolveStartType('T', 'lib/Plain.hx');
		Assert.equals('a/T.hx', resolved == null ? 'null' : resolved.file.file, 'the ambient band sheds the same-package candidate');
	}

	/** Run `body` over a freshly written fixture tree, removing it afterwards. */
	private function withTree(body: (String) -> Void): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_ambient_import', TREE);
		try body(root) catch (exception: haxe.Exception) {
			CliFixture.removeDir(root);
			throw exception;
		}
		CliFixture.removeDir(root);
		#end
	}

	/** The index over every `.hx` of the fixture tree, paths as written. */
	private function indexOf(root: String): SymbolIndex {
		#if (sys || nodejs)
		final files: Array<{ file: String, source: String }> = [
			for (entry in TREE) { file: '$root/${entry.name}', source: sys.io.File.getContent('$root/${entry.name}') }
		];
		return SymbolIndex.build(files, new HaxeQueryPlugin());
		#else
		return SymbolIndex.build([], new HaxeQueryPlugin());
		#end
	}

	/** The file declaring what `name` resolves to from `from`, or a word naming why it did not resolve. */
	private function declaringFile(index: SymbolIndex, name: String, from: String): String {
		final resolved: Null<ResolvedType> = index.refs.resolveStartType(name, from);
		return resolved == null ? 'unresolved' : resolved.file.file;
	}

	/** Whether the ambient chain of the module declaring `typeName` in `file` was bounded. */
	private function boundedAt(index: SymbolIndex, file: String, typeName: String): Bool {
		final host: Null<ResolvedType> = index.refs.findDeclaredType(file, typeName);
		if (host == null) throw new haxe.Exception('the fixture file $file must declare $typeName');
		return host.file.ambientImportsBounded;
	}

}
