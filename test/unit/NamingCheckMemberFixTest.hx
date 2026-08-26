package unit;

import anyparse.check.Check.Violation;
import anyparse.check.Naming;
import anyparse.check.UnusedPrivate;
import anyparse.grammar.haxe.HaxeNamingSupport;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;

using StringTools;

/**
 * The `naming` autofix on a class-level DECLARATION — a private field, a private
 * method, a `static final` constant, a property-backed field — where the rename is
 * only safe once the declaration is proved CONFINED to the sources the check can
 * see.
 *
 * Covered here: what confinement requires (no subclass, no `@:access` grant, no
 * `@:allow`, no skip-parsing file in the index, no RTTI class) and what a
 * confinement proof must still survive: a foreign-receiver access, an
 * own-type-receiver access, a comment or string-literal mention, a name collision,
 * an unattributable occurrence, a parameter capture. The reflection guard — which
 * `Reflect.*` field-name arguments count as a reference to the member — is here
 * too, including the on-disk cross-file fixtures behind `#if (sys || nodejs)`.
 *
 * The CROSS-FILE staging of such a rename lives in `NamingCheckCrossFileFixTest`.
 */
class NamingCheckMemberFixTest extends NamingCheckTestBase {

	public function testFixSkipsPrivateField(): Void {
		// A private field is cross-file-reachable (subclass / @:access) — report-only, no rename edit.
		final src: String = 'class C {\n\tprivate var BadField:Int;\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixSkipsType(): Void {
		// A type is cross-file-reachable — report-only, no rename edit.
		final src: String = 'class foo {}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixRenamesConfinedPrivateField(): Void {
		// A private field confined to its file (no subtype / @:access / @:allow), all references resolved → renamed.
		final src: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		assertFixCanonicalWithIndex(src, '_shape', 'var shape');
	}

