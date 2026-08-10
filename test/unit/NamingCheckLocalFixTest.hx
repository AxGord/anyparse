package unit;

import utest.Assert;
import anyparse.check.Check.Violation;
import anyparse.check.Naming;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import anyparse.query.SymbolIndex;

/**
 * The `naming` autofix on a LOCAL binding — a local `var` / `final`, a parameter, or
 * a local function — where the rename is confined to the one function that declares
 * it.
 *
 * Covered here: the de-prefix and the snake / upper-snake / leading-acronym
 * normalisations; the occurrences a rename must carry along (`$name` and `${name}`
 * interpolations, a distinctive comment mention) and the ones that block it (a
 * string literal spelling the name, a `noqa` comment, a sibling or enclosing-scope
 * binding, a parameter, an own member, a keyword); and the CAPTURE rule — a rename
 * that would make a member read resolve to the new local is qualified with `this.`
 * when that is provable and refused when it is not.
 */
class NamingCheckLocalFixTest extends NamingCheckTestBase {

	public function testFixRenamesLocal(): Void {
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar MyLocal = 1;\n\t\ttrace(MyLocal);\n\t}\n}';
		assertFixCanonical(src, 'myLocal', 'MyLocal');
	}

	public function testFixRenamesParam(): Void {
		final src: String = 'class C {\n\tpublic function f(BadParam:Int) {\n\t\treturn BadParam;\n\t}\n}';
		assertFixCanonical(src, 'badParam', 'BadParam');
	}

	public function testFixRenamesLocalWithSimpleInterpolation(): Void {
		// A bare `$name` interpolation read IS in the resolver index (as is the braced
		// `${name}` form), so the rename rewrites it along with the declaration instead
		// of bailing to report-only.
		final src: String = "class C {\n\tpublic function f():String {\n\t\tvar BadLocal = 3;\n\t\treturn 'value is $BadLocal';\n\t}\n}";
		assertFixCanonical(src, "$badLocal", 'BadLocal');
	}

	public function testFixRenamesLocalWithBracedInterpolation(): Void {
		// The braced `${name}` interpolation IS a resolved reference, so a local
		// rename rewrites both the declaration and the interpolation.
		final src: String = "class C {\n\tpublic function f():String {\n\t\tvar BadLocal = 3;\n\t\treturn 'value is ${BadLocal}';\n\t}\n}";
		assertFixCanonical(src, "${badLocal}", 'BadLocal');
	}

	public function testFixRenamesLocalWithCommentedMention(): Void {
		// A commented-out / prose mention of the old name no longer blocks the rename;
		// the occurrence inside the comment is renamed together with the code.
		final src: String =
			'class C {\n\tpublic function f() {\n\t\t// legacy MyLocal reference\n\t\tvar MyLocal = 1;\n\t\ttrace(MyLocal);\n\t}\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		assertCanonicalized(src, check.fix(src, vs, new HaxeQueryPlugin()), '// legacy myLocal reference', 'MyLocal');
	}

	public function testFixSkipsLocalMentionedInStringLiteral(): Void {
		// A plain string literal mentioning the old name may be a reflection key, so it
		// blocks the rename (consistent with the reflection-string guards).
		final src: String =
			'class C {\n\tpublic function f():String {\n\t\tvar MyLocal = 1;\n\t\ttrace(MyLocal);\n\t\treturn "MyLocal";\n\t}\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixSkipsLocalMentionedInNoqaComment(): Void {
		// A `noqa`-carrying comment is a machine-meaningful directive line; the rename
		// must not rewrite inside it, so the mention blocks (unlike a plain comment).
		final src: String =
			'class C {\n\tpublic function f() {\n\t\t// noqa: naming keep MyLocal\n\t\tvar MyLocal = 1;\n\t\ttrace(MyLocal);\n\t}\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixRenamesParamNamedAfterAnImportedTypeName(): Void {
		// TM's real shape: a handler parameter named `Event`, in a file importing `openfl.events.Event`
		// and using `Event.ACTIVATE` — the import path is not a reference to the parameter.
		final src: String =
			'package pkg;\n\nimport openfl.events.Event;\n\nclass C {\n\tpublic function f(Event:Int):Int {\n\t\treturn Event;\n\t}\n}';
		assertRenamedIn('pkg/C.hx', src, 'f(event:Int)', 'f(Event:Int)');
	}

	/**
	 * A parameter named after an IMPORTED TYPE. The projection gives `Event.ACTIVATE` and a read of
	 * the parameter the same `IdentExpr`, and `:Event` annotations only exist in the parallel
	 * type-ref projection — so all three forms used to read as unattributable references and veto
	 * the rename. Discounted now: the identifier binds to no value there AND the index resolves the
	 * name to a type in this file's scope.
	 */
	public function testFixRenamesParamNamedAfterAnImportedType(): Void {
		final src: String = 'package pkg;\n\nimport pkg.Thing;\n\nclass C {\n\tpublic function a(Thing:Int):Int {\n\t\treturn Thing;\n\t}\n'
			+ '\n\tpublic function b(t:Thing):Int {\n\t\treturn Thing.K + t.n;\n\t}\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: src },
			{
				file: 'pkg/Thing.hx',
				source: 'package pkg;\n\nclass Thing {\n\tpublic static final K:Int = 1;\n\n\tpublic var n:Int = 0;\n\n'
					+ '\tpublic function new() {}\n}'
			}
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'pkg/C.hx');
		Assert.isTrue(vs.length >= 1);
		switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin(), index), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('a(thing:Int)') >= 0, text);
				Assert.isTrue(text.indexOf('return thing;') >= 0, text);
				// The three TYPE forms keep their spelling.
				Assert.isTrue(text.indexOf('import pkg.Thing;') >= 0, text);
				Assert.isTrue(text.indexOf('b(t:Thing)') >= 0, text);
				Assert.isTrue(text.indexOf('Thing.K') >= 0, text);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	/**
	 * The unbound-root test alone is not enough: a name that resolves to NO type in scope keeps
	 * blocking, because an unattributed identifier is then a reference the resolver missed.
	 */
	public function testFixSkipsParamWhenNameIsNotATypeInScope(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function a(Thing:Int):Int {\n\t\treturn Thing;\n\t}\n\n\t'
			+ 'public function b():Int {\n\t\treturn Thing.K;\n\t}\n}';
		assertNotRenamed(src);
	}

	public function testFixRenamesUnderscoreLocal(): Void {
		// A local wrongly carrying the private-field `_`/`__` prefix, in a class whose
		// inheritance is fully resolvable (here: no supertype) - the prefix is stripped.
		final src: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\tvar __adjust = 1;\n\t\ttrace(__adjust);\n\t}\n}';
		assertFixCanonicalWithIndex(src, 'var adjust', '_adjust');
	}

	public function testFixSkipsLocalCollidingWithSiblingLocal(): Void {
		// De-prefixing `_adjust` to `adjust` collides with a sibling local `adjust` - skip.
		final src: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\tvar _adjust = 1;\n\t\tvar adjust = 2;\n'
			+ '\t\ttrace(_adjust + adjust);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	public function testFixSkipsLocalCollidingWithParam(): Void {
		// De-prefixing `_adjust` to `adjust` collides with a parameter `adjust` - skip.
		final src: String =
			'package pkg;\nclass C {\n\tpublic function f(adjust:Int) {\n\t\tvar _adjust = 1;\n\t\ttrace(_adjust + adjust);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	public function testFixSkipsLocalCollidingWithOwnMember(): Void {
		// De-prefixing `_adjust` to `adjust` collides with an own field `adjust` - skip.
		final src: String = 'package pkg;\nclass C {\n\tpublic var adjust:Int = 0;\n\tpublic function f() {\n\t\tvar _adjust = 1;\n'
			+ '\t\ttrace(_adjust);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	public function testFixSkipsLocalDeprefixingToKeyword(): Void {
		// De-prefixing `_new` to `new` yields a Haxe keyword - not a usable identifier - skip.
		final src: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\tvar _new = 1;\n\t\ttrace(_new);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
		final superSrc: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\tvar _super = 1;\n\t\ttrace(_super);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: superSrc }], 'pkg/C.hx', superSrc);
	}

	public function testFixSkipsLocalReferencedBehindConditional(): Void {
		// A reference behind a mid-expression `#if` is kept as raw trivia (a CondSpliceTail),
		// invisible to the resolver - the rename would leave that occurrence dangling, so the
		// completeness guard bails - skip.
		final src: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\tvar _adjust = 1;\n'
			+ '\t\tvar x = _adjust #if cpp + _adjust #end;\n\t\ttrace(x);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	public function testFixRenamesLocalShadowingInheritedMember(): Void {
		// De-prefixing `_adjust` -> `adjust` where `adjust` is an inherited field: a local
		// SHADOWING an inherited member is legal Haxe (verified), and the whole-file collision
		// scan sees no bare in-file `adjust`, so the rename applies (the inheritance gate is field-only).
		final baseSrc: String = 'package pkg;\nclass Base {\n\tpublic var adjust:Int = 0;\n}';
		final cSrc: String =
			'package pkg;\nclass C extends Base {\n\tpublic function f() {\n\t\tvar _adjust = 1;\n\t\ttrace(_adjust);\n\t}\n}';
		assertLocalRenamed(
			[{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }], 'pkg/C.hx', cSrc, 'var adjust', '_adjust'
		);
	}

	public function testFixRenamesLocalUnderUnresolvableInheritance(): Void {
		// The enclosing type extends a base absent from the index. A local cannot clash by
		// REDEFINITION (only a field can) and shadowing is legal, so a local rename no longer
		// depends on resolving inheritance - it applies.
		final src: String =
			'package pkg;\nclass C extends UnknownBase {\n\tpublic function f() {\n\t\tvar _adjust = 1;\n\t\ttrace(_adjust);\n\t}\n}';
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, 'var adjust', '_adjust');
	}

	public function testFixRenamesSnakeCaseLocal(): Void {
		// A snake_case local is converted to camelCase - the widened normalizer (`min_gap` -> `minGap`).
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar min_gap = 5;\n\t\ttrace(min_gap);\n\t}\n}';
		assertFixCanonical(src, 'minGap', 'min_gap');
	}

	public function testFixRenamesSnakeCaseParam(): Void {
		// A snake_case parameter is converted to camelCase (`grant_type` -> `grantType`).
		final src: String = 'class C {\n\tpublic function f(grant_type:String) {\n\t\treturn grant_type;\n\t}\n}';
		assertFixCanonical(src, 'grantType', 'grant_type');
	}

	public function testFixRenamesUpperSnakeLocal(): Void {
		// An UPPER_SNAKE local is lowercased per-segment then camel-joined (`MAX_LEN` -> `maxLen`).
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar MAX_LEN = 5;\n\t\ttrace(MAX_LEN);\n\t}\n}';
		assertFixCanonical(src, 'maxLen', 'MAX_LEN');
	}

	public function testFixRenamesParamDeprefix(): Void {
		// A `__`-prefixed parameter is de-prefixed to camelCase (a single leading `_` is the
		// deliberate unused-marker and stays conformant; `__` is flagged).
		final src: String = 'class C {\n\tpublic function f(__focusType:Int) {\n\t\treturn __focusType;\n\t}\n}';
		assertFixCanonical(src, 'focusType', '__focusType');
	}

	public function testFixSkipsSnakeLocalCollidingInFile(): Void {
		// The camelCase form already occurs in the file (a sibling local) - the collision scan
		// skips it to avoid a duplicate/shadow the re-parse gate accepts but that would not type-check.
		final src: String =
			'class C {\n\tpublic function f() {\n\t\tvar minGap = 1;\n\t\tvar min_gap = 2;\n\t\ttrace(minGap + min_gap);\n\t}\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.isTrue(vs.length >= 1);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testFixRenamesThreeSameNameBindings(): Void {
		// One file with THREE distinct `__id` bindings - a private field, a parameter, and a
		// for-loop iterator. Each renames to its OWN target (field -> `_id`, param & loop -> `id`)
		// in a single fix pass; the per-binding spans are disjoint so the edits do not corrupt.
		final src: String = 'package pkg;\nclass C {\n\tprivate var __id:Int = 0;\n\tpublic function add():Int {\n\t\treturn __id++;\n\t}\n'
			+ '\tpublic function remove(__id:Int):Void {\n\t\tremoveAt(__id);\n\t}\n\tpublic function clear():Void {\n'
			+ '\t\tfor (__id in [1, 2, 3]) removeAt(__id);\n\t}\n\tfunction removeAt(x:Int):Void {}\n}';
		final index: SymbolIndex = SymbolIndex.build([{ file: 'pkg/C.hx', source: src }], new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'pkg/C.hx', source: src }], new HaxeQueryPlugin());
		Assert.isTrue(vs.length >= 3);
		switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin(), index), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals(-1, text.indexOf('__id'));
				Assert.isTrue(text.indexOf('var _id') >= 0);
				Assert.isTrue(text.indexOf('remove(id') >= 0);
				Assert.isTrue(text.indexOf('for (id in') >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	public function testFixRenamesLocalDespiteSameNameInUnrelatedFunction(): Void {
		// `adjust` also names a local in an UNRELATED method `g` - out of `f`'s scope, so it no
		// longer blocks de-prefixing `_adjust` -> `adjust` in `f` (the collision scan is scope-aware).
		final src: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\tvar _adjust = 1;\n\t\ttrace(_adjust);\n\t}\n'
			+ '\tpublic function g() {\n\t\tvar adjust = 2;\n\t\ttrace(adjust);\n\t}\n}';
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, 'var adjust', '_adjust');
	}

	public function testFixSkipsLocalCollidingWithEnclosingScopeLocal(): Void {
		// `adjust` is bound in an ENCLOSING block of the SAME function - reachable from the inner
		// scope, so de-prefixing `_adjust` -> `adjust` is a genuine conflict and still skips
		// (scope-awareness exempts only UNRELATED functions, never the binding's own scope chain).
		final src: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\tvar adjust = 1;\n\t\tif (adjust > 0) {\n'
			+ '\t\t\tvar _adjust = 2;\n\t\t\ttrace(_adjust + adjust);\n\t\t}\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	public function testFixSkipsParamCapturedByNestedFunctionLocal(): Void {
		// A `__`-param captured by a NESTED local function whose body declares a same-named local:
		// de-prefixing `__items` -> `items` rebinds the param's in-closure use to that local (capture,
		// "has no field push"). A same-named binding ANYWHERE in the param's own function body -
		// including nested local functions - conflicts, so the rename must skip.
		final src: String = 'package pkg;\nclass C {\n\tpublic function f(__items:Array<Int>):Void {\n\t\tfunction finish():Void {\n'
			+ '\t\t\tfinal items:Int = 1;\n\t\t\t__items.push(items);\n\t\t}\n\t\tfinish();\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	public function testFixRenamesParamDespiteSameNameLocalInUnrelatedFunction(): Void {
		// `items` names a local only in an UNRELATED method `g` - out of `f`'s scope, so de-prefixing
		// param `__items` -> `items` in `f` still applies (scope-awareness exempts unrelated functions,
		// but never the binding's own body or its nested closures).
		final src: String = 'package pkg;\nclass C {\n\tpublic function f(__items:Array<Int>):Void {\n\t\t__items.push(1);\n\t}\n'
			+ '\tpublic function g():Void {\n\t\tfinal items:Int = 2;\n\t\ttrace(items);\n\t}\n}';
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, 'items.push', '__items');
	}

	public function testFixDoesNotRenameCommentMentionOfUnrelatedBinding(): Void {
		// Two methods each declare a DISTINCT `__x`. Renaming method `a`'s `__x` -> `x` must not rewrite
		// the `__x` mention in method `b`'s comment (which refers to b's own, un-renamed `__x`): comment
		// -along is scoped to the binding's container, so a same-named binding elsewhere is left alone.
		final src: String = 'package pkg;\nclass C {\n\tpublic function a(__x:Int):Int {\n\t\treturn __x;\n\t}\n'
			+ '\tpublic function b(__x:Int):Int {\n\t\tvar x:Int = 5;\n\t\t// keep __x here\n\t\treturn __x + x;\n\t}\n}';
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('// keep __x here') >= 0);
				Assert.isTrue(text.indexOf('a(x:Int)') >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	/**
	 * A leading ACRONYM run lowercases whole EXCEPT its last character, which heads the next
	 * word: `URLPath` -> `urlPath`. The pre-arm normalizer only lowered the first letter and
	 * emitted `uRLPath`.
	 */
	public function testFixLowercasesLeadingAcronymLocal(): Void {
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar URLPath = 1;\n\t\ttrace(URLPath);\n\t}\n}';
		assertFixCanonical(src, 'urlPath', 'uRLPath');
	}

	/** The acronym run is delimited by the first LOWERCASE letter, wherever it falls: `HTTPServer` -> `httpServer`. */
	public function testFixLowercasesAcronymRunBeforeWord(): Void {
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar HTTPServer = 1;\n\t\ttrace(HTTPServer);\n\t}\n}';
		assertFixCanonical(src, 'httpServer', 'hTTPServer');
	}

	/**
	 * An all-uppercase word with NO lowercase letter after it is not an acronym run - the
	 * whole-segment arm still lowercases it (`HEIGHT` -> `height`). Pins behaviour the
	 * acronym arm must not disturb.
	 */
	public function testFixLowercasesAllCapsWordWhole(): Void {
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar HEIGHT = 1;\n\t\ttrace(HEIGHT);\n\t}\n}';
		assertFixCanonical(src, 'height', 'HEIGHT');
	}

	/**
	 * The acronym arm is LEADING-only and needs a run of two or more: `MyURLPath` opens with a
	 * one-letter run, so only the final first-character lowering applies and the INTERIOR
	 * acronym is left alone. (The bare one-letter run is pinned by `testFixRenamesLocal`.)
	 */
	public function testFixLeavesInteriorAcronymAlone(): Void {
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar MyURLPath = 1;\n\t\ttrace(MyURLPath);\n\t}\n}';
		assertFixCanonical(src, 'myURLPath', 'MyURLPath');
	}

	/** The correction for a normalizer artifact is the whole name lowercased. */
	public function testNormalizerArtifactLocalLowercased(): Void {
		final src: String = 'class C {\n\tpublic function f() {\n\t\tvar hEIGHT = 1;\n\t\ttrace(hEIGHT);\n\t}\n}';
		assertFixCanonical(src, 'height', 'hEIGHT');
	}

	/**
	 * The MIRROR of the param idiom: a normalizer-artifact LOCAL corrected to `width` would capture
	 * the bare reads of the INHERITED `width`. Those reads are qualified through `this.` and the
	 * rename proceeds, instead of the collision refusing it forever.
	 */
	public function testFixQualifiesInheritedMemberCapturedByLocalRename(): Void {
		final baseSrc: String = 'package pkg;\nclass Base {\n\tpublic var width:Int = 0;\n}';
		final cSrc: String = 'package pkg;\nclass C extends Base {\n\tpublic function f():Void {\n'
			+ '\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertLocalRenamed(
			[{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }],
			'pkg/C.hx', cSrc, 'trace(this.width + width)', 'wIDTH'
		);
	}

	/**
	 * The same repair when the captured member is the enclosing type's OWN instance field - no
	 * supertype walk needed, the declaration sits in the file being fixed.
	 */
	public function testFixQualifiesOwnMemberCapturedByLocalRename(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic var width:Int = 0;\n\tpublic function f():Void {\n'
			+ '\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, 'trace(this.width + width)', 'wIDTH');
	}

	/**
	 * A captured STATIC member has no `this.` spelling, so the local rename stays refused - the
	 * mirror of `testFixRefusesStaticMemberCapture` on the member-rename side.
	 */
	public function testFixRefusesLocalRenameCapturingStaticMember(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic static var width:Int = 0;\n\tpublic function f():Void {\n'
			+ '\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * An unresolvable supertype leaves the captured name unproven - qualifying it would be a guess,
	 * so the rename is refused (fail-closed).
	 */
	public function testFixRefusesLocalRenameCapturingUnprovableMember(): Void {
		final src: String = 'package pkg;\nclass C extends Missing {\n\tpublic function f():Void {\n'
			+ '\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * The captured occurrence must be one that READ the member: a PARAMETER of the same name
	 * shadowed it, so the occurrence read the param, and `this.width` would rebind it to the field -
	 * valid, type-correct, a different program. Member existence alone is not the proof.
	 */
	public function testFixRefusesLocalRenameCapturingParamShadowedMember(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic var width:Int = 7;\n\tpublic function f(width:Int):Void {\n'
			+ '\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * A `#if`-guarded own `static` member still decides: the SymbolIndex sees a guarded declaration,
	 * so an own-member scan that stopped at the type body's direct children would read this as "no
	 * own declaration", let the inherited instance `width` answer, and emit a `this.` the guarded
	 * build rejects.
	 */
	public function testFixRefusesLocalRenameCapturingConditionalGuardedStatic(): Void {
		final baseSrc: String = 'package pkg;\nclass Base {\n\tpublic var width:Int = 0;\n}';
		final cSrc: String = 'package pkg;\nclass C extends Base {\n\t#if debug\n\tpublic static var width:Int = 0;\n\t#end\n'
			+ '\tpublic function f():Void {\n\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }], 'pkg/C.hx', cSrc);
	}

	/**
	 * The supertype proof must follow the IMPORT, not the simple name: `C extends b.Base` inherits
	 * nothing, and an unrelated `a.Base` declaring `width` must not supply the proof - the emitted
	 * `this.width` would not compile.
	 */
	public function testFixRefusesLocalRenameCapturingAmbiguouslyNamedSupertypeMember(): Void {
		final aSrc: String = 'package a;\nclass Base {\n\tpublic var width:Int = 0;\n}';
		final bSrc: String = 'package b;\nclass Base {\n\tpublic var depth:Int = 0;\n}';
		final cSrc: String = 'package pkg;\nimport b.Base;\nclass C extends Base {\n\tpublic function f():Void {\n'
			+ '\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertFixSkipped([
			{ file: 'a/Base.hx', source: aSrc },
			{ file: 'b/Base.hx', source: bSrc },
			{ file: 'pkg/C.hx', source: cSrc }
		], 'pkg/C.hx', cSrc);
	}

	/**
	 * Two flagged declarations wanting the SAME token: the local's qualification rewrites a bare
	 * `width` that the private field's own rename also owns. Overlapping edits have no defined
	 * winner, so one of the two must defer rather than silently clobber the other.
	 */
	public function testFixEmitsDisjointEditsForCollidingRenames(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function f():Void {\n\t\tfinal wIDTH:Int = 1;\n'
			+ '\t\ttrace(width + wIDTH);\n\t}\n\tprivate var width:Int = 0;\n}';
		assertFixEditsDisjoint([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * The repair under a NON-ZERO rename delta - `_width` is one character longer than `width`, so
	 * the qualified rewrite's offsets only map back when the per-occurrence length change is
	 * accumulated rather than assumed zero.
	 */
	public function testFixQualifiesCaptureUnderNonZeroRenameDelta(): Void {
		final baseSrc: String = 'package pkg;\nclass Base {\n\tpublic var width:Int = 0;\n}';
		final cSrc: String = 'package pkg;\nclass C extends Base {\n\tpublic function f():Void {\n'
			+ '\t\tfinal _width:Int = 1;\n\t\ttrace(width + _width);\n\t}\n}';
		assertLocalRenamed(
			[{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }],
			'pkg/C.hx', cSrc, 'trace(this.width + width)', '_width'
		);
	}

	/**
	 * A local `function` statement is a declaration the policy governs like any other local
	 * binding: `snake_case` violates the camelCase local rule and the autofix corrects it.
	 */
	public function testLocalFunctionNameFlaggedAndRenamed(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\tfunction draw_grid() {\n\t\t\ttrace(1);\n\t\t}\n'
			+ '\t\tdraw_grid();\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf("'draw_grid'") >= 0);
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, 'function drawGrid()', 'draw_grid');
	}

	/** A conformant local function name is no finding. */
	public function testCamelCaseLocalFunctionNameAccepted(): Void {
		final src: String =
			'package pkg;\nclass C {\n\tpublic function f() {\n\t\tfunction drawGrid() {\n\t\t\ttrace(1);\n\t\t}\n\t\tdrawGrid();\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A sibling local function already holding the corrected name is a collision: the scope a local
	 * function binds into is the enclosing body, so the two share it.
	 */
	public function testLocalFunctionCollidingWithSiblingSkipped(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\tfunction drawGrid(n:Int) {\n'
			+ '\t\t\tif (n > 0) drawGrid(n - 1);\n\t\t}\n\t\tfunction draw_grid() {\n\t\t\ttrace(1);\n\t\t}\n' + '\t\tdraw_grid();\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * A distinctive comment mention in the ENCLOSING body renames along with the local function: the
	 * binding's lexical container is the body it binds into, not the declaration's own span.
	 */
	public function testLocalFunctionCommentMentionRenamesAlong(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\t// draw_grid paints the pitch.\n'
			+ '\t\tfunction draw_grid() {\n\t\t\ttrace(1);\n\t\t}\n\t\tdraw_grid();\n\t}\n}';
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, '// drawGrid paints the pitch.', 'draw_grid');
	}

	/**
	 * A read resolved BEFORE the local function's declaration belongs to the member it shadows, so the
	 * rename is refused rather than rewriting a call the compiler binds elsewhere.
	 */
	public function testLocalFunctionWithOccurrenceBeforeDeclarationSkipped(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate function draw_grid() {\n\t\ttrace(1);\n\t}\n\n\tpublic function f() {\n'
			+ '\t\tdraw_grid();\n\t\tfunction draw_grid() {\n\t\t\ttrace(2);\n\t\t}\n\t\tdraw_grid();\n\t}\n}';
		assertFixSkipped([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src);
	}

	/**
	 * This check's OWN autofix shares `collidesInScope` with the underscore strip, so it sees the
	 * inline-helper scope union too: a parameter of one local `inline function` no longer collides
	 * with a SIBLING helper's same-named parameter, and `some_n` corrects to `someN` beside a
	 * helper that already binds `someN`. Before the union the two parameters shared the enclosing
	 * METHOD's span and the rename was refused.
	 */
	public function testInlineHelperParameterRenamesBesideSiblingHoldingTheName(): Void {
		final src: String = 'package pkg;\nclass C {\n\tpublic function f() {\n\t\tinline function a(some_n:Int) {\n\t\t\ttrace(some_n);\n'
			+ '\t\t}\n\t\tinline function b(someN:String) {\n\t\t\ttrace(someN);\n\t\t}\n\t\ta(1);\n\t\tb("x");\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.isTrue(vs[0].message.indexOf("'some_n'") >= 0);
		assertLocalRenamed([{ file: 'pkg/C.hx', source: src }], 'pkg/C.hx', src, 'inline function a(someN:Int)', 'some_n');
	}

	private function assertFixCanonical(src: String, present: String, absent: String): Void {
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		assertCanonicalized(src, check.fix(src, vs, new HaxeQueryPlugin()), present, absent);
	}

	/** Assert the naming autofix emits edits for `targetFile` that never overlap one another. */
	private function assertFixEditsDisjoint(files: Array<{ file: String, source: String }>, targetFile: String, targetSrc: String): Void {
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == targetFile);
		Assert.isTrue(vs.length >= 2);
		final edits: Array<{ span: Span, text: String }> = check.fix(targetSrc, vs, new HaxeQueryPlugin(), index);
		for (i in 0...edits.length) for (j in i + 1...edits.length) {
			final a: Span = edits[i].span;
			final b: Span = edits[j].span;
			Assert.isFalse(a.from < b.to && b.from < a.to, 'edits $i and $j overlap');
		}
	}

}
