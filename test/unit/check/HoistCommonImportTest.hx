package unit.check;

import anyparse.check.Check;
import anyparse.check.EmptyAmbientSource;
import anyparse.check.HoistCommonImport;
import anyparse.check.LintConfig;
import anyparse.check.Naming;
import anyparse.check.OracleCoverage;
import anyparse.check.UnusedImport;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.query.ReachLiveness.ReachBuilds;
import anyparse.query.StdResolver;
import anyparse.query.cli.command.LintFixDriver;
import anyparse.runtime.Span;
import haxe.io.Path;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * One file of a fixture tree: its tree-relative `name` and its `source`. Named because the fixtures,
 * the helpers that write them and the ones that read a fix back all pass the same pair.
 */
private typedef TreeFile = {
	var name: String;
	var source: String;
}

/**
 * `hoist-common-import` — which statement earns a place in a directory's ambient source, which one
 * is refused, and what the cross-file fix writes.
 *
 * Every fixture is a real tree on disk: the governed set and the chain are read from there, so an
 * in-memory file set cannot exercise either. Type names are NONCES — a one-letter or common name is
 * unreportable by construction, since the resolution scope joins the language's own std and any
 * string literal is a possible reflection key.
 */
@:nullSafety(Strict)
class HoistCommonImportTest extends Test {

	/** What `hoistedSites` puts between two slices — never a `;`, which every statement it renders ends with. */
	private static inline final SITE_SEPARATOR: String = ' :: ';

	/** A class body calling `tqq` extension-style on a `String` — the access a rival `using` declaring `tqq` contests. */
	private static inline final CALLS_TQQ: String = '\n\n\tfunction f(s:String):String {\n\t\treturn s.tqq();\n\t}\n\n';

	/** What `planned` reports for `usingTree` whose three modules also keep a rival `using` no access contests. */
	private static inline final HOISTED_PAST_RIVAL: String = 'src/aqq/OneQq.hx:qqz.Sqqwwee@src/import.hx,src/aqq/ThreeQq.hx:qqz.Sqqwwee@src/import.hx,'
		+ 'src/aqq/TwoQq.hx:qqz.Sqqwwee@src/import.hx';