	/**
	 * The completeness gate DISCOUNTS type references to the member's name — an occurrence that is
	 * neither a renamed reference nor a proven non-reference vetoes the whole rename. An annotation
	 * inside an anonymous structure lives only in the type-ref projection, which dropped the struct
	 * whole, so `Array<{node:Thing}>` read as an unattributable reference and refused the rename.
	 */
	public function testFixRenamesFieldNamedAfterATypeUsedInsideAnAnonymousStructure(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tprivate var Thing:Int = 0;\n\n\tpublic var box:Array<{node:Thing}>;\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: src },
			{ file: 'pkg/Thing.hx', source: 'package pkg;\n\nclass Thing {\n\tpublic function new() {}\n}' }
		];
		assertLocalRenamed(files, 'pkg/C.hx', src, '_thing', 'var Thing');
	}

	public function testFixSkipsPrivateFieldWithSubclass(): Void {
		// A subclass (any file) could read the inherited field → report-only.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n}';
		final files: Array<{ source: String, file: String }> = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/D.hx', source: 'package pkg;\nclass D extends C {\n\tpublic function g() { return shape; }\n}' }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final cVs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.equals(1, cVs.length);
		Assert.equals(0, check.fix(cSrc, cVs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixSkipsPrivateFieldWithAccessGrant(): Void {
		// Another file with @:access(C) can read C's privates → report-only.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n}';
		final files: Array<{ source: String, file: String }> = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/E.hx', source: 'package pkg;\n@:access(pkg.C)\nclass E {}' }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final cVs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.equals(0, check.fix(cSrc, cVs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixSkipsPrivateFieldWithAllow(): Void {
		// @:allow on the class grants another type access → report-only.
		final src: String = 'package pkg;\n@:allow(pkg.X)\nclass C {\n\tprivate var shape:Int;\n}';
		final files: Array<{ source: String, file: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixRenamesPrivateFieldWithNonThisAccess(): Void {
		// A non-`this` access (`o.shape`) is attributed through `o`'s declared type and renames along.
		final src: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function eq(o:C) { return o.shape == shape; }\n}';
		assertRenamedSingle(src, 'return o._shape == _shape', 'o.shape');
	}

	public function testFixWithoutIndexLeavesPrivateFieldReportOnly(): Void {
		// No index passed → a private field cannot be proven confined → report-only.
		final src: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'pkg/C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixSkipsPrivateFieldWhenASkipParsedFileMentionsIt(): Void {
		// A skip-parse file could hide a subtype / @:access we never see — but only for a member
		// it SPELLS. A whole-project veto here silenced the rule for every file in a scope holding
		// one unparseable file; the reachable question is per-name.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n}';
		Assert.equals(0, fixCount(cSrc, 'package pkg;\nclass Bad { function f() { shape = 1;'));
		Assert.isTrue(fixCount(cSrc, 'package pkg;\nclass Bad { function f() { other = 1;') > 0);
	}

	public function testFixSkipsPrivateFieldNameCollision(): Void {
		// Renaming `shape` to `_shape` when `_shape` is already a field of the type
		// would duplicate the binding — skip, report-only.
		final src: String = 'package pkg;\nclass C {\n\tprivate var _shape:Int;\n\tprivate var shape:Int;\n'
			+ '\tpublic function f() { return this.shape + this._shape; }\n}';
		final files: Array<{ source: String, file: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}

	/**
	 * A same-named member on ANOTHER type is not a reference to this field: `r.bottom` where `r`
	 * is a `Rect` must not veto renaming `C.bottom`. The receiver's declared type decides.
	 */
	public function testFixRenamesFieldWithForeignReceiverAccess(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate var bottom:Int = 0;\n\n\t'
			+ 'public function f(r:Rect):Int {\n\t\treturn bottom + r.bottom;\n\t}\n}';
		assertRenamedWithRect(src, 'var _bottom:Int', 'var bottom:Int');
	}

	/** The foreign access itself is left ALONE — only this class's own reads are rewritten. */
	public function testForeignReceiverAccessIsNotRewritten(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate var bottom:Int = 0;\n\n\t'
			+ 'public function f(r:Rect):Int {\n\t\treturn bottom + r.bottom;\n\t}\n}';
		// One assertion covering both facts: this class's read IS rewritten, the foreign one is NOT.
		assertRenamedWithRect(src, 'return _bottom + r.bottom', 'r._bottom');
	}

	/**
	 * A receiver whose type IS the owner is a real reference `renameOccurrences` cannot see — it emits
	 * bare and `this.`-qualified reads only — so it renames ALONG with the declaration. Leaving it
	 * behind would strand it on a name the fix has removed.
	 */
	public function testFixRenamesFieldWithOwnTypeReceiverAccess(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate var bottom:Int = 0;\n\n\t'
			+ 'public function f(other:C):Int {\n\t\treturn bottom + other.bottom;\n\t}\n}';
		assertRenamedSingle(src, 'return _bottom + other._bottom', 'other.bottom');
	}

	/**
	 * The owner-bound merge takes the RECEIVER-attributed half only. The bare half is attributed by the
	 * enclosing CLASS, so it also holds reads bound to a same-named local or parameter; merging it would
	 * rewrite THOSE. Three distinct `__id` bindings in one class, each renaming to its own target.
	 */
	public function testFixKeepsBareReadsOutOfTheOwnerBoundMerge(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate var __id:Int = 0;\n\n\tpublic function add():Int {\n\t\treturn __id;\n\t}\n'
			+ '\n\tpublic function remove(__id:Int):Void {\n\t\tremoveAt(__id);\n\t}\n\n\t' + 'private function removeAt(x:Int):Void {}\n}';
		assertRenamedSingle(src, 'removeAt(id)', '__id');
	}

	/** A receiver whose type does not resolve keeps blocking — fail-closed. */
	public function testFixSkipsFieldWithUnresolvableReceiverAccess(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate var bottom:Int = 0;\n\n\t'
			+ 'public function f(u:Unknown):Int {\n\t\treturn bottom + u.bottom;\n\t}\n}';
		assertNotRenamed(src);
	}

	/**
	 * An all-lowercase field name is a common word, so a word-boundary match inside a comment is
	 * probably prose and is left ALONE — but it does not block the rename either. A comment does
	 * not execute: the worst case is a sentence that ages, never a broken build.
	 */
	public function testFixRenamesFieldMentionedInNonDistinctiveComment(): Void {
		final src: String = 'package pkg;\nclass C {\n\t// resets the shape state\n\tprivate var shape:Int;\n'
			+ '\tpublic function f() { return this.shape; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin(), index), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('var _shape:Int') >= 0, text);
				// The prose keeps its own word.
				Assert.isTrue(text.indexOf('// resets the shape state') >= 0, text);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	/** A `noqa` comment is a DIRECTIVE, not prose — it still refuses. */
	public function testFixSkipsFieldMentionedInNoqaComment(): Void {
		final src: String =
			'package pkg;\nclass C {\n\t// noqa: shape\n\tprivate var shape:Int;\n\tpublic function f():Int { return this.shape; }\n}';
		assertNotRenamed(src);
	}

	public function testFixRenamesDistinctiveFieldMentionedInComment(): Void {
		// A distinctive field name (carries an uppercase letter) is safe to rename inside a
		// comment too, so a commented-out reference stays consistent with the renamed code.
		final src: String = 'package pkg;\nclass C {\n\t// legacy xShape fallback\n\tprivate var xShape:Int;\n'
			+ '\tpublic function f() { return this.xShape; }\n}';
		final files: Array<{ source: String, file: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		assertCanonicalized(src, check.fix(src, vs, new HaxeQueryPlugin(), index), '// legacy _xShape fallback', 'var xShape');
	}

	public function testFixRenamesConfinedStaticFinal(): Void {
		// A confined private static final wrongly given a `_` prefix (the macro-build
		// anchor shape) → the underscore is stripped to a camelCase constant name.
		final src: String = 'package pkg;\nclass C {\n\tprivate static final _forceBuild:Int = 0;\n}';
		assertFixCanonicalWithIndex(src, 'final forceBuild', '_forceBuild');
	}

	public function testFixSkipsNonDerivableStaticFinal(): Void {
		// Stripping `_FORCE_build` yields `FORCE_build`, not a valid camelCase name → report-only.
		final src: String = 'package pkg;\nclass C {\n\tprivate static final _FORCE_build:Int = 0;\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixRenamesUpperSnakeStaticFinal(): Void {
		// A confined private static final wrongly given a `_` prefix keeps its
		// UPPER_SNAKE shape once the underscore is stripped (`_FORCE_BUILD` →
		// `FORCE_BUILD`, valid per the Constant rule's UPPER_SNAKE branch).
		final src: String = 'package pkg;\nclass C {\n\tprivate static final _FORCE_BUILD:Int = 0;\n}';
		assertFixCanonicalWithIndex(src, 'final FORCE_BUILD', '_FORCE_BUILD');
	}

	public function testFixMemoizesConfinementAcrossFindingsOnOneOwner(): Void {
		// Two flagged private static finals in ONE class: the per-owner confinement
		// memo runs the project-wide scan once, and both findings are still fixed.
		final src: String =
			'package pkg;\nclass C {\n\tprivate static final _forceBuild:Int = 0;\n\tprivate static final _cacheSize:Int = 0;\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(2, vs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin(), index);
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('forceBuild') >= 0);
				Assert.isTrue(text.indexOf('cacheSize') >= 0);
				Assert.isTrue(text.indexOf('_forceBuild') == -1);
				Assert.isTrue(text.indexOf('_cacheSize') == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	public function testFixSkipsPrivateFieldReferencedByStringInAnotherFile(): Void {
		#if (sys || nodejs)
		// C's `shape` is confined (no subtype / @:access / @:allow), so WITHOUT the
		// cross-file guard it would be renamed — but Other.hx reaches it by a
		// reflection string `'shape'`, which a rename would break silently.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final otherSrc: String = "package pkg;\nclass Other {\n\tpublic function g() { return Reflect.field(this, 'shape'); }\n}";
		final dir: String = CliFixture.writeDir('namingrefl', [{ name: 'C.hx', source: cSrc }, { name: 'Other.hx', source: otherSrc }]);
		final files: Array<{ file: String, source: String }> = [
			{ file: '$dir/C.hx', source: cSrc },
			{
				file: '$dir/Other.hx',
				source: otherSrc
			}
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final cVs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == '$dir/C.hx');
		Assert.equals(1, cVs.length);
		Assert.equals(0, check.fix(cSrc, cVs, new HaxeQueryPlugin(), index).length);
		cleanupNamingDir(dir, ['C.hx', 'Other.hx']);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testFixRenamesPrivateFieldWhenOtherFileHasOnlyIdentifierOrSubstring(): Void {
		#if (sys || nodejs)
		// Other.hx contains `shape` only as an identifier (a param) and as a
		// substring of a longer string ("reshaped:"), neither of which is the exact
		// quoted name — so the cross-file guard does not trip and the rename applies.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final otherSrc: String =
			'package pkg;\nclass Other {\n\tpublic function g(shape:Int):String {\n\t\treturn "reshaped:" + shape;\n\t}\n}';
		final dir: String = CliFixture.writeDir('namingid', [{ name: 'C.hx', source: cSrc }, { name: 'Other.hx', source: otherSrc }]);
		final files: Array<{ file: String, source: String }> = [
			{ file: '$dir/C.hx', source: cSrc },
			{
				file: '$dir/Other.hx',
				source: otherSrc
			}
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final cVs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == '$dir/C.hx');
		Assert.equals(1, cVs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(cSrc, cVs, new HaxeQueryPlugin(), index);
		switch RefactorSupport.canonicalize(cSrc, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('_shape') >= 0);
				Assert.isTrue(text.indexOf('var shape') == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
		cleanupNamingDir(dir, ['C.hx', 'Other.hx']);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A field named after its OWN package: `package touches;` puts the word in a module path, which
	 * is not a reference to anything. It used to leave an unattributable occurrence and veto the
	 * rename outright.
	 */
	public function testFixRenamesFieldNamedAfterItsOwnPackage(): Void {
		final src: String =
			'package touches;\n\nclass C {\n\tprivate var touches:Int = 0;\n\n\tpublic function f():Int {\n\t\treturn touches;\n\t}\n}';
		assertRenamedIn('touches/C.hx', src, 'var _touches:Int', 'var touches:Int');
	}

	/** Same for a package segment some import traverses, and for an imported TYPE's own name. */
	public function testFixRenamesFieldNamedAfterAnImportedPathSegment(): Void {
		final src: String = 'package pkg;\n\nimport editor.bottom.Bottom;\n\nclass C {\n\t'
			+ 'private var bottom:Int = 0;\n\n\tpublic function f():Int {\n\t\treturn bottom + Bottom.K;\n\t}\n}';
		assertRenamedIn('pkg/C.hx', src, 'var _bottom:Int', 'var bottom:Int');
	}

	/** An occurrence in ACTIVE code still blocks — the relaxation is scoped to module paths. */
	public function testFixSkipsFieldWithUnattributableActiveOccurrence(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tprivate var bottom:Int = 0;\n\n\t'
			+ 'public function f(r:Unknown):Int {\n\t\treturn bottom + r.bottom;\n\t}\n}';
		assertNotRenamed(src);
	}

	/** A word inside a longer literal is prose: `t('Can edit')` must not veto renaming `edit`. */
	public function testFixRenamesFieldMentionedAsWordInsideLiteral(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate final edit:Int = label();\n\n\tpublic function f():Int {\n'
			+ '\t\treturn edit;\n\t}\n\n\tprivate function label():Int {\n\t\ttrace(\'Can edit\');\n\t\treturn 1;\n\t}\n}';
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, '_edit', 'final edit');
	}

	/** The same for a compound key: `'field:field'` names no member. */
	public function testFixRenamesFieldMentionedInsideCompoundLiteral(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate final field:Int = 1;\n\n\t'
			+ "public function f():Int {\n\t\ttrace('field:field');\n\t\treturn field;\n\t}\n}";
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, '_field', 'final field');
	}

	/** A literal whose WHOLE content is the name can be a by-name lookup — still refused. */
	public function testFixSkipsFieldNamedByWholeLiteral(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate final edit:Int = 1;\n\n\t'
			+ "public function f():Int {\n\t\ttrace('edit');\n\t\treturn edit;\n\t}\n}";
		assertNotRenamed(src);
	}

	/**
	 * An interpolation read IS a reference and is renamed ALONG with the code — it never reaches the
	 * occurrence classifier, because `Rename.renameOccurrences` already covers it. The `StringWord`
	 * relaxation must not turn such a read into ignored prose.
	 */
	public function testFixRenamesFieldReadByInterpolation(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate final edit:Int = 1;\n\n\t'
			+ "public function f():String {\n\t\treturn 'v=${edit}!';\n\t}\n}";
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, "${_edit}", "${edit}");
	}

	public function testFixSkipsPrivatePropertyWithAccessors(): Void {
		// A confined private property backed by physical `get_`/`set_` accessors:
		// renaming the property to `_value` alone leaves the accessors named
		// `get_Value` / `set_Value`, but Haxe then requires `get__value` /
		// `set__value` - the single-decl autofix would emit non-compiling source, so
		// it must skip the property (report-only).
		final src: String = 'package pkg;\nclass C {\n\tprivate var Value(get, set):Int;\n\tfunction get_Value():Int return this.Value;\n'
			+ '\tfunction set_Value(v:Int):Int return this.Value = v;\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("'Value'"));
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixStillRenamesConfinedPropertylessPrivateField(): Void {
		// Guard against over-skipping: a plain confined private field with no
		// accessor siblings is still renamed - the property skip must not swallow it.
		final src: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		assertFixCanonicalWithIndex(src, '_shape', 'var shape');
	}

	public function testFixSkipsFieldRedefiningInheritedUnderscoreName(): Void {
		// Renaming `count` -> `_count` would REDEFINE `_count` inherited from Base - a Haxe compile
		// error ("Redefinition of variable in subclass") a local shadow does not have. The field
		// inheritance gate skips it - report-only.
		final baseSrc: String = 'package pkg;\nclass Base {\n\tprivate var _count:Int = 0;\n}';
		final cSrc: String =
			'package pkg;\nclass C extends Base {\n\tprivate var count:Int = 1;\n\tpublic function f() { return this.count; }\n}';
		final files: Array<{ file: String, source: String }> =
			[{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final cVs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.isTrue(cVs.length >= 1);
		Assert.equals(0, check.fix(cSrc, cVs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixSkipsFieldInRttiClass(): Void {
		// A field of a class carrying `@:rtti` directly is serialized by reflecting on field NAMES;
		// renaming it breaks saved files. Report-only even though the field is otherwise confined.
		final src: String = 'package pkg;\n@:rtti\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin(), index).length);
	}

	public function testFixSkipsFieldExtendingRttiClass(): Void {
		// A subclass extending a `@:rtti` base (without its own `@:rtti`) is still name-reflected
		// through the base - the transitive index check skips its field.
		final baseSrc: String = 'package pkg;\n@:rtti\nclass Base {\n\tpublic function new() {}\n}';
		final cSrc: String =
			'package pkg;\nclass C extends Base {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final files: Array<{ file: String, source: String }> =
			[{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final cVs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.equals(1, cVs.length);
		Assert.equals(0, check.fix(cSrc, cVs, new HaxeQueryPlugin(), index).length);
	}

	/**
	 * A `_`-prefix field rename resolves its supertype closure through the plugin's
	 * RESOLUTION scope: `Base` lives only in the resolution-scope library (not the
	 * report files), and a clean `Base` lets `x -> _x` proceed. The report-only
	 * `index` (confinement) cannot see `Base`; before the resolution wiring the field
	 * gate consulted THAT index and blocked the rename as an unresolvable supertype.
	 */
	public function testFixFieldResolvesCleanSupertypeThroughResolutionScope(): Void {
		// The import is load-bearing, not decoration: a cross-package `extends Base` does not
		// compile without it, and the supertype resolution the fix relies on reads exactly the
		// imports the file declares.
		final subSrc: String =
			'package pkg;\nimport ext.Base;\n\nclass Sub extends Base {\n\tprivate var x:Int;\n\tpublic function f() { return this.x; }\n}';
		final edits: Array<{ span: Span, text: String }> = fixWithResolutionScope(subSrc, 'package ext;\nclass Base {}');
		assertCanonicalized(subSrc, edits, '_x', 'var x');
	}

	/**
	 * The mirror: when the resolution-scope `Base` DECLARES `_x`, the rename `x -> _x`
	 * would trigger Haxe's "Redefinition of variable in subclass", so the field gate —
	 * now walking the closure through the resolution index — blocks it (report-only).
	 */
	public function testFixFieldBlockedBySupertypeMemberInResolutionScope(): Void {
		final subSrc: String = 'package pkg;\nclass Sub extends Base {\n\tprivate var x:Int;\n\tpublic function f() { return this.x; }\n}';
		final edits: Array<{ span: Span, text: String }> = fixWithResolutionScope(
			subSrc, 'package ext;\nclass Base {\n\tprivate var _x:Int;\n}'
		);
		Assert.equals(0, edits.length);
	}

	public function testFixDePrefixesDoubleUnderscoreField(): Void {
		// A private field with a doubled underscore (`__size`) de-prefixes to the single-underscore
		// convention (`_size`), mirroring the snake/de-prefix normalisation already applied to locals.
		final src: String = 'package pkg;\nclass C {\n\tprivate var __size:Int;\n\tpublic function f() { return this.__size; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin(), index);
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('_size') >= 0);
				Assert.isTrue(text.indexOf('__size') == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	public function testFixBlocksFieldWithUnresolvableOccurrence(): Void {
		// A field reference behind a mid-expression `#if` is raw trivia the resolver cannot bind -
		// an uncovered active-code occurrence. Even with per-binding attribution, an UNRESOLVABLE
		// occurrence still fails the completeness gate closed, so the field rename is skipped.
		final src: String = 'package pkg;\nclass C {\n\tprivate var __id:Int = 0;\n\tpublic function f():Int {\n'
			+ '\t\treturn __id #if cpp + __id #end;\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * The field `logo` is used bare before and after a `switch` whose arms each declare their own
	 * `logo` local. Each arm frames its own body (`RefShape.branchScopeKinds`), so the bare uses
	 * bind to the FIELD and rename with it, while both arm-locals keep their name. Before the arms
	 * framed, the first arm's local swallowed every occurrence in the method and the completeness
	 * gate refused the whole rename rather than orphan the field's uses.
	 */
	public function testFixRenamesFieldAcrossCaseArmsDeclaringTheSameName(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate var logo:Null<Sprite>;\n\tpublic function make(kind:Int):Void {\n'
			+ '\t\tif (logo != null) removeChild(logo);\n\t\tlogo = switch kind {\n\t\t\tcase 0:\n\t\t\t\tfinal logo:Sprite = new '
			+ 'Sprite();\n\t\t\t\tlogo;\n\t\t\tcase _:\n\t\t\t\tfinal logo:Sprite = new Sprite();\n\t\t\t\tlogo;\n\t\t};\n'
			+ '\t\taddChild(logo);\n\t}\n\tfunction removeChild(o:Sprite):Void {}\n\tfunction addChild(o:Sprite):Void {}\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin(), index), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('private var _logo:Null<Sprite>') >= 0, text);
				// The field's own uses, on both sides of the switch.
				Assert.isTrue(text.indexOf('if (_logo != null) removeChild(_logo)') >= 0, text);
				Assert.isTrue(text.indexOf('addChild(_logo)') >= 0, text);
				// Both arm-locals keep their name — they are not the flagged declaration.
				Assert.equals(2, text.split('final logo:Sprite = new Sprite();').length - 1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	public function testFixRenamesFieldWithSameNamedParamInAnotherMethod(): Void {
		// The valid counterpart of the leak case: a same-named PARAM in one method (properly scoped) does
		// NOT steal the field's bare uses in ANOTHER method - those correctly bind to the field and rename
		// with it; the param is excluded (it genuinely binds elsewhere) and stays put.
		final src: String = 'package pkg;\nclass C {\n\tprivate var logo:Null<Sprite>;\n\tpublic function set(logo:Sprite):Void {\n'
			+ '\t\tthis.logo = logo;\n\t}\n\tpublic function use():Void {\n\t\tif (logo != null) logo.x = 0;\n\t}\n}';
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, 'var _logo', 'var logo');
	}

	/**
	 * The member-rename path DECLINES on a bound target name — it never qualifies the
	 * rewritten references (`this.x`) the way the `trivial-getter` collapse does. Kept as
	 * a contract test: the sibling audit of the loop-variable shadow hole turned on this
	 * difference, and the decline is what makes the naming fix immune to it.
	 */
	public function testMemberRenameDeclinesOnBoundTargetName(): Void {
		final src: String = 'class C {\n\tprivate var __count:Int = 0;\n\tprivate var _count:Int = 1;\n'
			+ '\tpublic function sum():Int return __count + _count;\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * A private METHOD confined to its file de-prefixes like a private field: the resolver
	 * binds its declaration and every in-file call, so `__startCycle` -> `startCycle` is a
	 * complete rename. The autofix used to refuse the whole Method category, leaving the
	 * `__`-prefix findings report-only forever.
	 */
	public function testFixRenamesConfinedPrivateMethod(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function new() { __startCycle(); }\n'
			+ '\tprivate function __startCycle():Void { trace(1); }\n}';
		assertFixCanonicalWithIndex(src, 'startCycle', '__startCycle');
	}

	/**
	 * The callback-value shape: the method is never CALLED, only passed by name to a
	 * subscribe / unsubscribe pair. Both value reads resolve to the declaration, so the
	 * completeness gate is satisfied and all three occurrences rename together.
	 */
	public function testFixRenamesPrivateMethodUsedAsCallbackValue(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function new() { add(__onHover); }\n'
			+ '\tpublic function dispose():Void { remove(__onHover); }\n\tprivate function __onHover(e:Int):Void { trace(e); }\n'
			+ '\tprivate function add(f:Int -> Void):Void {}\n\tprivate function remove(f:Int -> Void):Void {}\n}';
		assertFixCanonicalWithIndex(src, 'add(onHover)', '__onHover');
	}

	/**
	 * An `override` binds the name to the SUPERTYPE's declaration - renaming the override
	 * alone orphans it ("Field ... is declared 'override' but ... does not override"). The
	 * member is still confined and its target name still free, so only the override gate
	 * can refuse it.
	 */
	public function testFixSkipsOverridePrivateMethod(): Void {
		final baseSrc: String = 'package pkg;\nclass Base {\n\tprivate function __render():Void {}\n}';
		final cSrc: String = 'package pkg;\nclass C extends Base {\n\toverride private function __render():Void { trace(1); }\n}';
		assertFixSkipped([{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }], 'pkg/C.hx', cSrc);
	}

	/**
	 * A subclass can call the inherited private method, so the member is NOT confined and a
	 * single-file rename would leave the subclass calling a name that no longer exists. The
	 * cross-file rename path stays field/constant-only, so this is report-only.
	 */
	public function testFixSkipsPrivateMethodWithSubclass(): Void {
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate function __tick():Void {}\n\tpublic function f() { __tick(); }\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g() { __tick(); }\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }], 'pkg/C.hx', cSrc);
	}

	/**
	 * Renaming `__tick` -> `tick` where a supertype already declares `tick` is a Haxe compile
	 * error ("Field tick should be declared with 'override' since it is inherited from
	 * superclass"). The inherited-member gate - previously field-only - must cover a method too.
	 */
	public function testFixSkipsMethodRedefiningInheritedName(): Void {
		final baseSrc: String = 'package pkg;\nclass Base {\n\tprivate function tick():Void {}\n}';
		final cSrc: String =
			'package pkg;\nclass C extends Base {\n\tprivate function __tick():Void { trace(1); }\n\tpublic function f() { __tick(); }\n}';
		assertFixSkipped([{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }], 'pkg/C.hx', cSrc);
	}

	/** A PUBLIC method is reachable from anywhere - outside the single-file rename's proof - so it stays report-only. */
	public function testFixSkipsPublicMethod(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function __run():Void {}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * An annotated method carries an `implicitReach`: a macro / `@:keep` / framework can reach it
	 * by NAME through a channel no identifier-level completeness proof sees. Report-only.
	 */
	public function testFixSkipsAnnotatedPrivateMethod(): Void {
		final src: String = 'package pkg;\nclass C {\n\t@:keep private function __boot():Void {}\n\tpublic function f() { __boot(); }\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * The SAME annotation, one seam further away: the cross-version `extern` idiom puts a
	 * conditional-compilation region between `@:keep` and the member, and the projection walk that
	 * answers "does an annotation precede this member" used to stop at the region. The member then
	 * read as unannotated and the autofix RENAMED it, while its region-free twin above was refused —
	 * one gate, two answers, decided by where the `#if` sits. Report-only, like the twin.
	 */
	public function testFixSkipsAnnotatedPrivateMethodBehindConditional(): Void {
		final src: String = 'package pkg;\nclass C {\n\t@:keep #if (haxe_ver >= 4.2) extern #else @:extern #end private function '
			+ '__boot():Void {}\n\tpublic function f() { __boot(); }\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * A region the run steps over grants NOTHING of its own: `#if js @:keep #end` says nothing about
	 * the member that FOLLOWS it, and counting an annotation written inside a branch would exempt
	 * every `extern inline` private in the tree from every unused / rename gate. So this member has NO
	 * `implicitReach` and the confined-private rename still commits.
	 */
	public function testFixRenamesMethodWhoseOnlyAnnotationIsInsideTheRegion(): Void {
		final src: String =
			'package pkg;\nclass C {\n\t#if js @:keep #end private function __boot():Void {}\n\tpublic function f() { __boot(); }\n}';
		assertRenamedIn('pkg/C.hx', src, 'function boot', '__boot');
	}

	/**
	 * `_new` de-prefixes to `new` - the CONSTRUCTOR name, not a usable method identifier. The
	 * de-prefix normalizer must refuse a keyword result, as the local / param one already does.
	 */
	public function testFixSkipsMethodDeprefixingToKeyword(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate function _new():Void {}\n\tpublic function f() { _new(); }\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * A method of a `@:rtti` class is reflected on by NAME - report-only. Held by TWO independent
	 * gates (verified: ablating either alone leaves this green, ablating both flips it) - the
	 * projection's `renameUnsafe` marking of every member of a directly-`@:rtti` type, and the
	 * transitive-rtti gate now extended to the Method category.
	 */
	public function testFixSkipsMethodInRttiClass(): Void {
		final src: String = 'package pkg;\n@:rtti\nclass C {\n\tprivate function __load():Void {}\n\tpublic function f() { __load(); }\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * A private field whose corrected name the constructor PARAMETER already holds is the param
	 * idiom: the field write would become a self-assignment, so the write is qualified through
	 * `this.` instead of the rename being refused.
	 */
	public function testFixQualifiesParamCapturedFieldRename(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate final __position:Int;\n\tpublic function new(_position:Int) {\n'
			+ '\t\t__position = _position;\n\t}\n}';
		assertFixCanonicalWithIndex(src, 'this._position = _position', '__position');
	}

	/**
	 * A capture by a LOCAL is a naming mistake, not the param idiom - qualifying it would emit
	 * correct but confusing code, so the rename stays refused. Pins `Rename.qualifyCaptured`'s
	 * boundary through the `naming` path.
	 */
	public function testFixRefusesLocalCapturedFieldRename(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate final __position:Int = 0;\n\tpublic function f(position:Int):Int {\n'
			+ '\t\tfinal _position:Int = position;\n\t\treturn __position + _position;\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * A STATIC member can never be named through `this.`, so the qualification arm must not be
	 * reached for one. Pins the check's own static gate, ahead of the expensive occurrence
	 * resolution - without it the capture repair emits `this.run()` for a static method.
	 */
	public function testFixRefusesStaticMemberCapture(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate static function __run():Void {}\n\tpublic function f(run:Int):Void {\n'
			+ '\t\ttrace(run);\n\t\t__run();\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * A member of a Haxe `abstract` cannot be named through `this.` (there `this` is the
	 * underlying value), so the collision must stay a refusal - the qualified rewrite would not
	 * compile. Pins the check's own arm through the shared reachability predicate.
	 */
	public function testFixRefusesAbstractMemberCapture(): Void {
		final src: String = 'package pkg;\nabstract A(Int) {\n\tprivate function __run():Int return this + 1;\n'
			+ '\tpublic function f(run:Int):Int return __run() + run;\n}';
		assertFixSkipped([{ file: 'pkg/A.hx', source: src }], 'pkg/A.hx', src);
	}

	/**
	 * The private-field normalizer shares the camel word-splitting policy: a leading acronym run
	 * lowercases all but its last character, so the fix cannot manufacture the very
	 * lowercase-head-over-caps-tail shape the artifact arm exists to remove.
	 */
	public function testFixLowercasesLeadingAcronymPrivateField(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate var URLPath:Int = 0;\n\tpublic function f():Int return URLPath;\n}';
		assertFixCanonicalWithIndex(src, '_urlPath', '_uRLPath');
	}

	/** An all-caps private field lowercases whole, not first-letter-only: `HEIGHT` -> `_height`, never `_hEIGHT`. */
	public function testFixLowercasesAllCapsPrivateField(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate var HEIGHT:Int = 0;\n\tpublic function f():Int return HEIGHT;\n}';
		assertFixCanonicalWithIndex(src, '_height', '_hEIGHT');
	}

	public function testReflectionMemberNamesReadsSingleQuotedFieldArgument(): Void {
		Assert.isTrue(reflectionNames("class C {\n\tfunction f() {\n\t\tReflect.getProperty(o, 'shape');\n\t}\n}").contains('shape'));
	}

	public function testReflectionMemberNamesReadsDoubleQuotedFieldArgument(): Void {
		Assert.isTrue(reflectionNames('class C {\n\tfunction f() {\n\t\tReflect.field(o, "shape");\n\t}\n}').contains('shape'));
	}

	public function testReflectionMemberNamesCoverTheWholeFieldApi(): Void {
		for (m in [
			'field',
			'setField',
			'getProperty',
			'setProperty',
			'hasField',
			'deleteField',
			'callMethod'
		])
			Assert.isTrue(
				reflectionNames('class C {\n\tfunction f() {\n\t\tReflect.$m(o, "shape", 1);\n\t}\n}').contains('shape'),
				'Reflect.$m should project shape'
			);
	}

	public function testReflectionMemberNamesFindsANestedCall(): Void {
		final src: String = "class C {\n\tfunction f() {\n\t\ttrace('' + Reflect.field(o, 'shape'));\n\t}\n}";
		Assert.isTrue(reflectionNames(src).contains('shape'));
	}

	/** A string that merely SPELLS a member — a `case` action id, an asset key — is not a reference to it. */
	public function testReflectionMemberNamesIgnoresAPlainStringLiteral(): Void {
		final src: String =
			"class C {\n\tfunction f(a:String) {\n\t\tswitch a {\n\t\t\tcase 'shape': trace('shape');\n\t\t\tcase _:\n\t\t}\n\t}\n}";
		Assert.equals(0, reflectionNames(src).length);
	}

	/** `field` / `setProperty` are ordinary method names any type may carry — the receiver decides. */
	public function testReflectionMemberNamesIgnoresTheSameMethodOnAnotherReceiver(): Void {
		Assert.equals(0, reflectionNames("class C {\n\tfunction f() {\n\t\tform.field('shape');\n\t}\n}").length);
	}

	/** The documented limit: a name the call computes is unknowable, so it is outside the projection. */
	public function testReflectionMemberNamesIgnoresADynamicName(): Void {
		final src: String = 'class C {\n\tfunction f(key:String) {\n\t\tReflect.field(o, key);\n\t}\n}';
		Assert.equals(0, reflectionNames(src).length);
	}

	public function testReflectionMemberNamesIgnoresAnInterpolatedLiteral(): Void {
		final src: String = "class C {\n\tfunction f(p:String) {\n\t\tReflect.field(o, 'sh${p}pe');\n\t}\n}";
		Assert.equals(0, reflectionNames(src).length);
	}

	public function testReflectionMemberNamesDeduplicates(): Void {
		final src: String = "class C {\n\tfunction f() {\n\t\tReflect.field(o, 'shape');\n\t\tReflect.hasField(o, 'shape');\n\t}\n}";
		Assert.equals(1, reflectionNames(src).length);
	}

	/**
	 * Same-pass claim gate (A2): two declarations whose normalized names COLLIDE
	 * ('CAPS' and 'Caps' both -> '_caps') must not both land — the second DEFERS
	 * via the same mechanism that already defers on overlapping edit spans, and
	 * re-fires (getting refused for good by the whole-file collision scan) on the
	 * next --fix pass.
	 */
	public function testFixDefersTheSecondDeclarationWantingAnAlreadyClaimedName(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tprivate var CAPS:Int = 1;\n\tprivate var Caps:Int = 2;\n'
			+ '\n\tpublic function sum() { return CAPS + Caps; }\n}';
		// The renamed read next to the untouched one, in ONE string: neither half is true of the input,
		// and the duplicate-field bug produces `_caps + _caps`.
		assertRenamedIn('pkg/C.hx', src, '_caps + Caps', '_caps + _caps');
		assertRenamedIn('pkg/C.hx', src, 'var Caps', 'var CAPS');
	}

	/**
	 * `underscoreCamel` (B5) splits on `_` via the shared `camelCore`, so a multi-segment
	 * UPPER_SNAKE private field is corrected outright rather than staying report-only.
	 */
	public function testFixRenamesAnUpperSnakePrivateField(): Void {
		final src: String =
			'package pkg;\n\nclass C {\n\tprivate var CELLS_NUM_X:Int = 20;\n\n\tpublic function f() { return CELLS_NUM_X; }\n}';
		assertRenamedIn('pkg/C.hx', src, '_cellsNumX', 'CELLS_NUM_X');
	}

	/**
	 * Sibling of the above proving the SEGMENT-COUNT boundary itself moved: before B5 only a
	 * single-segment name ('CAPS' -> '_caps') fixed; a two-segment name ('CAPS_TWO') stayed
	 * report-only because `correctedName` returned null. Now it is renamed too.
	 */
	public function testFixRenamesAMultiSegmentUpperSnakePrivateField(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tprivate var CAPS_TWO:Int = 1;\n\n\tpublic function f() { return CAPS_TWO; }\n}';
		assertRenamedIn('pkg/C.hx', src, '_capsTwo', 'CAPS_TWO');
	}

	/**
	 * The one boundary the `_` split must NOT cross (B5): a separator BETWEEN TWO DIGIT RUNS has no
	 * camelCase spelling, because the capital that marks every other segment boundary does not exist
	 * for a digit. `_u5_7` (an age band "U5 - 7") would fuse to `_u57` - a different reading, and one
	 * `_u1_14` and `_u11_4` would BOTH land on - so the finding stays report-only rather than being
	 * "corrected" into a worse name. Measured on a real tree: without this guard the split renamed
	 * four such age-band fields.
	 */
	public function testFixRefusesAFieldWhoseUnderscoreSeparatesTwoDigitRuns(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tprivate final _u5_7:Int = 1;\n\n\tpublic function f() { return _u5_7; }\n}';
		assertNotRenamed(src);
	}

	/**
	 * The sister side of that boundary: a digit run adjacent to LETTERS keeps its boundary either way
	 * (`HEADLINE_1` -> `Headline1`, `1_FORMAT` -> `1Format`), so such a name IS corrected.
	 */
	public function testFixRenamesAFieldWithADigitSegmentBetweenLetterSegments(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tprivate var HEADLINE_1_FORMAT:Int = 1;\n'
			+ '\n\tpublic function f() { return HEADLINE_1_FORMAT; }\n}';
		assertRenamedIn('pkg/C.hx', src, '_headline1Format', 'HEADLINE_1_FORMAT');
	}

	/**
	 * `@:rtti` before a conditional-compilation region belongs to the TYPE the region holds, not to
	 * the type that follows it. The run-ender test asked only about MEMBERS, so a region holding a
	 * member-free type was transparent and the annotation reached one type too far - marking a class
	 * nothing annotates rename-unsafe and forfeiting every legitimate rename in it. Which declaration
	 * ends the run is the category whose run is walked: a type run is ended by a type.
	 */
	public function testFixRenamesFieldOfClassAfterRttiRegionHoldingAType(): Void {
		final src: String = 'package pkg;\n@:rtti #if js class Holder {} #end\nclass C {\n\tprivate var shape:Int;\n'
			+ '\tpublic function f() { return this.shape; }\n}';
		assertRenamedIn('pkg/C.hx', src, 'var _shape', 'var shape');
	}

	/**
	 * The twin the seam is FOR: a region holding no declaration at all is transparent, so `@:rtti`
	 * still reaches the class behind the cross-version idiom and its field stays report-only.
	 */
	public function testFixSkipsFieldOfRttiClassBehindMemberFreeRegion(): Void {
		final src: String = 'package pkg;\n@:rtti #if js @:native("C") #end\nclass C {\n\tprivate var shape:Int;\n'
			+ '\tpublic function f() { return this.shape; }\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * The three refusals above, now each saying which gate closed.
	 *
	 * `naming` reported 231 findings on an 851-file tree and wrote nothing, by either the per-file or
	 * the cross-file path, and the run could say only `its fix was called for these findings and
	 * returned no edit; the check declares neither NoAutofix nor a decline reason`. The rename path is
	 * a chain of independent proofs and `Check.fix` answers all of their failures with the same empty
	 * array, so "which one" was unanswerable from outside — and the first hypothesis anyone forms
	 * about a wholesale zero is a gate closing by accident. Measured with the reasons in place it is
	 * not: 198 of the 231 are a policy that states a format and carries no normalizer, and the rest
	 * split across these gates (7 override, 5 non-member, 3 rename-unsafe, 3 unconfined, 15 an
	 * unprovable cross-file hierarchy).
	 */
	public function testEveryRefusedRenameNamesItsGate(): Void {
		Assert.equals(
			'only a member (field / constant / method) has a confinement proof, and this declaration is not one — a type or enum-value '
			+ 'rename reaches every file that names it',
			refusalFor([{ file: 'C.hx', source: 'class foo {}' }], 'C.hx')
		);
		final baseSrc: String = 'package pkg;\nclass Base {\n\tprivate function __render():Void {}\n}';
		final overrideSrc: String = 'package pkg;\nclass C extends Base {\n\toverride private function __render():Void { trace(1); }\n}';
		Assert.equals(
			'the method is an `override`, so its name is the SUPERTYPE declaration\'s — renaming this one alone would leave it overriding '
			+ 'nothing',
			refusalFor([
				{ file: 'pkg/Base.hx', source: baseSrc },
				{ file: 'pkg/C.hx', source: overrideSrc }
			], 'pkg/C.hx')
		);
		Assert.equals(
			'a public member is reachable from every file holding a value of its owner type, so the single-file rename never applies to '
			+ 'one — the cross-file path owns it, and declined too',
			refusalFor([
				{ file: 'pkg/C.hx', source: 'package pkg;\nclass C {\n\tpublic function __run():Void {}\n}' }
			], 'pkg/C.hx')
		);
		// The other half: a rename the chain DOES reach the end of declines nothing.
		final renamed: String = 'package pkg;\nclass C {\n\tprivate function __run():Void {}\n\n\tpublic function u():Void { __run(); }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: renamed }];
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.isTrue(check.fix(renamed, vs, new HaxeQueryPlugin(), SymbolIndex.build(files, new HaxeQueryPlugin())).length > 0);
		Assert.isNull(vs[0].declineReason, 'a rename that landed declined nothing');
	}

	/**
	 * The gate `testEveryRefusedRenameNamesItsGate` measured the largest share of, now open. 198 of
	 * that run's 231 declines were one sentence — the policy came from a `checkstyle.json`, which
	 * states a format and no correction, so `correctedName` had nothing to return — and the proof was
	 * a ONE-VARIABLE matrix: same source, same finding, the same `MethodName` regex, only the
	 * policy's ORIGIN differing, `fixed 0` against `fixed 2`. Both arms now write the same two edits,
	 * the declaration and its call site.
	 *
	 * On disk because `Naming.fix` resolves its policy through `NamingSupport.policyFor`, which walks
	 * up from the FILE: an in-memory policy would exercise the check and skip the loader, which is
	 * the half that was broken.
	 */
	public function testACheckstyleDerivedPolicyFixesWhatTheDefaultWould(): Void {
		#if (sys || nodejs)
		final src: String =
			'package pkg;\nclass C {\n\tprivate function _doThing():Void {}\n\n\tpublic function f():Void { _doThing(); }\n}';
		final configured: String = CliFixture.writeDir('namingcsfix', [
			{ name: 'C.hx', source: src },
			{ name: 'checkstyle.json', source: '{"checks":[{"type":"MethodName","props":{"format":"^[a-z][a-zA-Z0-9_]*$"}}]}' }
		]);
		final bare: String = CliFixture.writeDir('namingnocsfix', [{ name: 'C.hx', source: src }]);
		Assert.equals(2, discoveredPolicyFixCount(configured, src));
		Assert.equals(2, discoveredPolicyFixCount(bare, src));
		CliFixture.removeDir(configured);
		CliFixture.removeDir(bare);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A decline reason that is FALSE is worse than none: it sends the next reader after a mechanism
	 * the member does not have. `NamedDecl` carried a `Bool` for "reachable without an identifier
	 * naming it", five disjoint mechanisms answered it, and one sentence spoke for all five — so a
	 * `private function new()` declined with `the member carries metadata` and carries none.
	 * Measured on the base engine, `lint --fix --rule naming` on exactly this fixture printed that
	 * sentence for both findings.
	 *
	 * ONE-VARIABLE matrix: two members of one class, one finding each, under one `MethodName` regex
	 * that admits neither name. The constructor and the annotated method must now state DIFFERENT
	 * gates, and the constructor's must not be the metadata one.
	 *
	 * On disk because `Naming.fix` resolves its policy through `NamingSupport.policyFor`, which walks
	 * up from the FILE — and because the built-in Method format accepts `new`, so only a config can
	 * put a constructor in front of this gate at all.
	 */
	public function testEachImplicitReachMechanismStatesItsOwnGate(): Void {
		#if (sys || nodejs)
		final src: String = 'package pkg;\nclass C {\n\tprivate function new() {}\n\n\t@:keep private function boot():Void {}\n}';
		final dir: String = CliFixture.writeDir('namingimplicitreach', [
			{ name: 'C.hx', source: src },
			{ name: 'checkstyle.json', source: '{"checks":[{"type":"MethodName","props":{"format":"^zz[a-z][a-zA-Z0-9]*$"}}]}' }
		]);
		final reasons: Array<String> = declineReasonsIn(dir, src);
		Assert.equals(2, reasons.length);
		Assert.stringContains('the method is the type\'s CONSTRUCTOR', reasons[0]);
		Assert.isFalse(reasons[0].contains('carries metadata'), 'a constructor carries none');
		Assert.stringContains('the member carries metadata', reasons[1]);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * TWO RULES DISAGREEING ABOUT ONE MEMBER. `unused-private` declines even to REPORT
	 * `private static final _BAD_ENTRY = SomeType;` — a `Class<T>` registry entry a macro resolves by
	 * NAME — and `naming --fix` renamed it to `BAD_ENTRY`. A name reached by NAME is broken by a
	 * rename exactly as it is broken by a deletion, and both rules read the SAME
	 * `NamedDecl.implicitReach` to decide: `UnusedPrivate.violationFor` asks it of every member,
	 * `RenameRefusal.of` asked it under `category == Method`. `isTypeReferenceInit` requires a
	 * `FinalMember`, whose category is Constant or Field and never Method, so the arm that exists FOR
	 * this shape could not refuse anything at all.
	 *
	 * ONE-VARIABLE matrix, the initializer: `= SomeType` against `= 5`, same declaration otherwise.
	 * The plain twin is still deleted by one rule and still renamed by the other, which is what makes
	 * this a narrowing of one question rather than a rule turned off.
	 */
	public function testATypeRegistryConstantIsNoMoreRenameableThanItIsDeletable(): Void {
		final registry: String = 'package pkg;\nclass C {\n\tprivate static final _BAD_ENTRY = SomeType;\n}';
		final plain: String = 'package pkg;\nclass C {\n\tprivate static final _BAD_ENTRY = 5;\n}';
		Assert.equals(1, unusedPrivateCount(plain), 'the plain twin IS a dead private');
		Assert.equals(0, unusedPrivateCount(registry), 'a macro may reach the registry entry by name');
		final refused: { edits: Int, findings: Array<Violation> } = fixedFindingsIn('pkg', registry);
		Assert.equals(0, refused.edits, 'and a rename breaks such a reference exactly as a deletion does');
		Assert.stringContains('a `static final` bound to a TYPE reference', refused.findings[0].declineReason ?? '');
		Assert.isTrue(fixedFindingsIn('pkg', plain).edits > 0, 'the plain twin still renames');
	}

	/**
	 * The other arm the Method-only gate let through: an annotated member. `@:keep` is the mechanism
	 * `unused-private` refuses a DELETION for, and a macro / framework reaches such a member through
	 * references no identifier-level proof sees whatever the member's category is — so a field and a
	 * constant carrying one were renamed while a method carrying one was refused.
	 */
	public function testAnAnnotatedFieldAndConstantAreRefusedAsAnAnnotatedMethodIs(): Void {
		final field: String =
			'package pkg;\nclass C {\n\t@:keep private var Bad_Field:Int = 1;\n\n\tpublic function f():Int { return Bad_Field; }\n}';
		final constant: String =
			'package pkg;\nclass C {\n\t@:keep private static final _KEPT:Int = 7;\n\n\tpublic function f():Int { return _KEPT; }\n}';
		for (src in [field, constant]) Assert.stringContains('the member carries metadata', declineReasonsIn('pkg', src)[0]);
	}

	/** The `Naming` fix edits for `pkg/C.hx` with one unparseable sibling carrying `badSrc`. */
	private function fixCount(cSrc: String, badSrc: String): Int {
		final files: Array<{ source: String, file: String }> = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/Bad.hx', source: badSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final cVs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		return check.fix(cSrc, cVs, new HaxeQueryPlugin(), index).length;
	}

	/** The member names `src` reaches through a reflection call, via the grammar's own projection. */
	private function reflectionNames(src: String): Array<String> {
		final support: HaxeNamingSupport = new HaxeNamingSupport();
		return support.reflectionMemberNames(new HaxeQueryPlugin().parseFile(src), src);
	}

	private function cleanupNamingDir(dir: String, names: Array<String>): Void {
		#if (sys || nodejs)
		for (n in names) if (sys.FileSystem.exists('$dir/$n')) sys.FileSystem.deleteFile('$dir/$n');
		if (sys.FileSystem.exists(dir)) sys.FileSystem.deleteDirectory(dir);
		#end
	}

	/** `src` plus a sibling `pkg.Rect` that carries its own `bottom`, fixed and asserted. */
	private function assertRenamedWithRect(src: String, present: String, absent: String): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: src },
			{ file: 'pkg/Rect.hx', source: 'package pkg;\n\nclass Rect {\n\tpublic var bottom:Int = 0;\n\n\tpublic function new() {}\n}' }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.isTrue(vs.length >= 1);
		assertCanonicalized(src, check.fix(src, vs, new HaxeQueryPlugin(), index), present, absent);
	}

	/** `assertNotRenamed`'s single-file setup, asserting on the fixed TEXT instead of a refusal. */
	private function assertRenamedSingle(src: String, present: String, absent: String): Void {
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: src }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.isTrue(vs.length >= 1);
		assertCanonicalized(src, check.fix(src, vs, new HaxeQueryPlugin(), index), present, absent);
	}

	/**
	 * Run naming's field fix on `subSrc` (the sole report file) with `libSrc` as the
	 * only resolution-scope library file. Confinement uses the report-only index; the
	 * field inheritance proof uses the host's resolution index (report UNION library).
	 */
	private function fixWithResolutionScope(subSrc: String, libSrc: String): Array<{ span: Span, text: String }> {
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/Sub.hx', source: subSrc }];
		final lib: Array<{ file: String, source: String }> = [{ file: 'ext/Base.hx', source: libSrc }];
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({ declared: true, sources: () -> {report: report, library: new LibrarySources(lib) } });
		final reportIndex: SymbolIndex = SymbolIndex.build(report, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(report, scoped).filter(v -> v.file == 'pkg/Sub.hx');
		Assert.equals(1, vs.length);
		return check.fix(subSrc, vs, scoped, reportIndex);
	}

	/** The naming fix edit count for `dir/C.hx`, with whatever config `dir` itself carries governing it. */
	private function discoveredPolicyFixCount(dir: String, src: String): Int {
		final run: { edits: Int, findings: Array<Violation> } = fixedFindingsIn(dir, src);
		Assert.equals(1, run.findings.length);
		return run.edits;
	}

	/**
	 * `dir/C.hx`'s naming findings after `fix` has been asked for each — so a caller can assert on
	 * the EDIT COUNT or on the `declineReason` the refusals wrote, from one run. `dir`'s own config
	 * governs, whatever it is: `Naming.fix` resolves its policy through `NamingSupport.policyFor`,
	 * which walks up from the FILE.
	 */
	private function fixedFindingsIn(dir: String, src: String): { edits: Int, findings: Array<Violation> } {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final files: Array<{ file: String, source: String }> = [{ file: '$dir/C.hx', source: src }];
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, plugin);
		return { edits: check.fix(src, vs, plugin, SymbolIndex.build(files, plugin)).length, findings: vs };
	}

	/** The `unused-private` findings a one-file `pkg/C.hx` fixture carries — the OTHER reader of `implicitReach`. */
	private function unusedPrivateCount(src: String): Int {
		return new UnusedPrivate().run([{ file: 'pkg/C.hx', source: src }], new HaxeQueryPlugin()).length;
	}

	/** Every finding's `declineReason` for `dir/C.hx`, in document order, with `''` for one that got none. */
	private function declineReasonsIn(dir: String, src: String): Array<String> {
		final run: { edits: Int, findings: Array<Violation> } = fixedFindingsIn(dir, src);
		Assert.equals(0, run.edits, 'every rename is refused');
		return [for (v in run.findings) v.declineReason ?? ''];
	}

	#if (sys || nodejs)
	/** A private field another file reads via `Reflect.getProperty(o, 'shape')` stays report-only. */
	public inline function testFixSkipsPrivateFieldNamedByReflectionInAnotherFile(): Void {
		assertReflectionGuard(
			"package pkg;\nclass E {\n\tpublic function f(o:Dynamic) {\n\t\ttrace(Reflect.getProperty(o, 'shape'));\n\t}\n}", false
		);
	}

	/** The same spelling as a plain action id is NOT a reference — the rename must land. */
	public inline function testFixRenamesPrivateFieldOnlySpelledByAStringInAnotherFile(): Void {
		assertReflectionGuard("package pkg;\nclass E {\n\tpublic function f(a:String) {\n\t\tif (a == 'shape') trace(a);\n\t}\n}", true);
	}

	/** A comment mentioning the name in quotes is text, not a reflection call. */
	public inline function testFixRenamesPrivateFieldMentionedInAnotherFilesComment(): Void {
		assertReflectionGuard("package pkg;\nclass E {\n\t// reads 'shape' from the model\n\tpublic function f() {}\n}", true);
	}

	/**
	 * Whether `C.shape`'s rename survives `otherSource` sitting beside it. Both files go to
	 * DISK because the guard reads its sources through the index's paths (`SymbolIndex` keeps
	 * none), so an in-memory pair would leave the guard with nothing to look at and pass
	 * vacuously.
	 */
	private function assertReflectionGuard(otherSource: String, expectRenamed: Bool): Void {
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\n\tpublic function f():Void {\n\t\tshape = 1;\n\t}\n}';
		final dir: String = CliFixture.writeDir('namingrefl', [
			{ name: 'C.hx', source: cSrc },
			{ name: 'E.hx', source: otherSource }
		]);
		final files: Array<{ file: String, source: String }> = [
			{ file: '$dir/C.hx', source: cSrc },
			{ file: '$dir/E.hx', source: otherSource }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == '$dir/C.hx');
		Assert.isTrue(vs.length >= 1);
		final edits: Array<{ span: Span, text: String }> = check.fix(cSrc, vs, new HaxeQueryPlugin(), index);
		Assert.equals(expectRenamed, edits.length > 0);
		cleanupNamingDir(dir, ['C.hx', 'E.hx']);
	}
	#end

}
