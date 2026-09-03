package unit.check;

/**
 * The `naming` autofix HOIST arm: a local `final` that is an author-intended CONSTANT — an
 * UPPER_SNAKE name over a compile-time-constant initializer — is MOVED to its enclosing class as
 * a `private static … final` member keeping its original spelling, rather than being camelCased
 * like an ordinary local. Whenever any gate fails the declaration falls back to the ordinary
 * rename arm, silently.
 *
 * Each fallback fixture below is shaped so only its OWN gate can reject it, except the
 * own-class-declares-the-name one, which the rename arm's completeness gate also refuses (a
 * member declaration of that name is an uncovered occurrence by construction) — it is a
 * regression guard on the hoist arm, not a discriminating test of the member gate. The
 * supertype fixture is the discriminating one for that gate.
 */
class NamingCheckHoistFixTest extends NamingCheckTestBase {

	/** A scalar UPPER_SNAKE local `final` becomes a `private static inline final` member; its reads keep their spelling. */
	public function testHoistsScalarLocalConstant(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function f():Void {\n\t\tfinal PAD:Int = 40;\n\t\ttrace(PAD);\n\t}\n}';
		assertRenamedIn(
			'pkg/C.hx', src,
			'class C {\n\tprivate static inline final PAD:Int = 40;\n\n\tpublic function f():Void {\n\t\ttrace(PAD);\n\t}', '\t\tfinal PAD'
		);
	}

	/** A negation over a numeric literal is a compile-time constant too. */
	public function testHoistsNegatedNumericLocalConstant(): Void {
		final src: String =
			'package pkg;\n\nclass C {\n\tpublic function f():Void {\n\t\tfinal OFFSET:Int = -5;\n\t\ttrace(OFFSET);\n\t}\n}';
		assertRenamedIn(
			'pkg/C.hx', src, 'private static inline final OFFSET:Int = -5;\n\n\tpublic function f():Void {\n\t\ttrace(OFFSET);',
			'\t\tfinal OFFSET'
		);
	}

	/** A String constant hoists WITHOUT `inline` — an inlined String duplicates its bytes at every hxcpp use site. */
	public function testHoistsStringLocalConstantWithoutInline(): Void {
		final src: String =
			"package pkg;\n\nclass C {\n\tpublic function f():Void {\n\t\tfinal TITLE:String = 'x';\n\t\ttrace(TITLE);\n\t}\n}";
		assertRenamedIn(
			'pkg/C.hx', src, "private static final TITLE:String = 'x';\n\n\tpublic function f():Void {\n\t\ttrace(TITLE);",
			'inline final TITLE'
		);
	}

	/** Two constants in one pass share ONE insertion, so their zero-width edits cannot collide at the same offset. */
	public function testHoistsTwoConstantsInOneInsertion(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function f():Void {\n\t\tfinal PAD:Int = 40;\n\t\tfinal GAP:Int = 8;\n'
			+ '\t\ttrace(PAD + GAP);\n\t}\n}';
		assertRenamedIn(
			'pkg/C.hx', src,
			'class C {\n\tprivate static inline final PAD:Int = 40;\n\tprivate static inline final GAP:Int = 8;\n\n'
			+ '\tpublic function f():Void {\n\t\ttrace(PAD + GAP);\n\t}',
			'\t\tfinal '
		);
	}

	/** An initializer reading a parameter is no compile-time constant — the ordinary rename applies. */
	public function testRenamesLocalWithNonConstantInitializer(): Void {
		final src: String =
			'package pkg;\n\nclass C {\n\tpublic function f(w:Int):Void {\n\t\tfinal WIDTH:Int = w * 2;\n\t\ttrace(WIDTH);\n\t}\n}';
		assertRenamedIn('pkg/C.hx', src, 'final width:Int = w * 2;\n\t\ttrace(width);', 'static inline final WIDTH');
	}

	/** A mutable `var` is no constant whatever its spelling — the hoist arm is `final`-only. */
	public function testRenamesUpperSnakeVarLocal(): Void {
		final src: String =
			'package pkg;\n\nclass C {\n\tpublic function f():Void {\n\t\tvar PAD:Int = 40;\n\t\tPAD++;\n\t\ttrace(PAD);\n\t}\n}';
		assertRenamedIn('pkg/C.hx', src, 'var pad:Int = 40;\n\t\tpad++;', 'static inline final PAD');
	}

	/** A supertype already declaring the name would make the hoisted member a redeclaration — rename instead. */
	public function testRenamesLocalWhenSupertypeDeclaresTheName(): Void {
		final baseSrc: String = 'package pkg;\n\nclass Base {\n\tpublic var PAD:Int = 0;\n}';
		final cSrc: String =
			'package pkg;\n\nclass C extends Base {\n\tpublic function f():Void {\n\t\tfinal PAD:Int = 40;\n\t\ttrace(PAD);\n\t}\n}';
		assertLocalRenamed(
			[{ file: 'pkg/Base.hx', source: baseSrc }, { file: 'pkg/C.hx', source: cSrc }],
			'pkg/C.hx', cSrc, 'final pad:Int = 40;\n\t\ttrace(pad);', 'static inline final PAD'
		);
	}

	/** An unresolvable supertype closure cannot rule out an inherited `PAD` — refuse the hoist and rename (fail-closed). */
	public function testRenamesLocalUnderUnresolvableSupertype(): Void {
		final src: String = 'package pkg;\n\nclass C extends UnknownBase {\n\tpublic function f():Void {\n\t\tfinal PAD:Int = 40;\n'
			+ '\t\ttrace(PAD);\n\t}\n}';
		assertRenamedIn('pkg/C.hx', src, 'final pad:Int = 40;\n\t\ttrace(pad);', 'static inline final PAD');
	}

	/** A second local of the same name elsewhere in the file: a hoisted member would shadow it — rename both. */
	public function testRenamesLocalWhenNameIsBoundElsewhereInTheFile(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function f():Void {\n\t\tfinal PAD:Int = 40;\n\t\ttrace(PAD);\n\t}\n\n'
			+ '\tpublic function g():Void {\n\t\tfinal PAD:Int = 8;\n\t\ttrace(PAD);\n\t}\n}';
		assertRenamedIn('pkg/C.hx', src, 'final pad:Int = 40;\n\t\ttrace(pad);', 'static inline final PAD');
	}

	/**
	 * The own class already declaring the name: the hoisted member would be a redeclaration, so the
	 * ordinary rename applies (see the class doc — this guards the hoist arm, it does not discriminate
	 * the member gate).
	 */
	public function testRenamesLocalWhenOwnClassDeclaresTheName(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic static final PAD:Int = 1;\n\n\tpublic function f():Void {\n'
			+ '\t\tfinal PAD:Int = 40;\n\t\ttrace(PAD);\n\t}\n}';
		assertRenamedIn('pkg/C.hx', src, 'final pad:Int = 40;\n\t\ttrace(pad);', 'static inline final PAD');
	}

	/**
	 * A `#if`-guarded declaration must not leave its branch: the other branches would gain a member they
	 * never declared. The declaration sits in a BRACED block, so it passes the direct-child-of-a-block
	 * gate and only the conditional gate can refuse it — the discriminating shape for that gate.
	 */
	public function testRefusesHoistInsideConditionalRegion(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function f():Void {\n\t\t#if debug\n\t\t{\n\t\t\tfinal PAD:Int = 40;\n'
			+ '\t\t\ttrace(PAD);\n\t\t}\n\t\t#end\n\t}\n}';
		assertRenamedIn(
			'pkg/C.hx', src, '#if debug\n\t\t{\n\t\t\tfinal pad:Int = 40;\n\t\t\ttrace(pad);\n\t\t}\n\t\t#end', 'static inline final PAD'
		);
	}

	/** A note written on the declaration's own line is unambiguously about it, so it travels to the class body with it. */
	public function testHoistsConstantWithItsTrailingComment(): Void {
		final src: String =
			'package pkg;\n\nclass C {\n\tpublic function f():Void {\n\t\tfinal PAD:Int = 40; // in points\n\t\ttrace(PAD);\n\t}\n}';
		assertRenamedIn(
			'pkg/C.hx', src, 'private static inline final PAD:Int = 40; // in points\n\n\tpublic function f():Void {\n\t\ttrace(PAD);',
			'\t\tfinal PAD'
		);
	}

	/**
	 * A comment on the line directly ABOVE reads the same whether it documents the declaration or
	 * introduces the block below it, so the hoist declines and the ordinary rename leaves the comment
	 * exactly where its author put it.
	 */
	public function testRenamesLocalCarryingALeadingComment(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function f():Void {\n\t\t// The gap between cards.\n'
			+ '\t\tfinal PAD:Int = 40;\n\t\ttrace(PAD);\n\t}\n}';
		assertRenamedIn('pkg/C.hx', src, '// The gap between cards.\n\t\tfinal pad:Int = 40;\n\t\ttrace(pad);', 'static inline final PAD');
	}

	/**
	 * A declaration that is the brace-less BODY of an `if` owns that body slot. Removing its line would
	 * hand the slot to the NEXT statement — `if (flag) trace(1);` — which parses, re-parses and
	 * type-checks while meaning something else entirely. Only a direct child of a statement block may
	 * be hoisted; here the ordinary rename applies and the body slot keeps its declaration.
	 */
	public function testRenamesLocalThatIsABracelessIfBody(): Void {
		final src: String =
			'package pkg;\n\nclass C {\n\tpublic function f(flag:Bool):Void {\n\t\tif (flag) final PAD:Int = 40;\n\t\ttrace(1);\n\t}\n}';
		assertRenamedIn('pkg/C.hx', src, 'if (flag) final pad:Int = 40;\n\t\ttrace(1);', 'static inline final PAD');
	}

	/** The same body-slot theft through a `for` header. */
	public function testRenamesLocalThatIsABracelessForBody(): Void {
		final src: String =
			'package pkg;\n\nclass C {\n\tpublic function f():Void {\n\t\tfor (i in 0...3) final GAP:Int = 41;\n\t\ttrace(2);\n\t}\n}';
		assertRenamedIn('pkg/C.hx', src, 'for (i in 0...3) final gap:Int = 41;\n\t\ttrace(2);', 'static inline final GAP');
	}

	/**
	 * The `else` variant, where the declaration IS alone on its line — so the line-span widening is
	 * happy and only the block-child gate stands between the fix and stealing the `else` body.
	 */
	public function testRenamesLocalThatIsABracelessElseBody(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function f(flag:Bool):Void {\n\t\tif (flag)\n\t\t\ttrace(3);\n'
			+ '\t\telse\n\t\t\tfinal TAB:Int = 42;\n\t\ttrace(4);\n\t}\n}';
		assertRenamedIn('pkg/C.hx', src, 'else\n\t\t\tfinal tab:Int = 42;\n\t\ttrace(4);', 'static inline final TAB');
	}

	/** Haxe rejects a static field on a `@:generic` class outright, so the receiving type must allow one. */
	public function testRenamesLocalInGenericClass(): Void {
		final src: String =
			'package pkg;\n\n@:generic class C<T> {\n\tpublic function f():Void {\n\t\tfinal PAD:Int = 40;\n\t\ttrace(PAD);\n\t}\n}';
		assertRenamedIn(
			'pkg/C.hx', src, '@:generic class C<T> {\n\tpublic function f():Void {\n\t\tfinal pad:Int = 40;', 'static inline final PAD'
		);
	}

	/** A multi-binding list continues through a node that carries no declaration keyword of its own — rename both. */
	public function testRenamesMultiBindingConstantList(): Void {
		final src: String =
			'package pkg;\n\nclass C {\n\tpublic function f():Void {\n\t\tfinal PAD:Int = 1, GAP:Int = 2;\n\t\ttrace(PAD + GAP);\n\t}\n}';
		assertRenamedIn('pkg/C.hx', src, 'final pad:Int = 1, gap:Int = 2;\n\t\ttrace(pad + gap);', 'static inline final');
	}

	/** An `enum abstract`'s members are enum VALUES, not fields — it is not a class and receives nothing. */
	public function testRenamesLocalInEnumAbstract(): Void {
		final src: String = 'package pkg;\n\nenum abstract E(Int) {\n\tfinal ONE = 1;\n\n\tpublic static function f():Int {\n'
			+ '\t\tfinal PAD:Int = 40;\n\t\treturn PAD;\n\t}\n}';
		assertRenamedIn('pkg/E.hx', src, 'final pad:Int = 40;\n\t\treturn pad;', 'static inline final PAD');
	}

	/** Two constants declared in DIFFERENT methods of one class still share that class's single insertion. */
	public function testHoistsFromTwoMethodsIntoOneInsertion(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\tpublic function f():Void {\n\t\tfinal PAD:Int = 40;\n\t\ttrace(PAD);\n\t}\n\n'
			+ '\tpublic function g():Void {\n\t\tfinal GAP:Int = 8;\n\t\ttrace(GAP);\n\t}\n}';
		assertRenamedIn(
			'pkg/C.hx', src,
			'class C {\n\tprivate static inline final PAD:Int = 40;\n\tprivate static inline final GAP:Int = 8;\n\n'
			+ '\tpublic function f():Void {\n\t\ttrace(PAD);\n\t}\n\n\tpublic function g():Void {\n\t\ttrace(GAP);\n\t}',
			'\t\tfinal '
		);
	}

	/** Two classes in one module each receive their OWN insertion, at their own body brace. */
	public function testHoistsIntoEachClassOfAModule(): Void {
		final src: String = 'package pkg;\n\nclass A {\n\tpublic function f():Void {\n\t\tfinal PAD:Int = 40;\n\t\ttrace(PAD);\n\t}\n}\n\n'
			+ 'class B {\n\tpublic function g():Void {\n\t\tfinal GAP:Int = 8;\n\t\ttrace(GAP);\n\t}\n}';
		assertRenamedIn(
			'pkg/A.hx', src,
			'class A {\n\tprivate static inline final PAD:Int = 40;\n\n\tpublic function f():Void {\n\t\ttrace(PAD);\n\t}\n}\n\n'
			+ 'class B {\n\tprivate static inline final GAP:Int = 8;\n\n\tpublic function g():Void {\n\t\ttrace(GAP);\n\t}\n}',
			'\t\tfinal '
		);
	}

	/**
	 * The insertion lands right after the body brace, NOT before the first member — that position sits
	 * past the member's leading doc comment, and an insertion there silently steals it.
	 */
	public function testHoistDoesNotStealTheFirstMemberDoc(): Void {
		final src: String = 'package pkg;\n\nclass C {\n\n\t/** The counter. */\n\tpublic var n:Int = 0;\n\n'
			+ '\tpublic function f():Void {\n\t\tfinal PAD:Int = 40;\n\t\ttrace(PAD + n);\n\t}\n}';
		assertRenamedIn(
			'pkg/C.hx', src, 'private static inline final PAD:Int = 40;\n\n\t/** The counter. */\n\tpublic var n:Int = 0;', '\t\tfinal PAD'
		);
	}

}