	/** Four modules of one package spelling one import, and a fifth that does not. */
	private static final COMMON_TREE: Array<TreeFile> = [
		{ name: 'src/qqz/Zqqwwee.hx', source: 'package qqz;\n\nclass Zqqwwee {}\n' },
		{ name: 'src/aqq/OneQq.hx', source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass OneQq {\n\n\tvar a: Zqqwwee;\n\n}\n' },
		{ name: 'src/aqq/TwoQq.hx', source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass TwoQq {\n\n\tvar a: Zqqwwee;\n\n}\n' },
		{ name: 'src/aqq/ThreeQq.hx', source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass ThreeQq {\n\n\tvar a: Zqqwwee;\n\n}\n' },
		{ name: 'src/aqq/FourQq.hx', source: 'package aqq;\n\nclass FourQq {}\n' }
	];

	/**
	 * Three modules of one package importing the MODULE `aqq.Modqqw`, whose sibling `Othqqw` a
	 * same-package `bqq.Othqqw` is a namesake of — and a fourth module that reads bare `Othqqw`
	 * without importing anything.
	 */
	private static final SIBLING_TREE: Array<TreeFile> = [
		{
			name: 'src/aqq/Modqqw.hx',
			source: 'package aqq;\n\nclass Modqqw {\n\n\tpublic static function who(): String {\n\t\treturn \'aqq\';\n\t}\n\n}\n\n'
				+ 'class Othqqw {\n\n\tpublic static function who(): String {\n\t\treturn \'aqq.Othqqw\';\n\t}\n\n}\n\n'
				+ 'class Subqqw {\n\n\tpublic static function who(): String {\n\t\treturn \'aqq.Subqqw\';\n\t}\n\n}\n'
		},
		{
			name: 'src/bqq/Othqqw.hx',
			source: 'package bqq;\n\nclass Othqqw {\n\n\tpublic static function who(): String {\n\t\treturn \'bqq\';\n\t}\n\n}\n'
		},
		{
			name: 'src/bqq/MqqOne.hx',
			source: 'package bqq;\n\nimport aqq.Modqqw;\n\nclass MqqOne {\n\n\tpublic static function run(): String {\n\t\t'
				+ 'return Modqqw.who();\n\t}\n\n}\n'
		},
		{
			name: 'src/bqq/MqqTwo.hx',
			source: 'package bqq;\n\nimport aqq.Modqqw;\n\nclass MqqTwo {\n\n\tpublic static function run(): String {\n\t\t'
				+ 'return Modqqw.who();\n\t}\n\n}\n'
		},
		{
			name: 'src/bqq/MqqThree.hx',
			source: 'package bqq;\n\nimport aqq.Modqqw;\n\nclass MqqThree {\n\n\tpublic static function run(): String {\n\t\t'
				+ 'return Modqqw.who();\n\t}\n\n}\n'
		},
		{
			name: 'src/bqq/Userqqw.hx',
			source: 'package bqq;\n\nclass Userqqw {\n\n\tpublic static function run(): String {\n\t\treturn Othqqw.who();\n\t}\n\n}\n'
		}
	];

	/** A modules-and-nesting tree: one statement every module spells, one only the nested package does. */
	private static final NESTED_TREE: Array<TreeFile> = [
		{ name: 'src/qqz/Zqqwwee.hx', source: 'package qqz;\n\nclass Zqqwwee {}\n' },
		{ name: 'src/qqz/Yqqwwee.hx', source: 'package qqz;\n\nclass Yqqwwee {}\n' },
		{
			name: 'src/aqq/OneQq.hx',
			source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass OneQq {\n\n\tvar a: Zqqwwee;\n\n}\n'
		},
		{
			name: 'src/aqq/TwoQq.hx',
			source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass TwoQq {\n\n\tvar a: Zqqwwee;\n\n}\n'
		},
		{
			name: 'src/aqq/bqq/ThreeQq.hx',
			source: 'package aqq.bqq;\n\nimport qqz.Yqqwwee;\nimport qqz.Zqqwwee;\n\nclass ThreeQq {\n\n\tvar a: Zqqwwee;\n'
				+ '\tvar b: Yqqwwee;\n\n}\n'
		},
		{
			name: 'src/aqq/bqq/FourQq.hx',
			source: 'package aqq.bqq;\n\nimport qqz.Yqqwwee;\nimport qqz.Zqqwwee;\n\nclass FourQq {\n\n\tvar a: Zqqwwee;\n'
				+ '\tvar b: Yqqwwee;\n\n}\n'
		},
		{
			name: 'src/aqq/bqq/FiveQq.hx',
			source: 'package aqq.bqq;\n\nimport qqz.Yqqwwee;\nimport qqz.Zqqwwee;\n\nclass FiveQq {\n\n\tvar a: Zqqwwee;\n'
				+ '\tvar b: Yqqwwee;\n\n}\n'
		}
	];

	/** Two types of a LIBRARY — a classpath entry of its own, outside every directory a fixture writes. */
	private static final LIBRARY_FILES: Array<{ file: String, source: String }> = [
		{ file: '/nonexistent-hoistqq-lib/qqz/Zqqwwee.hx', source: 'package qqz;\n\nclass Zqqwwee {}\n' },
		{ file: '/nonexistent-hoistqq-lib/qqz/Yqqwwee.hx', source: 'package qqz;\n\nclass Yqqwwee {}\n' }
	];

	/** The modules of `aqqTree`, tree-relative — what a build compiling that package parses. */
	private static final AQQ_MODULES: Array<String> = [
		'src/aqq/OneQq.hx',
		'src/aqq/TwoQq.hx',
		'src/aqq/ThreeQq.hx',
		'src/aqq/FourQq.hx'
	];

	/** An ambient source carrying a statement ONE of the five modules it governs reads. */
	private static final SINK_TREE: Array<TreeFile> = [
		{ name: 'src/qqz/Rqqwwee.hx', source: 'package qqz;\n\nclass Rqqwwee {}\n' },
		{ name: 'src/aqq/import.hx', source: 'import qqz.Rqqwwee;\n' },
		{ name: 'src/aqq/OneQq.hx', source: 'package aqq;\n\nclass OneQq {\n\n\tvar a:Rqqwwee;\n\n}\n' },
		{ name: 'src/aqq/TwoQq.hx', source: 'package aqq;\n\nclass TwoQq {}\n' },
		{ name: 'src/aqq/ThreeQq.hx', source: 'package aqq;\n\nclass ThreeQq {}\n' },
		{ name: 'src/aqq/FourQq.hx', source: 'package aqq;\n\nclass FourQq {}\n' },
		{ name: 'src/aqq/FiveQq.hx', source: 'package aqq;\n\nclass FiveQq {}\n' }
	];

	/**
	 * A statement most modules of a directory spell moves to the widest position whose share it
	 * reaches, and every module that spells it is reported.
	 */
	@:pin('control')
	@:killer('M-HOIST-NEVER-SOUND')
	public function testHoistsAnImportMostModulesSpell(): Void {
		Assert.equals(
			'src/aqq/OneQq.hx:qqz.Zqqwwee@src/import.hx,src/aqq/ThreeQq.hx:qqz.Zqqwwee@src/import.hx,'
			+ 'src/aqq/TwoQq.hx:qqz.Zqqwwee@src/import.hx',
			planned(COMMON_TREE)
		);
	}

	/** An ALIAS binds a name the rule cannot follow into an ambient source. */
	@:pin('guard')
	public function testRefusesAnAlias(): Void {
		Assert.equals('', planned(withStatement('import qqz.Zqqwwee as Uqqwwee;', 'Uqqwwee')));
	}

	/** A PACKAGE wildcard binds every module of a package, which no enumeration here could name. */
	@:pin('guard')
	public function testRefusesAPackageWildcard(): Void {
		Assert.equals('', planned(withStatement('import qqz.*;', 'Zqqwwee')));
	}

	/** A STATIC wildcard binds members, not a type name — a different question, refused here. */
	@:pin('guard')
	public function testRefusesAStaticWildcard(): Void {
		Assert.equals('', planned(withStatement('import qqz.Zqqwwee.*;', 'Zqqwwee')));
	}

	/**
	 * An ENUM import binds its constructors, and the ambient copy would outrank a module's own field
	 * import of the same name in either order: `FourQq`'s bare `Rqqwq` means
	 * `Kqqwwee.Rqqwq` today and would mean the constructor after the hoist. A statement binding a value
	 * is no candidate.
	 */
	@:pin('control')
	@:killer('M-HOIST-VALUES-BLIND')
	public function testRefusesAStatementBindingAConstructor(): Void {
		Assert.equals('', planned([
			{ name: 'src/qqz/Zqqwwee.hx', source: 'package qqz;\n\nenum Zqqwwee {\n\tRqqwq;\n}\n' },
			{ name: 'src/qqz/Kqqwwee.hx', source: 'package qqz;\n\nclass Kqqwwee {\n\n\tpublic static final Rqqwq: Int = 1;\n\n}\n' },
			carrying('OneQq', 'import qqz.Zqqwwee;', 'Zqqwwee'),
			carrying('TwoQq', 'import qqz.Zqqwwee;', 'Zqqwwee'),
			carrying('ThreeQq', 'import qqz.Zqqwwee;', 'Zqqwwee'),
			{
				name: 'src/aqq/FourQq.hx',
				source: 'package aqq;\n\nimport qqz.Kqqwwee.Rqqwq;\n\nclass FourQq {\n\n\tvar b: Int = Rqqwq;\n\n}\n'
			}
		]));
	}

	/**
	 * A `#if`-guarded statement decides a BUILD, so it cannot decide what a name means under a whole
	 * directory. Over-determined on purpose: the candidate filter refuses it, and so would the
	 * second-binder gate — which is why the arm for chain guardedness hangs on its own fixture below.
	 */
	@:pin('guard')
	public function testRefusesAGuardedStatement(): Void {
		Assert.equals('', planned(withStatement('#if js\nimport qqz.Zqqwwee;\n#end', 'Zqqwwee')));
	}

	/**
	 * A chain carrying ANY guarded statement withholds every verdict under it: one such statement makes
	 * name resolution in every governed module answer the union of two readings, and a position this
	 * rule adds to must not be one of them.
	 */
	@:pin('control')
	@:killer('M-HOIST-GUARDED-BLIND')
	public function testWithholdsWhereTheChainCarriesAGuardedStatement(): Void {
		Assert.equals('', planned(COMMON_TREE.concat([
			{ name: 'src/import.hx', source: '#if js\nimport aqq.Aqqwwee;\n#end\n' },
			{ name: 'src/aqq/Aqqwwee.hx', source: 'package aqq;\n\nclass Aqqwwee {}\n' }
		])));
	}

	/** A `using` off the allow-list stays where its author put it. */
	@:pin('guard')
	public function testRefusesAUsingOffTheAllowList(): Void {
		Assert.equals('', planned(usingTree('qqz.Rqqwwee', '')));
	}

	/** An allow-listed `using` moves, and opens its own block in the created source. */
	@:pin('control')
	@:killer('M-HOIST-NEVER-SOUND')
	public function testHoistsAnAllowListedUsing(): Void {
		Assert.equals('using qqz.Sqqwwee;|', hoisted(usingTree('qqz.Sqqwwee', '')));
	}

	/**
	 * A module where another `using` may take one of the hoisted one's accesses keeps its OWN statement: hoisting it would
	 * demote it below the rival, which declares the same method for the same receiver.
	 */
	@:pin('control')
	@:killer('M-HOIST-USING-DEMOTION')
	public function testKeepsAnAllowListedUsingWhereARivalRemains(): Void {
		final tree: Array<TreeFile> = usingTree('qqz.Sqqwwee', 'using qqz.Cqqwwee;\n', CALLS_TQQ).concat([
			{
				name: 'src/qqz/Cqqwwee.hx',
				source: 'package qqz;\n\nclass Cqqwwee {\n\n\tpublic static function tqq(s: String): String {\n\t\treturn s;\n\t}\n\n}\n'
			}
		]);
		Assert.equals('', planned(tree));
	}

	/** A rival `using` contesting no access of the module — it declares no method the hoisted one does — leaves it free to move. */
	@:pin('control')
	@:killer('M-USING-CONTEST-ANY')
	public function testHoistsAnAllowListedUsingPastARivalNoAccessContests(): Void {
		Assert.equals(HOISTED_PAST_RIVAL, planned(usingTree('qqz.Sqqwwee', 'using qqz.Rqqwwee;\n', CALLS_TQQ)));
	}

	/**
	 * A module whose call on a `@:forward` abstract both its `using` statements answer — through the abstract's underlying
	 * type — keeps its own: hoisting the winning one would demote it below the rival.
	 */
	@:pin('control')
	@:killer('M-USING-FORWARD-DECIDED')
	public function testKeepsAUsingWhoseForwardedAccessARivalAnswers(): Void {
		final extension: (String) -> String = type ->
			'package qqz;\n\nclass $type {\n\n\tpublic static function tqq(w: Wqqz): String {\n\t\treturn \'$type\';\n\t}\n\n}\n';
		final module: (String) -> TreeFile = name -> {
			name: 'src/aqq/$name.hx',
			source: 'package aqq;\n\nimport qqz.Fwqqz;\n\nusing qqz.Cqqwwee;\nusing qqz.Sqqwwee;\n\nclass $name {\n\n'
				+ '\tfunction f(x: Fwqqz): String {\n\t\treturn x.tqq();\n\t}\n\n}\n'
		};
		final tree: Array<TreeFile> = [
			{ name: 'apqlint.json', source: '{ "rules": { "hoist-common-import": { "usingAllowList": ["qqz.Sqqwwee"] } } }\n' },
			{ name: 'src/qqz/Wqqz.hx', source: 'package qqz;\n\nclass Wqqz {}\n' },
			{ name: 'src/qqz/Fwqqz.hx', source: 'package qqz;\n\n@:forward abstract Fwqqz(Wqqz) from Wqqz {}\n' },
			{ name: 'src/qqz/Sqqwwee.hx', source: extension('Sqqwwee') },
			{ name: 'src/qqz/Cqqwwee.hx', source: extension('Cqqwwee') },
			module('OneQq'),
			module('TwoQq'),
			module('ThreeQq'),
			{ name: 'src/aqq/FourQq.hx', source: 'package aqq;\n\nclass FourQq {}\n' }
		];
		Assert.isFalse(planned(tree).indexOf('qqz.Sqqwwee') >= 0);
	}

	/**
	 * Two hoisted usings keep their SOURCE order, which is their priority (Haxe ranks static extensions
	 * in reverse declaration order). The inserting seat puts each fresh `using` above the header's first
	 * one, so the rule inserts them last-first; inserted first-first they would come out reversed.
	 */
	@:pin('control')
	@:killer('M-HOIST-USINGS-SOURCE-ORDER')
	public function testHoistedUsingsKeepTheirSourceOrder(): Void {
		final tree: Array<TreeFile> = [
			for (file in usingTree('qqz.Sqqwwee', 'using qqz.Rqqwwee;\n'))
				file.name == 'apqlint.json' ? {
					name: file.name,
					source: '{ "rules": { "hoist-common-import": { "usingAllowList": ["qqz.Sqqwwee", "qqz.Rqqwwee"] } } }\n'
				} : file
		];
		Assert.equals('using qqz.Sqqwwee;|using qqz.Rqqwwee;|', hoisted(tree));
	}

	/** An ambient explicit import OUTRANKS a same-package type, so a namesake there is a retarget. */
	@:pin('control')
	@:killer('M-HOIST-RETARGET-BAND')
	public function testRefusesASamePackageNamesake(): Void {
		Assert.equals('', planned(COMMON_TREE.concat([{ name: 'src/aqq/Zqqwwee.hx', source: 'package aqq;\n\nclass Zqqwwee {}\n' }])));
	}

	/** And a ROOT-package type, which is what a language's own top-level std types are. */
	@:pin('control')
	@:killer('M-HOIST-RETARGET-BAND')
	public function testRefusesARootPackageNamesake(): Void {
		Assert.equals('', planned(COMMON_TREE.concat([{ name: 'src/Zqqwwee.hx', source: 'class Zqqwwee {}\n' }])));
	}

	/** And a type a governed module reaches through its own PACKAGE wildcard. */
	@:pin('control')
	@:killer('M-HOIST-RETARGET-BAND')
	public function testRefusesANamesakeReachedByAWildcard(): Void {
		Assert.equals('', planned(COMMON_TREE.concat([
			{ name: 'src/wqq/Zqqwwee.hx', source: 'package wqq;\n\nclass Zqqwwee {}\n' },
			{ name: 'src/aqq/FiveQq.hx', source: 'package aqq;\n\nimport wqq.*;\n\nclass FiveQq {\n\n\tvar a: Zqqwwee;\n\n}\n' }
		])));
	}

	/**
	 * A namesake is a retarget only for the modules one of their bands carries it to, so a widest
	 * position governing the namesake's own package is refused while the nested one below it is not —
	 * the gate is per band and per module, never per name.
	 */
	@:pin('guard')
	public function testANamesakePushesTheStatementToADeeperSite(): Void {
		Assert.equals(
			'src/aqq/OneQq.hx:qqz.Zqqwwee@src/aqq/import.hx,src/aqq/ThreeQq.hx:qqz.Zqqwwee@src/aqq/import.hx,'
			+ 'src/aqq/TwoQq.hx:qqz.Zqqwwee@src/aqq/import.hx',
			planned(COMMON_TREE.concat([{ name: 'src/fqq/Zqqwwee.hx', source: 'package fqq;\n\nclass Zqqwwee {}\n' }]))
		);
	}

	/**
	 * A statement naming a MODULE binds every type that module declares, so a SIBLING of the imported
	 * type with a namesake a governed module can see is the same retarget as one on the leaf — and it
	 * is the one nobody would look at, since no module in the directory ever named it.
	 */
	@:pin('control')
	@:killer('M-IMPORT-LEAF-ONLY-NAMES')
	public function testRefusesAModuleImportWhoseSiblingHasANamesake(): Void {
		Assert.equals('', planned(SIBLING_TREE));
	}

	/** A path naming ONE type inside a module brings only that type, so a sibling's namesake is irrelevant to it. */
	@:pin('control')
	@:killer('M-HOIST-NEVER-SOUND')
	public function testASubTypeImportIgnoresItsSiblings(): Void {
		Assert.equals(
			'src/bqq/MqqOne.hx:aqq.Modqqw.Subqqw@src/import.hx,src/bqq/MqqThree.hx:aqq.Modqqw.Subqqw@src/import.hx,'
			+ 'src/bqq/MqqTwo.hx:aqq.Modqqw.Subqqw@src/import.hx',
			planned(SIBLING_TREE.map(entry -> entry.name.startsWith('src/bqq/Mqq') ? {
				name: entry.name,
				source: entry.source.split('import aqq.Modqqw;')
					.join('import aqq.Modqqw.Subqqw;')
					.split('Modqqw.who()')
					.join('Subqqw.who()')
			} : entry))
		);
	}

	/**
	 * A static-FIELD import binds no type, and a path naming a type the index never sees binds at most that one name,
	 * even inside a module no file declares: neither is a second binder of a statement it shares a module with nothing of.
	 */
	@:pin('control')
	@:killer('M-IMPORT-MODULE-TAIL-UNKNOWN')
	public function testAFieldOrUnseenSubTypeImportIsNoSecondBinder(): Void {
		final kqq: TreeFile = {
			name: 'src/qqz/Kqqwwee.hx',
			source: 'package qqz;\n\nclass Kqqwwee {\n\n\tpublic static function hqq(): Int {\n\t\treturn 1;\n\t}\n\n}\n'
		};
		Assert.equals(
			'src/aqq/OneQq.hx:qqz.Zqqwwee@src/import.hx,src/aqq/ThreeQq.hx:qqz.Zqqwwee@src/import.hx,'
			+ 'src/aqq/TwoQq.hx:qqz.Zqqwwee@src/import.hx',
			planned(COMMON_TREE.map(entry -> switch entry.name {
				case 'src/aqq/OneQq.hx': {
					name: entry.name,
					source: entry.source.replace('import qqz.Zqqwwee;', 'import qqz.Kqqwwee.hqq;\nimport qqz.Zqqwwee;')
				};
				case 'src/aqq/TwoQq.hx': {
					name: entry.name,
					source: entry.source.replace('import qqz.Zqqwwee;', 'import qqz.Kqqwwee.Gqqwwee;\nimport qqz.Zqqwwee;')
				};
				case 'src/aqq/ThreeQq.hx': {
					name: entry.name,
					source: entry.source.replace('import qqz.Zqqwwee;', 'import qqz.Pqqwwee.Hqqwwee;\nimport qqz.Zqqwwee;')
				};
				case _: entry;
			}).concat([kqq]))
		);
	}

	/**
	 * A statement whose module comes from ANOTHER classpath entry, a library, reaches `FourQq`, which holds nothing from that
	 * entry — and a build compiling `FourQq` without the library would stop on the ambient source. Withheld.
	 */
	@:pin('control')
	@:killer('M-HOIST-RECEIVER-UNVOUCHED')
	public function testWithholdsAStatementAReceiverMayNotResolve(): Void {
		Assert.equals('', planned(COMMON_TREE.filter(entry -> entry.name.startsWith('src/aqq/')), LIBRARY_FILES));
	}

	/**
	 * A receiver that already compiles with the library's entry and package vouches for the statement it receives — and the site
	 * holding every module only through its one child is weighed before that child, so the chain carries the statement once.
	 */
	@:pin('control')
	@:killer('M-HOIST-RECEIVER-EVIDENCE-BLIND')
	@:killer('M-HOIST-TIE-NEAREST-FIRST')
	public function testAReceiverAlreadyCompilingTheEntryVouchesForIt(): Void {
		Assert.equals(
			'src/aqq/OneQq.hx:qqz.Zqqwwee@src/import.hx,src/aqq/ThreeQq.hx:qqz.Zqqwwee@src/import.hx,'
			+ 'src/aqq/TwoQq.hx:qqz.Zqqwwee@src/import.hx',
			planned(
				COMMON_TREE.filter(entry -> entry.name.startsWith('src/aqq/')).map(entry -> entry.name == 'src/aqq/FourQq.hx' ? {
					name: entry.name,
					source: 'package aqq;\n\nimport qqz.Yqqwwee;\n\nclass FourQq {\n\n\tvar b: Yqqwwee;\n\n}\n'
				} : entry),
				LIBRARY_FILES
			)
		);
	}

	@:pin('control')
	@:killer('M-HOIST-BUILDS-UNASKED')
	public function testEveryBuildParsingTheStatementVouchesForEveryReceiver(): Void {
		// FourQq spells nothing of the library, but the one build that reads it reads the statement's module as well
		Assert.equals(
			'src/aqq/OneQq.hx:qqz.Zqqwwee@src/import.hx,src/aqq/ThreeQq.hx:qqz.Zqqwwee@src/import.hx,'
			+ 'src/aqq/TwoQq.hx:qqz.Zqqwwee@src/import.hx',
			planned(aqqTree(), LIBRARY_FILES, [AQQ_MODULES.concat([LIBRARY_FILES[0].file])])
		);
	}

	@:pin('control')
	@:killer('M-HOIST-BUILD-WITHOUT-MODULE-IGNORED')
	public function testABuildParsingAReceiverButNotTheStatementWithholdsIt(): Void {
		// FourQq's own statement resolves under the statement's classpath entry, which vouches for nothing the statement's
		// module imports in turn: the second build reads FourQq and that entry, never the statement's module
		final tree: Array<TreeFile> = aqqTree().map(entry -> entry.name == 'src/aqq/FourQq.hx' ? {
			name: entry.name,
			source: 'package aqq;\n\nimport qqz.Yqqwwee;\n\nclass FourQq {\n\n\tvar b: Yqqwwee;\n\n}\n'
		} : entry);
		Assert.equals('', planned(tree, LIBRARY_FILES, [
			AQQ_MODULES.concat([LIBRARY_FILES[0].file]),
			['src/aqq/FourQq.hx', LIBRARY_FILES[1].file]
		]));
	}

	@:pin('control')
	@:killer('M-HOIST-UNPARSED-RECEIVER-WITHHELD')
	public function testAReceiverNoBuildParsesLosesNothing(): Void {
		// the builds are declared to be all of the project's, and none of them reads FourQq
		Assert.equals(
			'src/aqq/OneQq.hx:qqz.Zqqwwee@src/import.hx,src/aqq/ThreeQq.hx:qqz.Zqqwwee@src/import.hx,'
			+ 'src/aqq/TwoQq.hx:qqz.Zqqwwee@src/import.hx',
			planned(
				aqqTree(), LIBRARY_FILES,
				[
					AQQ_MODULES.filter(name -> name != 'src/aqq/FourQq.hx').concat([LIBRARY_FILES[0].file])
				]
			)
		);
	}

	/** The language's implicit tier reaches every module without a statement, so its entry and package vouch for every receiver. */
	@:pin('control')
	@:killer('M-HOIST-IMPLICIT-TIER-BLIND')
	public function testTheImplicitTierVouchesForEveryReceiver(): Void {
		final std: Null<String> = StdResolver.stdDir();
		if (std == null) {
			Assert.pass();
			return;
		}
		final head: String = 'package aqq;\n\nusing StringTools;\n';
		Assert.equals(
			'src/aqq/OneQq.hx:StringTools@src/import.hx,src/aqq/ThreeQq.hx:StringTools@src/import.hx,'
			+ 'src/aqq/TwoQq.hx:StringTools@src/import.hx',
			planned([
				{ name: 'src/aqq/OneQq.hx', source: '$head\nclass OneQq {}\n' },
				{ name: 'src/aqq/TwoQq.hx', source: '$head\nclass TwoQq {}\n' },
				{ name: 'src/aqq/ThreeQq.hx', source: '$head\nclass ThreeQq {}\n' },
				{ name: 'src/aqq/FourQq.hx', source: 'package aqq;\n\nclass FourQq {}\n' }
			], [{ file: Path.join([std, 'StdTypes.hx']), source: 'abstract Voidqq {}\n' }])
		);
	}

	/** A second run over the tree the fix produced has nothing left to do. */
	@:pin('guard')
	public function testASecondRunHasNothingToDo(): Void {
		Assert.equals('', planned(applied(COMMON_TREE)));
	}

	/**
	 * A module whose directory contradicts its package has a chain nobody can bound, so no verdict is made
	 * under it. It spells the statement itself, so it is no receiver the availability gate would withhold for.
	 */
	@:pin('control')
	@:killer('M-HOIST-SHORT-CHAIN')
	public function testWithholdsOnAnUnboundedChain(): Void {
		Assert.equals('', planned(COMMON_TREE.concat([
			{ name: 'src/aqq/StrayQq.hx', source: 'package wrongqq;\n\nimport qqz.Zqqwwee;\n\nclass StrayQq {\n\n\tvar a: Zqqwwee;\n\n}\n' }
		])));
	}

	/** A directory with fewer modules than the minimum has no share worth reading. */
	@:pin('control')
	@:killer('M-HOIST-MIN-MODULES')
	public function testWithholdsBelowTheMinimumModuleCount(): Void {
		Assert.equals('', planned([
			{ name: 'src/qqz/Zqqwwee.hx', source: 'package qqz;\n\nclass Zqqwwee {}\n' },
			{ name: 'src/aqq/OneQq.hx', source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass OneQq {\n\n\tvar a: Zqqwwee;\n\n}\n' }
		]));
	}

	/** A statement the chain above the directory already provides binds nothing new there. */
	@:pin('guard')
	public function testDoesNotProposeWhatTheChainAlreadyProvides(): Void {
		Assert.equals('', planned(COMMON_TREE.concat([{ name: 'src/import.hx', source: 'import qqz.Zqqwwee;\n' }])));
	}

	/** A NESTED position takes only what its parents did not, so no statement lands in two sources of one chain. */
	@:pin('control')
	@:killer('M-HOIST-SITE-ORDER')
	@:killer('M-HOIST-CHAIN-INHERITED')
	public function testANestedSiteTakesOnlyWhatItsParentDidNot(): Void {
		Assert.equals('src/import.hx=import qqz.Zqqwwee;| :: src/aqq/import.hx=import qqz.Yqqwwee;|', hoistedSites(NESTED_TREE));
	}

	/** An existing ambient source keeps its own statements and takes the new one in its ordered place. */
	@:pin('control')
	@:killer('M-HOIST-NEVER-SOUND')
	public function testExtendsAnExistingAmbientSource(): Void {
		Assert.equals('import aqq.Aqqwwee;|import qqz.Zqqwwee;|', hoisted(COMMON_TREE.concat([
			{ name: 'src/import.hx', source: 'import aqq.Aqqwwee;\n' },
			{ name: 'src/aqq/Aqqwwee.hx', source: 'package aqq;\n\nclass Aqqwwee {}\n' }
		])));
	}

	/** The statement is CREATED as a whole file when no source is there — the half no edit list can express. */
	@:pin('guard')
	public function testCreatesTheAmbientSourceAsAWholeFile(): Void {
		Assert.equals('create', slicesOf(COMMON_TREE).head);
	}

	/** Extending an existing source is an EDIT, not a create — the opposite refusal of the same seat. */
	@:pin('guard')
	public function testExtendingAnExistingSourceIsAnEdit(): Void {
		Assert.equals(
			'edit', slicesOf(COMMON_TREE.concat([
				{ name: 'src/import.hx', source: 'import aqq.Aqqwwee;\n' },
				{ name: 'src/aqq/Aqqwwee.hx', source: 'package aqq;\n\nclass Aqqwwee {}\n' }
			])).head
		);
	}

	/** One slice per SITE, so a created source and every removal it makes commit together or not at all. */
	@:pin('guard')
	public function testOneSlicePerSite(): Void {
		Assert.equals(2, slicesOf(NESTED_TREE).groups);
	}

	/** A statement fewer than the sink share of its source's modules read is reported on the source itself. */
	@:pin('control')
	@:killer('M-SINK-NEVER-SOUND')
	public function testSinksAStatementTooFewModulesRead(): Void {
		Assert.equals('src/aqq/import.hx:qqz.Rqqwwee', sunk(SINK_TREE));
	}

	/** Two readers of five is a share at the sink threshold's other side: the statement stays where it is. */
	@:pin('control')
	@:killer('M-SINK-SHARE-BLIND')
	public function testKeepsAStatementEnoughModulesRead(): Void {
		Assert.equals(
			'', sunk(SINK_TREE.map(entry -> entry.name == 'src/aqq/TwoQq.hx' ? {
				name: entry.name,
				source: 'package aqq;\n\nclass TwoQq {\n\n\tvar a:Rqqwwee;\n\n}\n'
			} : entry))
		);
	}

	/** A sink threshold at or above the hoist one would put one share on both sides, so it is not honoured. */
	@:pin('control')
	@:killer('M-SINK-HYSTERESIS-OFF')
	public function testASinkThresholdNotBelowTheHoistOneIsIgnored(): Void {
		Assert.equals('', sunk(SINK_TREE.concat([
			{ name: 'apqlint.json', source: '{ "rules": { "hoist-common-import": { "threshold": 50, "sinkThreshold": 50 } } }\n' }
		])));
	}

	/** The fix spells the statement in its one reader and deletes the source it leaves with nothing in it. */
	@:pin('control')
	@:killer('M-SINK-NEVER-SOUND')
	public function testTheSinkDeletesTheSourceItEmpties(): Void {
		Assert.equals(
			'GONE :: package aqq;||import qqz.Rqqwwee;||class OneQq {||\tvar a:Rqqwwee;||}|',
			'${fileAfter(SINK_TREE, 'src/aqq/import.hx')} :: ${fileAfter(SINK_TREE, 'src/aqq/OneQq.hx')}'
		);
	}

	/** A source keeping another statement, or a comment, is EDITED: deleting it would take them along. */
	@:pin('guard')
	public function testTheSinkKeepsASourceThatCarriesMore(): Void {
		final commented: Array<TreeFile> = SINK_TREE.map(entry -> entry.name == 'src/aqq/import.hx' ? {
			name: entry.name,
			source: '// shared\nimport qqz.Rqqwwee;\n'
		} : entry);
		Assert.equals('// shared||', fileAfter(commented, 'src/aqq/import.hx'));
	}

	/**
	 * A NEARER source binding the same name to another type is what the reader reads, and the own copy a
	 * sink writes would outrank it — `OneQq`'s `Rqqwwee` would turn from `wqq`'s into `qqz`'s. Refused.
	 */
	@:pin('control')
	@:killer('M-SINK-RIVAL-BLIND')
	public function testRefusesASinkWhereANearerSourceBindsTheName(): Void {
		Assert.equals('', sunk([
			for (entry in SINK_TREE) entry.name == 'src/aqq/OneQq.hx' ? {
				name: 'src/aqq/bqq/OneQq.hx',
				source: 'package aqq.bqq;\n\nclass OneQq {\n\n\tvar a:Rqqwwee;\n\n}\n'
			} : entry
		].concat([
			{ name: 'src/wqq/Rqqwwee.hx', source: 'package wqq;\n\nclass Rqqwwee {}\n' },
			{ name: 'src/aqq/bqq/import.hx', source: 'import wqq.Rqqwwee;\n' }
		])));
	}

	/** An OWN rival import of the name is refused the same way: the own copy sorts after it and the last one wins. */
	@:pin('control')
	@:killer('M-SINK-OWN-RIVAL-BLIND')
	public function testRefusesASinkWhereTheReaderImportsARival(): Void {
		Assert.equals(
			'',
			sunk(
				SINK_TREE.map(entry -> entry.name == 'src/aqq/OneQq.hx' ? {
					name: entry.name,
					source: 'package aqq;\n\nimport eqq.Rqqwwee;\n\nclass OneQq {\n\n\tvar a:Rqqwwee;\n\n}\n'
				} : entry)
					.concat([{ name: 'src/eqq/Rqqwwee.hx', source: 'package eqq;\n\nclass Rqqwwee {}\n' }])
			)
		);
	}

	/** A sunk `using` lands ABOVE the reader's own ones — the lowest extension priority, the rank it held in the source. */
	@:pin('guard')
	public function testASunkUsingKeepsItsRankBelowTheReadersOwn(): Void {
		Assert.equals(
			'package aqq;||using qqz.Sqqwwee;|using qqz.Rqqwwee;||class OneQq {||\tfunction f(s:String):String {|'
			+ '\t\treturn s.tqq();|\t}||}|',
			fileAfter(usingSinkTree(''), 'src/aqq/OneQq.hx')
		);
	}

	/**
	 * Another `using` in the reader's chain that offers one of the sunk one's accesses would rank BELOW the own copy a sink
	 * writes. Refused.
	 */
	@:pin('control')
	@:killer('M-SINK-USING-RANK-BLIND')
	public function testRefusesAUsingSinkWhereTheChainCarriesAnotherUsing(): Void {
		Assert.equals('', sunk(usingSinkTree('using qqz.Cqqwwee;\n')));
	}

	/** A `using` in the reader's chain contesting none of the sunk one's accesses takes nothing from it: the sink goes ahead. */
	@:pin('control')
	@:killer('M-USING-CONTEST-ANY')
	public function testSinksAUsingPastAChainRivalNoAccessContests(): Void {
		Assert.equals(sunk(usingSinkTree('')), sunk(usingSinkTree('using qqz.Pqqwwee;\n')));
		Assert.notEquals('', sunk(usingSinkTree('using qqz.Pqqwwee;\n')));
	}

	/**
	 * A fix run over both directions leaves a tree the next run has nothing to do on: a share between the two
	 * thresholds stays wherever it is, and a sink threshold at or above the hoist one, which would send a
	 * hoisted statement straight back, is not honoured.
	 */
	@:pin('control')
	@:killer('M-SINK-HYSTERESIS-OFF')
	public function testAFixedTreeIsAFixedPointOfBothDirections(): Void {
		#if (sys || nodejs)
		final tree: Array<TreeFile> = [
			for (entry in COMMON_TREE) { name: entry.name, source: entry.source.replace('a: ', 'a:') }
		];
		final verdicts: Array<String> = [];
		for (config in ['{}', '{ "rules": { "hoist-common-import": { "sinkThreshold": 70 } } }']) {
			final root: String = CliFixture.writeTree('apq_hoist_fixpoint', tree);
			CliFixture.always(CliFixture.removeDir.bind(root), () -> {
				fixOnDisk(root, config);
				final first: String = diskOf(root);
				fixOnDisk(root, config);
				verdicts.push('${sys.FileSystem.exists('$root/src/import.hx')}|${first == diskOf(root)}');
			});
		}
		Assert.equals('true|true,true|true', verdicts.join(','));
		#else
		Assert.pass();
		#end
	}

	/**
	 * A sink and a cross-file rename of ANOTHER rule landing in one reader in the same pass both reach it: the
	 * reader's edits from the two are merged into one set, so the sink's must be the insertion alone — a
	 * whole-file rewrite would swallow the rename and leave `OneQq` reading a member that is gone.
	 */
	@:pin('control')
	@:killer('M-SINK-WHOLE-FILE')
	public function testASinkAndARenameInOneReaderBothLand(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree(
			'apq_hoist_sink_rename',
			SINK_TREE.map(entry -> switch entry.name {
				case 'src/aqq/OneQq.hx': {
					name: entry.name,
					source: 'package aqq;\n\nclass OneQq extends qqz.Base {\n\n\tfunction f():Int {\n\t\treturn shape;\n\t}\n\n'
						+ '\tvar a:Rqqwwee;\n\n}\n'
				};
				case _: entry;
			})
				.concat([
					{ name: 'src/qqz/Base.hx', source: 'package qqz;\n\nclass Base {\n\n\tprivate var shape:Int = 0;\n\n}\n' }
				])
		);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			fixOnDisk(root, '{}', [new Naming(), new HoistCommonImport()]);
			final reader: String = sys.io.File.getContent('$root/src/aqq/OneQq.hx');
			out = '${reader.indexOf('import qqz.Rqqwwee;') >= 0}|${reader.indexOf('return _shape;') >= 0}'
				+ '|${sys.io.File.getContent('$root/src/qqz/Base.hx').indexOf('_shape') >= 0}';
		});
		Assert.equals('true|true|true', out);
		#else
		Assert.pass();
		#end
	}

	/** `tree` with this rule's own fix applied — the ambient sources it writes, and the modules without what it lifted. */
	private function applied(tree: Array<TreeFile>): Array<TreeFile> {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_hoist_applied', tree);
		var out: Array<TreeFile> = tree;
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final byName: Map<String, String> = [];
			for (entry in tree) byName[entry.name] = entry.source;
			for (slice in fixOf(tree, root)) for (part in slice) {
				final name: String = relative(part.file, root);
				final created: Null<String> = part.create;
				if (created != null) {
					byName[name] = created;
					continue;
				}
				if (part.remove == true) {
					byName.remove(name);
					continue;
				}
				var source: String = byName[name] ?? '';
				for (edit in part.edits) source = source.substring(0, edit.span.from) + edit.text + source.substr(edit.span.to);
				byName[name] = source;
			}
			out = [for (name => source in byName) { name: name, source: source }];
		});
		return out;
		#else
		return tree;
		#end
	}

	/**
	 * Every finding over `tree` as `<module>:<path>@<site>`, tree-relative and SORTED — the governed
	 * order is a directory listing's, which is the filesystem's to decide.
	 */
	private function planned(
		tree: Array<TreeFile>, ?libraries: Array<{ file: String, source: String }>, ?parsing: Array<Array<String>>
	): String {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_hoist_plan', tree);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final rendered: Array<String> = [
				for (v in reportOf(
					tree, root, libraries, parsing
				)) '${relative(v.file, root)}:${quoted(v.message, 0)}@${relative(quoted(v.message, 1), root)}'
			];
			rendered.sort((a, b) -> if (a < b)
				-1
			else if (a > b)
				1
			else
				0);
			out = rendered.join(',');
		});
		return out;
		#else
		return '';
		#end
	}

	/** Every SINK finding over `tree` as `<source>:<path>`, tree-relative and sorted — the findings that land on an ambient source. */
	private function sunk(tree: Array<TreeFile>): String {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_hoist_sink', tree);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final rendered: Array<String> = [
				for (v in reportOf(
					tree, root
				)) if (v.message.indexOf(' is read by ') >= 0) '${relative(v.file, root)}:${quoted(v.message, 0)}'
			];
			rendered.sort((a, b) -> if (a < b)
				-1
			else if (a > b)
				1
			else
				0);
			out = rendered.join(',');
		});
		return out;
		#else
		return '';
		#end
	}

	/** `name`'s text once this rule's fix is applied to `tree`, each newline as `|` — or `GONE` when the fix deleted it. */
	private function fileAfter(tree: Array<TreeFile>, name: String): String {
		final entry: Null<TreeFile> = applied(tree).find(file -> file.name == name);
		return entry == null ? 'GONE' : entry.source.replace('\n', '|');
	}

	/** The ambient source text the FIRST slice writes, with each newline as `|`. */
	private function hoisted(tree: Array<TreeFile>): String {
		final sites: String = hoistedSites(tree);
		final first: Int = sites.indexOf(SITE_SEPARATOR);
		final one: String = first < 0 ? sites : sites.substring(0, first);
		final at: Int = one.indexOf('=');
		return at < 0 ? one : one.substr(at + 1);
	}

	/** Every slice as `<site>=<ambient source text with | for each newline>`, joined in plan order. */
	private function hoistedSites(tree: Array<TreeFile>): String {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_hoist_fix', tree);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			out = [
				for (slice in fixOf(tree, root)) '${relative(slice[0].file, root)}=${textOf(slice[0], tree, root).replace('\n', '|')}'
			].join(SITE_SEPARATOR);
		});
		return out;
		#else
		return '';
		#end
	}

	/** Whether the first slice CREATES or EDITS its ambient source, and how many slices there are. */
	private function slicesOf(tree: Array<TreeFile>): { head: String, groups: Int } {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_hoist_slices', tree);
		var out: { head: String, groups: Int } = {
			head: '',
			groups: 0
		};
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final slices: Array<Array<CrossFileEdits>> = fixOf(tree, root);
			out = {
				head: slices.length == 0 ? '' : slices[0][0].create != null ? 'create' : 'edit',
				groups: slices.length
			};
		});
		return out;
		#else
		return {
			head: '',
			groups: 0
		};
		#end
	}

	/**
	 * The rule's report over the whole tree written under `root` — under the run's `parsing` builds when given, each the files it
	 * parses, tree-relative or absolute.
	 */
	private function reportOf(
		tree: Array<TreeFile>, root: String, ?libraries: Array<{ file: String, source: String }>, ?parsing: Array<Array<String>>
	): Array<Violation> {
		final files: Array<{ file: String, source: String }> = analysed(tree, root);
		return libraries == null
			? CheckFixture.violationsIn(new HoistCommonImport(), files)
			: CheckFixture.violationsIn(new HoistCommonImport(), files, StdScope.plugin(files, libraries, true, buildsOf(root, parsing)));
	}

	/** The rule's cross-file fix over the whole tree written under `root`, justified by its own report. */
	private function fixOf(tree: Array<TreeFile>, root: String): Array<Array<CrossFileEdits>> {
		final files: Array<{ file: String, source: String }> = analysed(tree, root);
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final rule: HoistCommonImport = new HoistCommonImport();
		return rule.crossFileFix(files, CheckFixture.violationsIn(rule, files, plugin), plugin);
	}

	/** `path` without the fixture root prefix. */
	private static inline function relative(path: String, root: String): String {
		return path.startsWith('$root/') ? path.substr(root.length + 1) : path;
	}

	/** One build per entry of `parsing`, parsing exactly the files it names (resolved under `root`); null without `parsing`. */
	private static function buildsOf(root: String, parsing: Null<Array<Array<String>>>): Null<ReachBuilds> {
		if (parsing == null) return null;
		final cwd: String = Sys.getCwd();
		return {
			configurations: [
				for (i => names in parsing)
					{
						name: 'build$i',
						defined: [],
						everDefined: [],
						values: [],
						compiled: [],
						types: [],
						parsed: [
							for (name in names) OracleCoverage.canonical(cwd, name.startsWith('/') ? name : '$root/$name')
						]
					}
			],
			library: []
		};
	}

	/** The head slice's resulting ambient source text — its `create`, or its edit applied to the existing source. */
	private static function textOf(slice: CrossFileEdits, tree: Array<TreeFile>, root: String): String {
		final created: Null<String> = slice.create;
		if (created != null) return created;
		final name: String = relative(slice.file, root);
		final existing: String = tree.find(entry -> entry.name == name)?.source ?? '';
		final edit: { span: Span, text: String } = slice.edits[0];
		return existing.substring(0, edit.span.from) + edit.text + existing.substr(edit.span.to);
	}

	/** Every `.hx` of `tree` as the run's file set — an ambient source included, the way a whole-tree lint sees one. */
	private static function analysed(tree: Array<TreeFile>, root: String): Array<{ file: String, source: String }> {
		return [
			for (entry in tree) if (entry.name.endsWith('.hx')) { file: '$root/${entry.name}', source: entry.source }
		];
	}

	/** The `n`-th single-quoted SPAN of `message` — quotes come in pairs, so its opening one is at twice the index. */
	private static function quoted(message: String, n: Int): String {
		var at: Int = -1;
		for (_ in 0...2 * n + 1) {
			at = message.indexOf('\'', at + 1);
			if (at < 0) return message;
		}
		final close: Int = message.indexOf('\'', at + 1);
		return close < 0 ? message : message.substring(at + 1, close);
	}

	/** Three of four modules of one package carrying `statement`, which binds `name`. */
	private static function withStatement(statement: String, name: String): Array<TreeFile> {
		return [
			{ name: 'src/qqz/Zqqwwee.hx', source: 'package qqz;\n\nclass Zqqwwee {}\n' },
			carrying('OneQq', statement, name),
			carrying('TwoQq', statement, name),
			carrying('ThreeQq', statement, name),
			{ name: 'src/aqq/FourQq.hx', source: 'package aqq;\n\nclass FourQq {}\n' }
		];
	}

	/** One module of `aqq` carrying `statement` and reading `name`. */
	private static function carrying(module: String, statement: String, name: String): TreeFile {
		return {
			name: 'src/aqq/$module.hx',
			source: 'package aqq;\n\n$statement\n\nclass $module {\n\n\tvar a: $name;\n\n}\n'
		};
	}

	/**
	 * Three of six modules carrying `using <path>;` plus `extra` and the class body `body`, with `path` on the
	 * allow-list this fixture's own `apqlint.json` declares — a `using` of a local module, since a direct run
	 * resolves no library.
	 */
	private static function usingTree(path: String, extra: String, body: String = ''): Array<TreeFile> {
		final head: String = 'package aqq;\n\nusing $path;\n$extra';
		return [
			{ name: 'apqlint.json', source: '{ "rules": { "hoist-common-import": { "usingAllowList": ["qqz.Sqqwwee"] } } }\n' },
			{
				name: 'src/qqz/Sqqwwee.hx',
				source: 'package qqz;\n\nclass Sqqwwee {\n\n\tpublic static function tqq(s: String): String {\n\t\treturn s;\n\t}\n\n}\n'
			},
			{
				name: 'src/qqz/Rqqwwee.hx',
				source: 'package qqz;\n\nclass Rqqwwee {\n\n\tpublic static function uqq(s: String): String {\n\t\treturn s;\n\t}\n\n}\n'
			},
			{ name: 'src/aqq/OneQq.hx', source: '$head\nclass OneQq {$body}\n' },
			{ name: 'src/aqq/TwoQq.hx', source: '$head\nclass TwoQq {$body}\n' },
			{ name: 'src/aqq/ThreeQq.hx', source: '$head\nclass ThreeQq {$body}\n' },
			{ name: 'src/aqq/FourQq.hx', source: 'package aqq;\n\nclass FourQq {}\n' }
		];
	}

	/**
	 * An ambient `using qqz.Sqqwwee;` that one of five modules calls — `OneQq`, which keeps a `using` of its
	 * own — with `parent` as the text of an ambient source one directory up when it is not empty. Both
	 * `using` modules a source carries are on this fixture's allow-list.
	 */
	private static function usingSinkTree(parent: String): Array<TreeFile> {
		final extension: (
			String, String
		) -> String = (type, method) ->
			'package qqz;\n\nclass $type {\n\n\tpublic static function $method(s:String):String {\n\t\treturn s;\n\t}\n\n}\n';
		final tree: Array<TreeFile> = [
			{
				name: 'apqlint.json',
				source: '{ "rules": { "hoist-common-import": { "usingAllowList": ["qqz.Sqqwwee", "qqz.Pqqwwee"] } } }\n'
			},
			{ name: 'src/qqz/Sqqwwee.hx', source: extension('Sqqwwee', 'tqq') },
			{ name: 'src/qqz/Rqqwwee.hx', source: extension('Rqqwwee', 'uqq') },
			{ name: 'src/qqz/Pqqwwee.hx', source: extension('Pqqwwee', 'vqq') },
			{ name: 'src/qqz/Cqqwwee.hx', source: extension('Cqqwwee', 'tqq') },
			{ name: 'src/aqq/import.hx', source: 'using qqz.Sqqwwee;\n' },
			{
				name: 'src/aqq/OneQq.hx',
				source: 'package aqq;\n\nusing qqz.Rqqwwee;\n\nclass OneQq {\n\n\tfunction f(s:String):String {\n\t\treturn s.tqq();\n'
					+ '\t}\n\n}\n'
			}
		].concat([
			for (module in ['TwoQq', 'ThreeQq', 'FourQq', 'FiveQq'])
				{
					name: 'src/aqq/$module.hx',
					source: 'package aqq;\n\nclass $module {}\n'
				}
		]);
		return parent == '' ? tree : tree.concat([{ name: 'src/import.hx', source: parent }]);
	}

	/** `COMMON_TREE`'s `aqq` package alone: three modules spelling a library import, a fourth spelling none. */
	private static function aqqTree(): Array<TreeFile> {
		return COMMON_TREE.filter(entry -> entry.name.startsWith('src/aqq/'));
	}

	#if (sys || nodejs)
	/** One `lint --fix` over every `.hx` under `root`, by both import-moving directions and the two rules that clean up after them. */
	private static function fixOnDisk(root: String, config: String, ?checks: Array<Check>): Void {
		final files: Array<{ file: String, source: String }> = [
			for (path in modulesUnder(root)) { file: path, source: sys.io.File.getContent(path) }
		];
		CliFixture.captureStderr(() ->
			LintFixDriver.runLintFix(
				files, checks ?? [new HoistCommonImport(), new UnusedImport(), new EmptyAmbientSource()], new HaxeQueryPlugin(),
				_ -> LintConfig.parse(config), false, null, [], true, null, false
			)
		);
	}

	/** Every `.hx` file under `dir` with its text, sorted by path — the tree as a fix left it on disk. */
	private static function diskOf(dir: String): String {
		return [for (path in modulesUnder(dir)) '$path=${sys.io.File.getContent(path)}'].join('\n');
	}

	/** Every `.hx` path under `dir`, sorted. */
	private static function modulesUnder(dir: String): Array<String> {
		final out: Array<String> = [];
		for (name in sys.FileSystem.readDirectory(dir)) {
			final path: String = '$dir/$name';
			if (sys.FileSystem.isDirectory(path))
				for (inner in modulesUnder(path)) out.push(inner)
			else if (name.endsWith('.hx'))
				out.push(path);
		}
		out.sort((a, b) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		return out;
	}
	#end

}
